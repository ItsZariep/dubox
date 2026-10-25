module tools.mkdir;

// Without -p it is a single mkdirat(2). With -p every path component is created
// relative to the fd of the previous one, so the string is never resolved twice.

import core.stdc.errno : errno, EEXIST;
import common.args;
import common.cstr : fromC, parseOctalMode;
import common.entry : StandaloneMain;
import common.io : gout, diag, diagMsg;
import common.sys;
import common.vec;

@nogc nothrow:

enum toolName = "mkdir";

static immutable ToolInfo info = ToolInfo(toolName, "mkdir [OPTION]... DIRECTORY...",
	"Create the DIRECTORY(ies), if they do not already exist.");

static immutable Opt[] opts = [
	Opt('m', "mode", "set file mode (octal), not 0777 - umask", true),
	Opt('p', "parents", "no error if existing, make parent directories as needed"),
	Opt('v', "verbose", "print a message for each created directory"),
];

enum iMode = optIndex(opts, "mode");
enum iParents = optIndex(opts, "parents");
enum iVerbose = optIndex(opts, "verbose");

private struct Cfg
{
	bool parents;
	bool verbose;
	bool exact; // -m given: use `mode` as is, ignoring the umask
	uint mode;
	uint umaskBits;
}

// One mkdirat with a chosen umask. Returns 0 or errno.
private int mk(int dfd, const(char)* name, uint mode, uint maskToUse) @trusted
{
	const old = umask(maskToUse);
	const r = mkdirat(dfd, name, mode);
	const e = r == 0 ? 0 : errno;
	umask(old);
	return e;
}

// Create the final component, honouring -m.
private int makeLeaf(ref const Cfg c, int dfd, const(char)* name) @trusted
{
	if (!c.exact)
	{
		return mk(dfd, name, 0x1FF /* 0777 */ , c.umaskBits);
	}
	int e = mk(dfd, name, c.mode & 0x1FF, 0);
	if (e == 0 && (c.mode & 0xE00 /* 07000 */ ))
	{
		// mkdir(2) cannot set setuid/setgid/sticky reliably; fix it up on the new dir.
		if (fchmodat(dfd, name, c.mode, 0) != 0)
		{
			e = errno;
		}
	}
	return e;
}

private void created(const(char)[] path)
{
	gout.put("mkdir: created directory '");
	gout.put(path);
	gout.put("'\n");
}

private bool makeOne(ref const Cfg c, const(char)* cpath) @trusted
{
	const(char)[] path = fromC(cpath);

	if (!c.parents || path.length == 0)
	{
		const e = makeLeaf(c, AT_FDCWD, cpath);
		if (e)
		{
			diag(toolName, "cannot create directory", path, e);
			return false;
		}
		if (c.verbose)
		{
			created(path);
		}
		return true;
	}

	// -p: walk the components, holding one directory fd at a time.
	size_t end = path.length;
	while (end > 1 && path[end - 1] == '/')
	{
		--end;
	}

	size_t pos = 0;
	int dfd = AT_FDCWD;
	if (path[0] == '/')
	{
		dfd = openat(AT_FDCWD, "/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		if (dfd < 0)
		{
			diag(toolName, "cannot open directory", "/", errno);
			return false;
		}
		while (pos < end && path[pos] == '/')
		{
			++pos;
		}
	}

	bool ok = true;
	Vec!char comp;

	while (pos < end)
	{
		const size_t s = pos;
		while (pos < end && path[pos] != '/')
		{
			++pos;
		}
		const size_t compEnd = pos;
		while (pos < end && path[pos] == '/')
		{
			++pos;
		}
		const bool last = pos >= end;

		comp.truncate(0);
		must(comp.append(path[s .. compEnd]));
		must(comp.terminate());
		const(char)* name = comp.data.ptr;
		const(char)[] shown = path[0 .. compEnd];

		if (last)
		{
			const e = makeLeaf(c, dfd, name);
			if (e == 0)
			{
				if (c.verbose)
				{
					created(shown);
				}
			}
			else
			{
				stat_t st;
				if (e == EEXIST && fstatat(dfd, name, &st, 0) == 0 && isDirMode(st.st_mode))
				{
					// already there: fine with -p
				}
				else
				{
					diag(toolName, "cannot create directory", shown, e);
					ok = false;
				}
			}
			break;
		}

		// Intermediate: rwx for the owner is always added, like GNU mkdir -p.
		const e = mk(dfd, name, 0x1FF, c.umaskBits & ~0xC0u /* ~0300 */ );
		if (e == 0)
		{
			if (c.verbose)
			{
				created(shown);
			}
		}
		else if (e != EEXIST)
		{
			diag(toolName, "cannot create directory", shown, e);
			ok = false;
			break;
		}

		const nfd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		if (nfd < 0)
		{
			diag(toolName, "cannot create directory", shown, errno);
			ok = false;
			break;
		}
		if (dfd != AT_FDCWD)
		{
			close(dfd);
		}
		dfd = nfd;
	}

	if (dfd != AT_FDCWD)
	{
		close(dfd);
	}
	return ok;
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

	Cfg c;
	c.parents = p.flags[iParents];
	c.verbose = p.flags[iVerbose];
	c.mode = 0x1FF;
	if (p.flags[iMode])
	{
		if (!parseOctalMode(fromC(p.values[iMode]), c.mode))
		{
			diag(toolName, "invalid mode", fromC(p.values[iMode]), 0);
			return 1;
		}
		c.exact = true;
	}

	if (p.count == 0)
	{
		diagMsg(toolName, "missing operand");
		tryHelp(toolName);
		return 1;
	}

	c.umaskBits = umask(0);
	umask(c.umaskBits);

	int rc = 0;
	foreach (i; 0 .. p.count)
	{
		if (!makeOne(c, p.operands[i]))
		{
			rc = 1;
		}
	}
	return rc;
}

mixin StandaloneMain!run;
