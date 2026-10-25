module tools.rmdir;

// A single unlinkat(AT_REMOVEDIR) per directory. With -p the parent chain is removed
// by string prefix, which is inherent to the option (the parents are no longer
// reachable through a held fd once the child is gone); nothing is ever
// *recursively* deleted, so a swapped path can at worst remove an empty directory.

import core.stdc.errno : errno, ENOTEMPTY, EEXIST;
import common.args;
import common.cstr : fromC;
import common.entry : StandaloneMain;
import common.io : gout, diag, diagMsg;
import common.sys;
import common.vec;

@nogc nothrow:

enum toolName = "rmdir";

static immutable ToolInfo info = ToolInfo(toolName, "rmdir [OPTION]... DIRECTORY...",
	"Remove the DIRECTORY(ies), if they are empty.");

static immutable Opt[] opts = [
	Opt('\0', "ignore-fail-on-non-empty", "ignore each failure that is solely because a directory is non-empty"),
	Opt('p', "parents", "remove DIRECTORY and its ancestors; e.g., 'rmdir -p a/b' is like 'rmdir a/b a'"),
	Opt('v', "verbose", "output a diagnostic for every directory processed"),
];

enum iIgnore = optIndex(opts, "ignore-fail-on-non-empty");
enum iParents = optIndex(opts, "parents");
enum iVerbose = optIndex(opts, "verbose");

private bool isNonEmptyError(int e)
{
	return e == ENOTEMPTY || e == EEXIST;
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

	const ignoreNonEmpty = p.flags[iIgnore];
	const parents = p.flags[iParents];
	const verbose = p.flags[iVerbose];

	if (p.count == 0)
	{
		diagMsg(toolName, "missing operand");
		tryHelp(toolName);
		return 1;
	}

	int rc = 0;
	Vec!char buf;

	foreach (i; 0 .. p.count)
	{
		buf.truncate(0);
		must(buf.append(fromC(p.operands[i])));
		// "a/b//" -> "a/b" (but keep a lone "/")
		size_t len = buf.length;
		while (len > 1 && buf.data[len - 1] == '/')
		{
			--len;
		}
		buf.truncate(len);

		for (;;)
		{
			must(buf.terminate());
			if (verbose)
			{
				gout.put("rmdir: removing directory, '");
				gout.put(buf.data);
				gout.put("'\n");
			}
			if (unlinkat(AT_FDCWD, buf.data.ptr, AT_REMOVEDIR) != 0)
			{
				const e = errno;
				if (!(ignoreNonEmpty && isNonEmptyError(e)))
				{
					diag(toolName, "failed to remove", buf.data, e);
					rc = 1;
				}
				break;
			}
			if (!parents)
			{
				break;
			}

			// climb: drop the last component and any slashes before it
			size_t cut = buf.length;
			while (cut > 0 && buf.data[cut - 1] != '/')
			{
				--cut;
			}
			if (cut == 0)
			{
				break; // no parent component left
			}
			while (cut > 0 && buf.data[cut - 1] == '/')
			{
				--cut;
			}
			if (cut == 0)
			{
				break; // parent is the root
			}
			buf.truncate(cut);
		}
	}
	return rc;
}

mixin StandaloneMain!run;
