module tools.mv;

// The fast path is one renameat(2). Only when source and destination are on different
// filesystems (EXDEV) does it fall back to copy (common/copy.d, preserving attributes)
// followed by an fd relative removal of the source, and only if the copy fully succeeded.

import core.stdc.errno : errno, EEXIST, EINVAL, ENOSYS, ENOTDIR, EXDEV, ENOTEMPTY, EISDIR;
import common.args;
import common.copy;
import common.cstr : baseName, fromC;
import common.entry : StandaloneMain;
import common.io : gout, diagMsg, diagQ, diagQ2;
import common.sys;
import common.vec;

@nogc nothrow:

enum toolName = "mv";

static immutable ToolInfo info = ToolInfo(toolName,
	"mv [OPTION]... SOURCE DEST\n   or: mv [OPTION]... SOURCE... DIRECTORY\n"
	~ "   or: mv [OPTION]... -t DIRECTORY SOURCE...",
	"Rename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.");

static immutable Opt[] opts = [
	Opt('f', "force", "do not prompt before overwriting (default)"),
	Opt('n', "no-clobber", "do not overwrite an existing file"),
	Opt('T', "no-target-directory", "treat DEST as a normal file"),
	Opt('t', "target-directory", "move all SOURCE arguments into DIRECTORY", true),
	Opt('v', "verbose", "explain what is being done"),
];

enum iForce = optIndex(opts, "force");
enum iNoClobber = optIndex(opts, "no-clobber");
enum iNoTargetDir = optIndex(opts, "no-target-directory");
enum iTargetDir = optIndex(opts, "target-directory");
enum iVerbose = optIndex(opts, "verbose");

private bool sameInode(ref const stat_t a, ref const stat_t b)
{
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

// Move one operand. `dname` is relative to `ddfd`.
private bool moveOne(ref CopyCtx c, bool verbose, const(char)* src, int ddfd, const(char)* dname,
		const(char)[] srcShown, const(char)[] dstShown) @trusted
{
	stat_t ss;
	if (fstatat(AT_FDCWD, src, &ss, AT_SYMLINK_NOFOLLOW) != 0)
	{
		diagQ(toolName, "cannot stat ", srcShown, "", errno);
		return false;
	}

	stat_t ds;
	const hasDest = fstatat(ddfd, dname, &ds, AT_SYMLINK_NOFOLLOW) == 0;
	if (hasDest)
	{
		if (sameInode(ss, ds))
		{
			diagQ2(toolName, "", srcShown, " and ", dstShown, " are the same file", 0);
			return false;
		}
		if (c.noClobber)
		{
			return true; // skip silently
		}
		if (isDirMode(ds.st_mode) && !isDirMode(ss.st_mode))
		{
			diagQ2(toolName, "cannot overwrite directory ", dstShown, " with non-directory ", srcShown, "", 0);
			return false;
		}
		if (!isDirMode(ds.st_mode) && isDirMode(ss.st_mode))
		{
			diagQ2(toolName, "cannot overwrite non-directory ", dstShown, " with directory ", srcShown, "", 0);
			return false;
		}
	}

	int r;
	if (c.noClobber)
	{
		r = renameat2(AT_FDCWD, src, ddfd, dname, RENAME_NOREPLACE);
		if (r != 0 && (errno == EINVAL || errno == ENOSYS))
		{
			r = renameat(AT_FDCWD, src, ddfd, dname); // filesystem without NOREPLACE; checked above
		}
		else if (r != 0 && errno == EEXIST)
		{
			return true;
		}
	}
	else
	{
		r = renameat(AT_FDCWD, src, ddfd, dname);
	}

	if (r == 0)
	{
		if (verbose)
		{
			gout.put("renamed '");
			gout.put(srcShown);
			gout.put("' -> '");
			gout.put(dstShown);
			gout.put("'\n");
		}
		return true;
	}

	const e = errno;
	if (e == EXDEV)
	{
		if (hasDest && isDirMode(ds.st_mode))
		{
			// same-filesystem rename would say "not empty"; never merge trees across devices
			diagQ2(toolName, "cannot move ", srcShown, " to ", dstShown, "", ENOTEMPTY);
			return false;
		}
		if (!copyTop(c, src, ddfd, dname, srcShown, dstShown))
		{
			return false; // copy failed: the source stays exactly as it was
		}
		Vec!char path;
		must(path.append(srcShown));
		if (!removeAt(toolName, AT_FDCWD, src, path))
		{
			return false;
		}
		if (verbose)
		{
			gout.put("renamed '");
			gout.put(srcShown);
			gout.put("' -> '");
			gout.put(dstShown);
			gout.put("'\n");
		}
		return true;
	}
	if (e == EINVAL && isDirMode(ss.st_mode))
	{
		diagQ2(toolName, "cannot move ", srcShown, " to a subdirectory of itself, ", dstShown, "", 0);
		return false;
	}
	diagQ2(toolName, "cannot move ", srcShown, " to ", dstShown, "", e);
	return false;
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

	// For the cross-device fallback: copy everything, keep attributes, never follow links.
	CopyCtx c;
	c.prog = toolName;
	c.recursive = true;
	c.preserve = true;
	c.force = p.flags[iForce];
	c.noClobber = p.flags[iNoClobber];
	c.verbose = false; // mv prints its own "renamed" lines (the copy engine stays quiet)
	c.umaskBits = 0;

	const verbose = p.flags[iVerbose];
	const noTargetDir = p.flags[iNoTargetDir];
	if (p.flags[iTargetDir] && noTargetDir)
	{
		diagMsg(toolName, "cannot combine --target-directory and --no-target-directory");
		tryHelp(toolName);
		return 1;
	}
	char** srcs = p.operands;
	size_t nSrc = p.count;
	const(char)* destDir = null;

	if (p.flags[iTargetDir])
	{
		destDir = p.values[iTargetDir];
	}
	else
	{
		if (nSrc == 0)
		{
			diagMsg(toolName, "missing file operand");
			tryHelp(toolName);
			return 1;
		}
		if (nSrc == 1)
		{
			diagQ(toolName, "missing destination file operand after ", fromC(srcs[0]), "", 0);
			tryHelp(toolName);
			return 1;
		}
		const last = srcs[nSrc - 1];
		stat_t st;
		if (!noTargetDir && fstatat(AT_FDCWD, last, &st, 0) == 0 && isDirMode(st.st_mode))
		{
			destDir = last;
		}
		--nSrc;
		if (destDir is null && (nSrc > 1 || noTargetDir && nSrc != 1))
		{
			if (noTargetDir)
			{
				diagQ(toolName, "extra operand ", fromC(srcs[1]), "", 0);
			}
			else
			{
				diagQ(toolName, "target ", fromC(last), " is not a directory", 0);
			}
			tryHelp(toolName);
			return 1;
		}
		if (destDir is null)
		{
			return moveOne(c, verbose, srcs[0], AT_FDCWD, last, fromC(srcs[0]), fromC(last)) ? 0 : 1;
		}
	}

	if (nSrc == 0)
	{
		diagMsg(toolName, "missing file operand");
		tryHelp(toolName);
		return 1;
	}

	const dfd = openat(AT_FDCWD, destDir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (dfd < 0)
	{
		diagQ(toolName, "target ", fromC(destDir), " is not a directory", 0);
		return 1;
	}

	const(char)[] dirText = fromC(destDir);
	size_t dend = dirText.length;
	while (dend > 1 && dirText[dend - 1] == '/')
	{
		--dend;
	}

	int rc = 0;
	Vec!char leaf, shown;
	foreach (i; 0 .. nSrc)
	{
		const(char)* s = srcs[i];
		leaf.truncate(0);
		must(leaf.append(baseName(fromC(s))));
		must(leaf.terminate());

		shown.truncate(0);
		must(shown.append(dirText[0 .. dend]));
		if (!(dend == 1 && dirText[0] == '/'))
		{
			must(shown.push('/'));
		}
		must(shown.append(leaf.data));

		if (!moveOne(c, verbose, s, dfd, leaf.data.ptr, fromC(s), shown.data))
		{
			rc = 1;
		}
	}
	close(dfd);
	return rc;
}

mixin StandaloneMain!run;
