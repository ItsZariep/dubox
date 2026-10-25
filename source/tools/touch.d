module tools.touch;

// Supported time sources: now (default), -r FILE, -t [[CC]YY]MMDDhhmm[.ss],
// -d '@EPOCH' | 'YYYY-MM-DD[ hh:mm[:ss]]' (the full GNU date grammar is not implemented).

import core.stdc.errno : errno, ENOENT;
import core.stdc.string : memset;
import core.stdc.time : time, time_t, tm, mktime, localtime;
import common.args;
import common.cstr : eq, fromC, parseDecimal;
import common.entry : StandaloneMain;
import common.io : diag, diagMsg;
import common.sys;

@nogc nothrow:

enum toolName = "touch";

static immutable ToolInfo info = ToolInfo(toolName, "touch [OPTION]... FILE...",
	"Update the access and modification times of each FILE to the current time.\n"
	~ "A FILE argument that does not exist is created empty, unless -c or -h is supplied.\n"
	~ "A FILE argument string of - is handled specially and causes touch to change the\n"
	~ "times of the file associated with standard output.");

static immutable Opt[] opts = [
	Opt('a', "", "change only the access time"),
	Opt('c', "no-create", "do not create any files"),
	Opt('d', "date", "parse STRING and use it instead of current time", true),
	Opt('h', "no-dereference", "affect each symbolic link instead of any referenced file"),
	Opt('m', "", "change only the modification time"),
	Opt('r', "reference", "use this file's times instead of current time", true),
	Opt('t', "", "use [[CC]YY]MMDDhhmm[.ss] instead of current time", true),
];

enum iA = optIndexShort(opts, 'a');
enum iC = optIndex(opts, "no-create");
enum iD = optIndex(opts, "date");
enum iH = optIndex(opts, "no-dereference");
enum iM = optIndexShort(opts, 'm');
enum iR = optIndex(opts, "reference");
enum iT = optIndexShort(opts, 't');

// date parsing //

private bool digits(const(char)[] s, size_t pos, size_t n, ref int v)
{
	if (pos + n > s.length)
	{
		return false;
	}
	int r = 0;
	foreach (i; 0 .. n)
	{
		const c = s[pos + i];
		if (c < '0' || c > '9')
		{
			return false;
		}
		r = r * 10 + (c - '0');
	}
	v = r;
	return true;
}

// Local time broken-down fields -> seconds since the epoch.
private bool toEpoch(int yr, int mo, int dy, int hh, int mi, int ss, ref long out_) @trusted
{
	if (mo < 1 || mo > 12 || dy < 1 || dy > 31 || hh > 23 || mi > 59 || ss > 60)
	{
		return false;
	}
	tm t;
	memset(&t, 0, t.sizeof);
	t.tm_year = yr - 1900;
	t.tm_mon = mo - 1;
	t.tm_mday = dy;
	t.tm_hour = hh;
	t.tm_min = mi;
	t.tm_sec = ss;
	t.tm_isdst = -1;
	const time_t r = mktime(&t);
	if (r == cast(time_t)-1)
	{
		return false;
	}
	out_ = r;
	return true;
}

// -t [[CC]YY]MMDDhhmm[.ss]
private bool parseStamp(const(char)[] s, ref long out_) @trusted
{
	int ss = 0;
	if (s.length >= 3 && s[s.length - 3] == '.')
	{
		if (!digits(s, s.length - 2, 2, ss))
		{
			return false;
		}
		s = s[0 .. s.length - 3];
	}
	const n = s.length;
	if (n != 8 && n != 10 && n != 12)
	{
		return false;
	}
	size_t i = 0;
	int yr;
	if (n == 12)
	{
		if (!digits(s, 0, 4, yr))
		{
			return false;
		}
		i = 4;
	}
	else if (n == 10)
	{
		int yy;
		if (!digits(s, 0, 2, yy))
		{
			return false;
		}
		yr = yy >= 69 ? 1900 + yy : 2000 + yy;
		i = 2;
	}
	else
	{
		time_t now = time(null);
		yr = localtime(&now).tm_year + 1900;
	}
	int mo, dy, hh, mi;
	if (!digits(s, i, 2, mo) || !digits(s, i + 2, 2, dy) || !digits(s, i + 4, 2, hh)
			|| !digits(s, i + 6, 2, mi))
	{
		return false;
	}
	return toEpoch(yr, mo, dy, hh, mi, ss, out_);
}

// -d '@N' | 'YYYY-MM-DD' | 'YYYY-MM-DD hh:mm[:ss]' (also with 'T')
private bool parseDate(const(char)[] s, ref long out_) @trusted
{
	if (s.length > 1 && s[0] == '@')
	{
		return parseDecimal(s[1 .. $], out_);
	}
	int yr, mo, dy;
	if (s.length < 10 || !digits(s, 0, 4, yr) || s[4] != '-' || !digits(s, 5, 2, mo)
			|| s[7] != '-' || !digits(s, 8, 2, dy))
	{
		return false;
	}
	int hh = 0, mi = 0, ss = 0;
	if (s.length > 10)
	{
		if ((s[10] != ' ' && s[10] != 'T') || s.length < 16 || !digits(s, 11, 2, hh)
				|| s[13] != ':' || !digits(s, 14, 2, mi))
		{
			return false;
		}
		if (s.length == 19)
		{
			if (s[16] != ':' || !digits(s, 17, 2, ss))
			{
				return false;
			}
		}
		else if (s.length != 16)
		{
			return false;
		}
	}
	return toEpoch(yr, mo, dy, hh, mi, ss, out_);
}

// the work //

private bool touchOne(const(char)* path, ref timespec[2] ts, bool noCreate, bool noDeref) @trusted
{
	int e = 0;
	const int lflag = noDeref ? AT_SYMLINK_NOFOLLOW : 0;

	if (path[0] == '-' && path[1] == '\0')
	{
		if (futimens(1, ts.ptr) != 0)
		{
			diagMsg(toolName, "failed to touch standard output");
			return false;
		}
		return true;
	}

	if (noCreate)
	{
		if (utimensat(AT_FDCWD, path, ts.ptr, lflag) != 0)
		{
			e = errno;
			if (e == ENOENT)
			{
				return true; // -c: a missing file is not an error
			}
		}
	}
	else if (noDeref)
	{
		if (utimensat(AT_FDCWD, path, ts.ptr, AT_SYMLINK_NOFOLLOW) != 0)
		{
			e = errno;
			if (e == ENOENT)
			{
				e = 0;
				const fd = openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_EXCL | O_NOCTTY | O_CLOEXEC, 0x1B6 /* 0666 */ );
				if (fd < 0)
				{
					e = errno;
				}
				else
				{
					if (futimens(fd, ts.ptr) != 0)
					{
						e = errno;
					}
					close(fd);
				}
			}
		}
	}
	else
	{
		const fd = openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_NONBLOCK | O_NOCTTY | O_CLOEXEC, 0x1B6);
		if (fd >= 0)
		{
			if (futimens(fd, ts.ptr) != 0)
			{
				e = errno;
			}
			close(fd);
		}
		else
		{
			// directories, read-only files, etc. change the times without opening for write
			const openErr = errno;
			if (utimensat(AT_FDCWD, path, ts.ptr, 0) != 0)
			{
				e = errno == ENOENT ? openErr : errno;
			}
		}
	}

	if (e)
	{
		diag(toolName, "cannot touch", fromC(path), e);
		return false;
	}
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

	const noDeref = p.flags[iH];

	// at most one time source (-d, -r, -t)
	const sources = (p.flags[iD] ? 1 : 0) + (p.flags[iR] ? 1 : 0) + (p.flags[iT] ? 1 : 0);
	if (sources > 1)
	{
		diagMsg(toolName, "cannot specify times from more than one source");
		tryHelp(toolName);
		return 1;
	}

	timespec[2] ts;
	ts[0].tv_nsec = UTIME_NOW;
	ts[1].tv_nsec = UTIME_NOW;

	if (p.flags[iR])
	{
		stat_t st;
		const path = p.values[iR];
		if (fstatat(AT_FDCWD, path, &st, noDeref ? AT_SYMLINK_NOFOLLOW : 0) != 0)
		{
			diag(toolName, "failed to get attributes of", fromC(path), errno);
			return 1;
		}
		ts[0] = atimeOf(st);
		ts[1] = mtimeOf(st);
	}
	else if (p.flags[iD] || p.flags[iT])
	{
		long secs;
		if (p.flags[iT])
		{
			if (!parseStamp(fromC(p.values[iT]), secs))
			{
				diag(toolName, "invalid date format", fromC(p.values[iT]), 0);
				return 1;
			}
		}
		else if (!parseDate(fromC(p.values[iD]), secs))
		{
			diag(toolName, "invalid date format", fromC(p.values[iD]), 0);
			return 1;
		}
		ts[0].tv_sec = secs;
		ts[0].tv_nsec = 0;
		ts[1] = ts[0];
	}

	const onlyA = p.flags[iA] && !p.flags[iM];
	const onlyM = p.flags[iM] && !p.flags[iA];
	if (onlyA)
	{
		ts[1].tv_nsec = UTIME_OMIT;
	}
	if (onlyM)
	{
		ts[0].tv_nsec = UTIME_OMIT;
	}

	if (p.count == 0)
	{
		diagMsg(toolName, "missing file operand");
		tryHelp(toolName);
		return 1;
	}

	int rc = 0;
	foreach (i; 0 .. p.count)
	{
		if (!touchOne(p.operands[i], ts, p.flags[iC], noDeref))
		{
			rc = 1;
		}
	}
	return rc;
}

mixin StandaloneMain!run;
