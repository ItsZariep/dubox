module tools.cp;

// This file only decides *where* each operand goes, see common/copy.d.

import core.stdc.errno : errno;
import common.args;
import common.copy;
import common.cstr : baseName, fromC;
import common.entry : StandaloneMain;
import common.io : diagMsg, diagQ;
import common.sys;
import common.vec;

@nogc nothrow:

enum toolName = "cp";

static immutable ToolInfo info = ToolInfo(toolName,
	"cp [OPTION]... SOURCE DEST\n   or: cp [OPTION]... SOURCE... DIRECTORY\n"
	~ "   or: cp [OPTION]... -t DIRECTORY SOURCE...",
	"Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.");

static immutable Opt[] opts = [
	Opt('a', "archive", "same as -R -p (never follows symbolic links)"),
	Opt('f', "force", "if an existing destination cannot be opened, remove it and try again"),
	Opt('H', "", "follow command-line symbolic links in SOURCE"),
	Opt('L', "dereference", "always follow symbolic links in SOURCE"),
	Opt('n', "no-clobber", "do not overwrite an existing file"),
	Opt('P', "no-dereference", "never follow symbolic links in SOURCE (default with -R)"),
	Opt('p', "", "preserve mode, ownership and timestamps"),
	Opt('R', "recursive", "copy directories recursively"),
	Opt('r', "", "same as -R"),
	Opt('T', "no-target-directory", "treat DEST as a normal file"),
	Opt('t', "target-directory", "copy all SOURCE arguments into DIRECTORY", true),
	Opt('v', "verbose", "explain what is being done"),
];

enum iArchive = optIndex(opts, "archive");
enum iForce = optIndex(opts, "force");
enum iH = optIndexShort(opts, 'H');
enum iDeref = optIndex(opts, "dereference");
enum iNoClobber = optIndex(opts, "no-clobber");
enum iPreserve = optIndexShort(opts, 'p');
enum iRecursive = optIndex(opts, "recursive");
enum iLowerR = optIndexShort(opts, 'r');
enum iNoTargetDir = optIndex(opts, "no-target-directory");
enum iTargetDir = optIndex(opts, "target-directory");
enum iVerbose = optIndex(opts, "verbose");

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

	CopyCtx c;
	c.prog = toolName;
	c.recursive = p.flags[iRecursive] || p.flags[iLowerR] || p.flags[iArchive];
	c.preserve = p.flags[iPreserve] || p.flags[iArchive];
	c.force = p.flags[iForce];
	c.noClobber = p.flags[iNoClobber];
	c.verbose = p.flags[iVerbose];
	c.derefAll = p.flags[iDeref] && !p.flags[iArchive];
	c.derefTop = c.derefAll || p.flags[iH];
	c.umaskBits = umask(0);
	umask(c.umaskBits);

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
			// cp SRC NEWNAME: the destination string is resolved once, by the copy itself
			return copyTop(c, srcs[0], AT_FDCWD, last, fromC(srcs[0]), fromC(last)) ? 0 : 1;
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

		if (!copyTop(c, s, dfd, leaf.data.ptr, fromC(s), shown.data))
		{
			rc = 1;
		}
	}
	close(dfd);
	return rc;
}

mixin StandaloneMain!run;
