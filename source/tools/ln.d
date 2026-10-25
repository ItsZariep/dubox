module tools.ln;

// Links that go into a directory are created relative to one fd opened on that
// directory (linkat / symlinkat / unlinkat), so the directory string is resolved once.

import core.stdc.errno : errno, EEXIST, ENOENT, EPERM;
import common.args;
import common.cstr : baseName, eq, fromC;
import common.entry : StandaloneMain;
import common.io : gout, gerr, diag, diagMsg, diagQ, diagQ2;
import common.sys;
import common.vec;

@nogc nothrow:

enum toolName = "ln";

static immutable ToolInfo info = ToolInfo(toolName,
	"ln [OPTION]... TARGET LINK_NAME\n   or: ln [OPTION]... TARGET\n"
	~ "   or: ln [OPTION]... TARGET... DIRECTORY\n   or: ln [OPTION]... -t DIRECTORY TARGET...",
	"Create hard links by default, symbolic links with --symbolic.");

static immutable Opt[] opts = [
	Opt('f', "force", "remove existing destination files"),
	Opt('n', "no-dereference", "treat LINK_NAME as a normal file if it is a symbolic link to a directory"),
	Opt('r', "relative", "with -s, create links relative to link location"),
	Opt('s', "symbolic", "make symbolic links instead of hard links"),
	Opt('t', "target-directory", "specify the DIRECTORY in which to create the links", true),
	Opt('T', "no-target-directory", "treat LINK_NAME as a normal file always"),
	Opt('v', "verbose", "print name of each linked file"),
];

enum iForce = optIndex(opts, "force");
enum iNoDeref = optIndex(opts, "no-dereference");
enum iRel = optIndex(opts, "relative");
enum iSym = optIndex(opts, "symbolic");
enum iTargetDir = optIndex(opts, "target-directory");
enum iNoTargetDir = optIndex(opts, "no-target-directory");
enum iVerbose = optIndex(opts, "verbose");

private struct Cfg
{
	bool force, noDeref, rel, sym, verbose;
}

// relative path computation //

// Next path component of `s` at or after `pos`; returns false at the end.
private bool nextComp(const(char)[] s, ref size_t pos, ref size_t a, ref size_t b)
{
	while (pos < s.length && s[pos] == '/')
	{
		++pos;
	}
	if (pos >= s.length)
	{
		return false;
	}
	a = pos;
	while (pos < s.length && s[pos] != '/')
	{
		++pos;
	}
	b = pos;
	return true;
}

// Path that, read from directory `from`, names `to` (both absolute and canonical).
private void relativePath(const(char)[] from, const(char)[] to, ref Vec!char out_) @trusted
{
	size_t fp = 0, tp = 0, fa, fb, ta, tb;
	bool haveF = nextComp(from, fp, fa, fb);
	bool haveT = nextComp(to, tp, ta, tb);
	// skip the common leading components
	while (haveF && haveT && (fb - fa) == (tb - ta) && eq(from[fa .. fb], to[ta .. tb]))
	{
		haveF = nextComp(from, fp, fa, fb);
		haveT = nextComp(to, tp, ta, tb);
	}
	bool first = true;
	while (haveF)
	{
		if (!first)
		{
			must(out_.push('/'));
		}
		must(out_.append(".."));
		first = false;
		haveF = nextComp(from, fp, fa, fb);
	}
	while (haveT)
	{
		if (!first)
		{
			must(out_.push('/'));
		}
		must(out_.append(to[ta .. tb]));
		first = false;
		haveT = nextComp(to, tp, ta, tb);
	}
	if (first)
	{
		must(out_.push('.'));
	}
}

// Canonical form of `path` as a NUL-terminated string in `buf`. Null on failure.
private const(char)[] canon(const(char)[] path, ref char[4096] buf) @trusted
{
	Vec!char tmp;
	must(tmp.append(path));
	must(tmp.terminate());
	if (realpath(tmp.data.ptr, buf.ptr) is null)
	{
		return null;
	}
	return fromC(buf.ptr);
}

// Text for a symlink at `linkDir`/x that points at `target`, relative style.
private bool relativeTarget(const(char)[] target, const(char)[] linkDir, ref Vec!char out_) @trusted
{
	size_t end = target.length;
	while (end > 1 && target[end - 1] == '/')
	{
		--end;
	}
	target = target[0 .. end];
	if (target.length == 0)
	{
		return false;
	}

	char[4096] b1, b2;
	Vec!char abs;

	const(char)[] last = baseName(target);
	if (eq(last, ".") || eq(last, "..") || eq(last, "/"))
	{
		const c = canon(target, b1);
		if (c is null)
		{
			return false;
		}
		must(abs.append(c));
	}
	else
	{
		const dirLen = target.length - last.length;
		const(char)[] dirPart = dirLen == 0 ? "." : target[0 .. dirLen];
		const c = canon(dirPart, b1);
		if (c is null)
		{
			return false;
		}
		must(abs.append(c));
		if (!(c.length == 1 && c[0] == '/'))
		{
			must(abs.push('/'));
		}
		must(abs.append(last));
	}

	const l = canon(linkDir, b2);
	if (l is null)
	{
		return false;
	}
	relativePath(l, abs.data, out_);
	return true;
}

// the link itself //

private bool sameFile(ref const stat_t a, ref const stat_t b)
{
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

// Create `name` (relative to dfd) pointing at `target`.
// `linkShown` is the name as the user should see it; `linkDir` is where it lives (for -r).
private bool makeLink(ref const Cfg c, const(char)* target, int dfd, const(char)* name,
	const(char)[] linkShown, const(char)[] linkDir) @trusted
{
	const(char)[] tshown = fromC(target);
	Vec!char relText;
	const(char)* content = target;

	if (c.sym)
	{
		if (c.rel)
		{
			if (!relativeTarget(tshown, linkDir, relText))
			{
				diagQ(toolName, "cannot compute relative link for ", tshown, "", errno);
				return false;
			}
			must(relText.terminate());
			content = relText.data.ptr;
		}
	}
	else
	{
		stat_t sst;
		if (fstatat(AT_FDCWD, target, &sst, AT_SYMLINK_NOFOLLOW) != 0)
		{
			diag(toolName, "failed to access", tshown, errno);
			return false;
		}
		if (isDirMode(sst.st_mode))
		{
			diagQ(toolName, "", tshown, ": hard link not allowed for directory", 0);
			return false;
		}
	}

	int r = c.sym ? symlinkat(content, dfd, name) : linkat(AT_FDCWD, target, dfd, name, 0);
	int e = r == 0 ? 0 : errno;

	if (e == EEXIST && c.force)
	{
		stat_t dst;
		if (!c.sym)
		{
			stat_t sst;
			if (fstatat(AT_FDCWD, target, &sst, AT_SYMLINK_NOFOLLOW) == 0
					&& fstatat(dfd, name, &dst, AT_SYMLINK_NOFOLLOW) == 0 && sameFile(sst, dst))
			{
				diagQ2(toolName, "", linkShown, " and ", tshown, " are the same file", 0);
				return false;
			}
		}
		if (unlinkat(dfd, name, 0) != 0 && errno != ENOENT)
		{
			diag(toolName, "cannot remove", linkShown, errno);
			return false;
		}
		if (c.verbose)
		{
			gout.put("removed '");
			gout.put(linkShown);
			gout.put("'\n");
		}
		r = c.sym ? symlinkat(content, dfd, name) : linkat(AT_FDCWD, target, dfd, name, 0);
		e = r == 0 ? 0 : errno;
	}

	if (e)
	{
		if (c.sym)
		{
			diag(toolName, "failed to create symbolic link", linkShown, e);
		}
		else
		{
			diagQ2(toolName, "failed to create hard link ", linkShown, " => ", tshown, "", e);
		}
		return false;
	}

	if (c.verbose)
	{
		gout.put("'");
		gout.put(linkShown);
		gout.put(c.sym ? "' -> '" : "' => '");
		gout.put(c.sym ? fromC(content) : tshown);
		gout.put("'\n");
	}
	return true;
}

// Directory part of a path for -r: "a/b/c" -> "a/b", "x" -> ".", "/x" -> "/".
private const(char)[] dirOf(const(char)[] path)
{
	size_t end = path.length;
	while (end > 1 && path[end - 1] == '/')
	{
		--end;
	}
	while (end > 0 && path[end - 1] != '/')
	{
		--end;
	}
	while (end > 1 && path[end - 1] == '/')
	{
		--end;
	}
	if (end == 0)
	{
		return ".";
	}
	return path[0 .. end];
}

// Trailing-slash-free copy of `name`'s last component as a NUL-terminated string.
private void leafName(const(char)[] path, ref Vec!char out_)
{
	out_.truncate(0);
	must(out_.append(baseName(path)));
	must(out_.terminate());
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
	c.force = p.flags[iForce];
	c.noDeref = p.flags[iNoDeref];
	c.rel = p.flags[iRel];
	c.sym = p.flags[iSym];
	c.verbose = p.flags[iVerbose];
	const noTargetDir = p.flags[iNoTargetDir];

	if (p.flags[iTargetDir] && noTargetDir)
	{
		diagMsg(toolName, "cannot combine --target-directory and --no-target-directory");
		tryHelp(toolName);
		return 1;
	}

	char** targets = p.operands;
	size_t nTargets = p.count;
	const(char)* destDir = null;

	if (p.flags[iTargetDir])
	{
		destDir = p.values[iTargetDir];
	}
	else if (nTargets >= 2 && !noTargetDir)
	{
		stat_t st;
		const last = p.operands[nTargets - 1];
		if (fstatat(AT_FDCWD, last, &st, c.noDeref ? AT_SYMLINK_NOFOLLOW : 0) == 0 && isDirMode(st.st_mode))
		{
			destDir = last;
			--nTargets;
		}
	}

	if (nTargets == 0)
	{
		diagMsg(toolName, "missing file operand");
		tryHelp(toolName);
		return 1;
	}

	int rc = 0;
	Vec!char leaf, shown;

	if (destDir !is null)
	{
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
		foreach (i; 0 .. nTargets)
		{
			const(char)* t = targets[i];
			leafName(fromC(t), leaf);
			shown.truncate(0);
			must(shown.append(dirText[0 .. dend]));
			if (!(dend == 1 && dirText[0] == '/'))
			{
				must(shown.push('/'));
			}
			must(shown.append(leaf.data));
			if (!makeLink(c, t, dfd, leaf.data.ptr, shown.data, dirText[0 .. dend]))
			{
				rc = 1;
			}
		}
		close(dfd);
		return rc;
	}

	if (nTargets > 2)
	{
		diagQ(toolName, "target ", fromC(targets[nTargets - 1]), " is not a directory", 0);
		return 1;
	}

	const(char)* t = targets[0];
	if (nTargets == 1)
	{
		// ln TARGET: link named after TARGET's last component, in the current directory
		leafName(fromC(t), leaf);
		return makeLink(c, t, AT_FDCWD, leaf.data.ptr, leaf.data, ".") ? 0 : 1;
	}

	const(char)* linkName = targets[1];
	return makeLink(c, t, AT_FDCWD, linkName, fromC(linkName), dirOf(fromC(linkName))) ? 0 : 1;
}

mixin StandaloneMain!run;
