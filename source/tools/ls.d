module tools.ls;

import common.args;
import common.cstr : fromC, isDotOrDotDot;
import common.entry : StandaloneMain;
import common.io : diag, gout;
import common.sys;
import common.vec;
import core.stdc.errno : errno;
import core.stdc.string : strcmp, strlen;

@nogc nothrow:

enum toolName = "ls";

static immutable ToolInfo info = ToolInfo(toolName, "ls [OPTION]... [FILE]...",
	"List information about the FILEs (the current directory by default).\n"
	~ "Entries are sorted bytewise (like LC_ALL=C), one per line.");

static immutable Opt[] opts = [
	Opt('a', "all", "do not ignore entries starting with ."),
	Opt('A', "almost-all", "do not list implied . and .."),
	Opt('d', "directory", "list directories themselves, not their contents"),
	Opt('F', "classify", "append indicator (one of */@|=) to entries"),
	Opt('r', "reverse", "reverse order while sorting"),
	Opt('U', "", "do not sort; list entries in directory order"),
	Opt('1', "", "list one file per line (always on in this build)"),
];

// Option indices are computed at compile time: a typo here is a compile error.
enum iAll = optIndex(opts, "all");
enum iAlmost = optIndex(opts, "almost-all");
enum iDirectory = optIndex(opts, "directory");
enum iClassify = optIndex(opts, "classify");
enum iReverse = optIndex(opts, "reverse");
enum iUnsorted = optIndexShort(opts, 'U');

struct Flags
{
	bool all, almost, dirOnly, classify, reverse, unsorted;
}

// sorting //

struct Entry
{
	size_t off; // offset of the NUL-terminated name inside the arena
	ubyte type; // d_type from readdir
}

// qsort() comparators get no context pointer, so the arena base is a global.
__gshared const(char)* gBase;

extern (C) int cmpAsc(const(void)* a, const(void)* b) @trusted nothrow @nogc
{
	const x = cast(const(Entry)*) a;
	const y = cast(const(Entry)*) b;
	return strcmp(gBase + x.off, gBase + y.off);
}

extern (C) int cmpDesc(const(void)* a, const(void)* b) @trusted nothrow @nogc
{
	return cmpAsc(b, a);
}

// -F support //

private char modeChar(uint mode)
{
	switch (mode & S_IFMT)
	{
		case S_IFDIR:
			return '/';
		case S_IFLNK:
			return '@';
		case S_IFIFO:
			return '|';
		case S_IFSOCK:
			return '=';
		case S_IFREG:
			return (mode & 0b001_001_001) ? '*' : '\0';
		default:
			return '\0';
	}
}

// Use d_type when it is conclusive; fall back to fstatat() only when needed
// (regular files, to see the exec bit, or file systems that report DT_UNKNOWN).
private char classifyChar(int dirFd, const(char)* name, ubyte type) @trusted
{
	switch (type)
	{
		case DT_DIR:
			return '/';
		case DT_LNK:
			return '@';
		case DT_FIFO:
			return '|';
		case DT_SOCK:
			return '=';
		case DT_CHR, DT_BLK:
			return '\0';
		default:
			stat_t st;
			if (fstatat(dirFd, name, &st, AT_SYMLINK_NOFOLLOW) != 0)
				return '\0';
			return modeChar(st.st_mode);
	}
}

// listing //

private bool hidden(const(char)* name, ref const Flags f) @trusted
{
	if (name[0] != '.' || f.all) return false;
	if (!f.almost) return true; // default: hide every dot-name
	return isDotOrDotDot(name); // -A: hide only "." and ".."
}

private int listDir(const(char)* path, ref const Flags f) @trusted
{
	DIR* d = opendir(path);
	if (d is null)
	{
		diag(toolName, "cannot open directory", fromC(path), errno);
		return 2;
	}

	const stream = f.unsorted && !f.classify;
	Vec!char arena; // all names, NUL-terminated, back to back
	Vec!Entry ents;

	for (;;)
	{
		errno = 0; // can tell "end of directory" from "error"
		dirent* de = readdir(d);
		if (de is null)
			break;
		const(char)* nm = de.d_name.ptr;
		if (hidden(nm, f))
			continue;
		if (stream)
		{
			gout.put(fromC(nm));
			gout.putc('\n');
			continue;
		}
		const off = arena.length;
		must(arena.append(nm[0 .. strlen(nm) + 1]));
		must(ents.push(Entry(off, de.d_type)));
	}
	int rc = 0;
	if (errno != 0)
	{
		diag(toolName, "error reading directory", fromC(path), errno);
		rc = 2;
	}

	if (!stream)
	{
		if (!f.unsorted && ents.length > 1)
		{
			gBase = arena.data.ptr;
			qsort(ents.data.ptr, ents.length, Entry.sizeof, f.reverse ? &cmpDesc : &cmpAsc);
		}
		foreach (ref e; ents.data)
		{
			const(char)* nm = arena.data.ptr + e.off;
			gout.put(fromC(nm));
			if (f.classify)
			{
				const c = classifyChar(dirfd(d), nm, e.type);
				if (c != '\0')
					gout.putc(c);
			}
			gout.putc('\n');
		}
	}
	closedir(d);
	return rc;
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
		return 2;
	}

	Flags f;
	f.all = p.flags[iAll];
	f.almost = p.flags[iAlmost];
	f.dirOnly = p.flags[iDirectory];
	f.classify = p.flags[iClassify];
	f.reverse = p.flags[iReverse];
	f.unsorted = p.flags[iUnsorted];

	if (p.count == 0)
		return listDir(".", f);

	int rc = 0;
	bool printedAny = false;

	// operands that are not listed as directories
	foreach (i; 0 .. p.count)
	{
		const(char)* path = p.operands[i];
		stat_t st;
		if (fstatat(AT_FDCWD, path, &st, 0) != 0)
		{
			diag(toolName, "cannot access", fromC(path), errno);
			rc = 2;
			continue;
		}
		if (!f.dirOnly && isDirMode(st.st_mode))
			continue;
		gout.put(fromC(path));
		if (f.classify)
		{
			const c = modeChar(st.st_mode);
			if (c != '\0')
				gout.putc(c);
		}
		gout.putc('\n');
		printedAny = true;
	}

	// directories, with "name:" headers when there is more than one operand.
	if (!f.dirOnly)
	{
		foreach (i; 0 .. p.count)
		{
			const(char)* path = p.operands[i];
			stat_t st;
			if (fstatat(AT_FDCWD, path, &st, 0) != 0 || !isDirMode(st.st_mode))
				continue;
			if (p.count > 1)
			{
				if (printedAny)
					gout.putc('\n');
				gout.put(fromC(path));
				gout.put(":\n");
			}
			printedAny = true;
			const r = listDir(path, f);
			if (r > rc)
				rc = r;
		}
	}
	return rc;
}

mixin StandaloneMain!run;
