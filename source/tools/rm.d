module tools.rm;

import common.args;
import common.cstr : baseName, eq, fromC, isDotOrDotDot;
import common.entry : StandaloneMain;
import common.io : diag, diagMsg, gerr, gout;
import common.sys;
import common.vec;
import core.stdc.errno : EISDIR, ENOENT, errno;
import core.stdc.string : strlen;

@nogc nothrow:

enum toolName = "rm";

static immutable ToolInfo info = ToolInfo(toolName, "rm [OPTION]... FILE...",
	"Remove (unlink) the FILE(s).\n\n"
	~ "By default rm does not remove directories; use -r to remove a directory\n"
	~ "and everything below it.");

static immutable Opt[] opts = [
	Opt('f', "force", "ignore nonexistent files, never complain"),
	Opt('r', "recursive", "remove directories and their contents recursively"),
	Opt('R', "", "same as -r"),
	Opt('d', "dir", "remove empty directories"),
	Opt('v', "verbose", "explain what is being done"),
	Opt('\0', "one-file-system", "skip directories on a different file system"),
];

enum iForce = optIndex(opts, "force");
enum iRecursive = optIndex(opts, "recursive");
enum iRecursiveR = optIndexShort(opts, 'R');
enum iDir = optIndex(opts, "dir");
enum iVerbose = optIndex(opts, "verbose");
enum iOneFs = optIndex(opts, "one-file-system");

// Everything the recursion needs, passed by reference instead of globals.
struct Ctx
{
	bool force;
	bool verbose;
	bool oneFs;
	ulong rootDev; // st_dev of the command-line directory (for --one-file-system)
	Vec!char path; // display path of the entry being processed (messages only!)
}

private bool fail(ref Ctx c, const(char)[] what, int err)
{
	diag(toolName, what, c.path.data, err);
	return false;
}

private void say(ref Ctx c, const(char)[] what)
{
	if (!c.verbose) return;
	gout.put(what);
	gout.put(" '");
	gout.put(c.path.data);
	gout.put("'\n");
}

private void pushComponent(ref Vec!char path, const(char)* name) @trusted
{
	if (path.length != 0 && path.data[path.length - 1] != '/')
	{
		must(path.push('/'));
	}
	must(path.append(name[0 .. strlen(name)]));
}

// True if `st` describes the root directory. Fails closed: if "/" cannot be
// examined we answer "yes, it is root" and the caller refuses to proceed.
private bool isRoot(ref const stat_t st) @trusted
{
	stat_t root;
	if (fstatat(AT_FDCWD, "/", &root, 0) != 0) return true;
	return root.st_dev == st.st_dev && root.st_ino == st.st_ino;
}

//recursion //

// Remove one entry `name` that lives in the directory open as `dirFd`.
private bool removeEntry(int dirFd, const(char)* name, ubyte dtype, ref Ctx c) @trusted
{
	bool isDir = (dtype == DT_DIR);
	if (dtype == DT_UNKNOWN) // some file systems do not fill d_type
	{
		stat_t st;
		if (fstatat(dirFd, name, &st, AT_SYMLINK_NOFOLLOW) != 0)
		{
			const e = errno;
			return e == ENOENT ? true : fail(c, "cannot remove", e);
		}
		isDir = isDirMode(st.st_mode);
	}

	if (!isDir)
	{
		if (unlinkat(dirFd, name, 0) == 0)
		{
			say(c, "removed");
			return true;
		}
		const e = errno;
		if (e == ENOENT)
			return true; // somebody else removed it: fine
		if (e != EISDIR)
			return fail(c, "cannot remove", e);
		// It turned into a directory since readdir(): handle it as one.
	}
	return removeDirAt(dirFd, name, c);
}

// Empty and then remove the directory `name` inside `parentFd`.
private bool removeDirAt(int parentFd, const(char)* name, ref Ctx c) @trusted
{
	// O_NOFOLLOW: a symlink here is an error, never followed.
	// O_DIRECTORY: fail instead of opening some other file type.
	const fd = openat(parentFd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0)
		return fail(c, "cannot remove", errno);

	if (c.oneFs)
	{
		stat_t st;
		if (fstat(fd, &st) != 0)
		{
			const e = errno;
			close(fd);
			return fail(c, "cannot remove", e);
		}
		if (st.st_dev != c.rootDev)
		{
			close(fd);
			gout.flush();
			gerr.put("rm: skipping '");
			gerr.put(c.path.data);
			gerr.put("', since it's on a different device\n");
			gerr.flush();
			return false; // counts as a failure, like GNU rm
		}
	}

	DIR* d = fdopendir(fd); // takes ownership of fd
	if (d is null)
	{
		const e = errno;
		close(fd);
		return fail(c, "cannot remove", e);
	}

	bool ok = true;
	// Deleting while iterating is allowed to skip entries on some file systems,
	// so re-scan until a pass finds nothing left (or something failed).
	for (;;)
	{
		bool sawEntry = false;
		rewinddir(d);
		for (;;)
		{
			errno = 0;
			dirent* de = readdir(d);
			if (de is null)
				break;
			const(char)* nm = de.d_name.ptr;
			if (isDotOrDotDot(nm))
				continue;
			sawEntry = true;
			const mark = c.path.length;
			pushComponent(c.path, nm);
			if (!removeEntry(dirfd(d), nm, de.d_type, c))
				ok = false;
			c.path.truncate(mark);
		}
		if (errno != 0)
		{
			fail(c, "cannot read directory", errno);
			ok = false;
		}
		if (!sawEntry || !ok)
			break;
	}
	closedir(d);
	if (!ok) return false;

	if (unlinkat(parentFd, name, AT_REMOVEDIR) != 0)
	{
		const e = errno;
		return e == ENOENT ? true : fail(c, "cannot remove", e);
	}
	say(c, "removed directory");
	return true;
}

// command-line operands //

private bool removeOperand(const(char)* operand, ref Ctx c, bool recursive, bool dirs) @trusted
{
	// Work on a copy without trailing slashes. "link/" would otherwise make the
	// kernel follow the symlink despite O_NOFOLLOW (so `rm -r link/` removes the
	// link itself instead of the directory it points to; never the other way round).
	const orig = fromC(operand);
	size_t n = orig.length;
	while (n > 1 && orig[n - 1] == '/')
	{
		--n;
	}

	c.path.truncate(0);
	must(c.path.append(orig[0 .. n]));

	Vec!char top; // NUL-terminated syscall copy; separate from c.path, which may be reallocated
	must(top.append(orig[0 .. n]));
	must(top.terminate());
	const(char)* topC = top.data.ptr;

	const base = baseName(orig[0 .. n]);
	if (eq(base, ".") || eq(base, ".."))
	{
		diag(toolName, "refusing to remove '.' or '..' directory: skipping", orig, 0);
		return false;
	}

	stat_t st;
	if (fstatat(AT_FDCWD, topC, &st, AT_SYMLINK_NOFOLLOW) != 0)
	{
		const e = errno;
		if (e == ENOENT && c.force)
			return true;
		return fail(c, "cannot remove", e);
	}

	if (isDirMode(st.st_mode))
	{
		if (recursive)
		{
			if (isRoot(st))
			{
				diag(toolName, "it is dangerous to operate recursively on", "/", 0);
				diagMsg(toolName, "(dubox has no --no-preserve-root; refusing)");
				return false;
			}
			c.rootDev = st.st_dev;
			return removeDirAt(AT_FDCWD, topC, c);
		}
		if (dirs)
		{
			if (unlinkat(AT_FDCWD, topC, AT_REMOVEDIR) != 0)
				return fail(c, "cannot remove", errno);
			say(c, "removed directory");
			return true;
		}
		return fail(c, "cannot remove", EISDIR);
	}

	if (unlinkat(AT_FDCWD, topC, 0) != 0)
	{
		const e = errno;
		if (e == ENOENT && c.force)
			return true;
		return fail(c, "cannot remove", e);
	}
	say(c, "rm");
	return true;
}

int run(int argc, char** argv) @trusted
{
	Parsed!(opts.length) p;
	final switch (parse!(opts, info)(argc, argv, p))
	{
		case ParseResult.ok:
			break;
		case ParseResult.stop:
			return 0;
		case ParseResult.bad:
			return 1;
	}

	Ctx c;
	c.force = p.flags[iForce];
	c.verbose = p.flags[iVerbose];
	c.oneFs = p.flags[iOneFs];
	const recursive = p.flags[iRecursive] || p.flags[iRecursiveR];
	const dirs = p.flags[iDir];

	if (p.count == 0)
	{
		if (c.force)
			return 0;
		diagMsg(toolName, "missing operand");
		tryHelp(toolName);
		return 1;
	}

	int rc = 0;
	foreach (i; 0 .. p.count)
	{
		if (!removeOperand(p.operands[i], c, recursive, dirs))
		{
			rc = 1;
		}
	}
	return rc;
}

mixin StandaloneMain!run;
