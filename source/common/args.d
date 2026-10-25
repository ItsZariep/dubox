/*
	Declarative command-line parsing shared by every tool.

	A tool declares its options as *data* (`static immutable Opt[] opts`);
	the parser, `--help` text and flag lookup are all generated from that
	table with templates and CTFE. Nothing here allocates.
*/

module common.args;

import common.cstr : eq, fromC;
import common.entry : duboxVersion;
import common.io : gout, gerr;

@nogc nothrow:

struct Opt
{
	char shortName; // '\0' if none
	string longName; //  "" if none
	string help;
	bool hasArg = false; // option takes a value: -m MODE, -mMODE, --mode=MODE, --mode MODE
}

struct ToolInfo
{
	string name;
	string usage;
	string summary;
}

enum ParseResult
{
	ok, // carry on
	stop, //--help / --version was handled; exit 0
	bad, // diagnostic already printed; exit with the tool's usage-error status
}

// Result of parsing: one flag per declared option, plus the operands.
struct Parsed(size_t N)
{
	bool[N] flags;
	const(char)*[N] values; // value of each hasArg option (null if absent); points into argv
	char** operands; // points into argv (compacted in place)
	size_t count;
}

// compile-time option lookup //

private bool sameString(string a, string b) pure @safe
{
	if (a.length != b.length)
	{
		return false;
	}
	foreach (i; 0 .. a.length)
	{
		if (a[i] != b[i])
		{
			return false;
		}
	}
	return true;
}

// Index of an option by long name, resolved at compile time:
// enum iForce = optIndex(opts, "force"); // a typo is a compile error
size_t optIndex(immutable(Opt)[] opts, string longName) pure @safe
{
	foreach (i, ref o; opts)
	{
		if (o.longName.length != 0 && sameString(o.longName, longName))
		{
			return i;
		}
	}
	assert(0, "no option with that long name");
}

// Same, for options that only have a short name.
size_t optIndexShort(immutable(Opt)[] opts, char shortName) pure @safe
{
	foreach (i, ref o; opts)
	{
		if (o.shortName == shortName)
			return i;
	}
	assert(0, "no option with that short name");
}

// diagnostics //

void tryHelp(const(char)[] prog)
{
	gerr.put("Try '");
	gerr.put(prog);
	gerr.put(" --help' for more information.\n");
	gerr.flush();
}

private void badShort(const(char)[] prog, char c)
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": invalid option -- '");
	gerr.putc(c);
	gerr.put("'\n");
	tryHelp(prog);
}

private void badLong(const(char)[] prog, const(char)* arg) @trusted
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": unrecognized option '");
	gerr.put(fromC(arg));
	gerr.put("'\n");
	tryHelp(prog);
}

private void badNeedsArgLong(const(char)[] prog, const(char)[] name) @trusted
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": option '--");
	gerr.put(name);
	gerr.put("' requires an argument\n");
	tryHelp(prog);
}

private void badNoArgLong(const(char)[] prog, const(char)[] name) @trusted
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": option '--");
	gerr.put(name);
	gerr.put("' doesn't allow an argument\n");
	tryHelp(prog);
}

private void badNeedsArgShort(const(char)[] prog, char c)
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": option requires an argument -- '");
	gerr.putc(c);
	gerr.put("'\n");
	tryHelp(prog);
}

private void optLine(char s, const(char)[] l, const(char)[] help, bool hasArg = false)
{
	size_t col = 2;
	gout.put(" ");
	if (s != '\0')
	{
		gout.putc('-');
		gout.putc(s);
		col += 2;
		if (l.length)
		{
			gout.put(", ");
			col += 2;
		}
	}
	else
	{
		gout.put(" ");
		col += 4;
	}
	if (l.length)
	{
		gout.put("--");
		gout.put(l);
		col += 2 + l.length;
		if (hasArg)
		{
			gout.put("=ARG");
			col += 4;
		}
	}
	else if (hasArg)
	{
		gout.put(" ARG");
		col += 4;
	}
	do
	{
		gout.putc(' ');
		++col;
	}
	while (col < 30);
	gout.put(help);
	gout.putc('\n');
}

private void printVersion(alias info)()
{
	gout.put(info.name);
	gout.put(" (dubox) ");
	gout.put(duboxVersion);
	gout.put("\n");
}

private void printHelp(alias opts, alias info)()
{
	printVersion!info();
	gout.put("Usage: ");
	gout.put(info.usage);
	gout.put("\n");
	gout.put(info.summary);
	gout.put("\n\n");
	foreach (ref o; opts)
	{
		optLine(o.shortName, o.longName, o.help, o.hasArg);
	}
	optLine('\0', "help", "display this help and exit");
	optLine('\0', "version", "output version information and exit");
}

// the parser //

ParseResult parse(alias opts, alias info, size_t N)(int argc, char** argv, ref Parsed!N p) @trusted
{
	size_t nOps = 0;
	bool endOfOptions = false;

	for (int i = 1; i < argc; ++i)
	{
		char* a = argv[i];

		if (endOfOptions || a[0] != '-' || a[1] == '\0')
		{
			argv[1 + nOps] = a; // safe: write index is always < read index
			++nOps;
			continue;
		}

		if (a[1] == '-')
		{
			const(char)[] s = fromC(a + 2);
			if (s.length == 0)
			{
				endOfOptions = true;
				continue;
			}
			if (eq(s, "help"))
			{
				printHelp!(opts, info)();
				return ParseResult.stop;
			}
			if (eq(s, "version"))
			{
				printVersion!info();
				return ParseResult.stop;
			}
			size_t eqAt = s.length; // position of '=' in --name=value
			foreach (k; 0 .. s.length)
			{
				if (s[k] == '=')
				{
					eqAt = k;
					break;
				}
			}
			const(char)[] name = s[0 .. eqAt];
			const bool hasEq = eqAt < s.length;
			bool found = false;
			foreach (idx, ref o; opts)
			{
				if (o.longName.length != 0 && eq(name, o.longName))
				{
					found = true;
					if (o.hasArg)
					{
						if (hasEq)
						{
							p.values[idx] = a + 2 + eqAt + 1;
						}
						else if (i + 1 < argc)
						{
							p.values[idx] = argv[++i];
						}
						else
						{
							badNeedsArgLong(info.name, name);
							return ParseResult.bad;
						}
					}
					else if (hasEq)
					{
						badNoArgLong(info.name, name);
						return ParseResult.bad;
					}
					p.flags[idx] = true;
					break;
				}
			}
			if (!found)
			{
				badLong(info.name, a);
				return ParseResult.bad;
			}
		}
		else
		{
			for (const(char)* c = a + 1; *c != '\0'; ++c)
			{
				bool found = false;
				bool restIsValue = false;
				foreach (idx, ref o; opts)
				{
					if (o.shortName != '\0' && o.shortName == *c)
					{
						found = true;
						p.flags[idx] = true;
						if (o.hasArg)
						{
							if (c[1] != '\0')
							{
								p.values[idx] = c + 1; // -mVALUE
							}
							else if (i + 1 < argc)
							{
								p.values[idx] = argv[++i]; // -m VALUE
							}
							else
							{
								badNeedsArgShort(info.name, *c);
								return ParseResult.bad;
							}
							restIsValue = true;
						}
						break;
					}
				}
				if (!found)
				{
					badShort(info.name, *c);
					return ParseResult.bad;
				}
				if (restIsValue)
				{
					break; // the rest of this argv word was the value
				}
			}
		}
	}

	p.operands = argv + 1;
	p.count = nOps;
	return ParseResult.ok;
}
