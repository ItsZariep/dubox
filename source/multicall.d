/*
	busybox-style entry point: one binary, many tools.

	dubox ls -a # explicit
	ln -s dubox ls; ./ls -a # by argv[0]

	Build with `-version=Multicall` so the tool modules do not emit their own main().
*/
module multicall;

version (Multicall) {}
else
{
	static assert(0, "multicall.d must be built with -version=Multicall");
}

import common.cstr : baseName, eq, fromC;
import common.entry : duboxVersion;
import common.io : diagMsg, finishIo, gerr, initIo;

// File & Directory Management
static import tools.cp, tools.ln, tools.mkdir, tools.mv, tools.rmdir, tools.touch, tools.ls, tools.rm;

// Input/Output & Pipeline Control
static import tools.yes;

@nogc nothrow:

alias AliasSeq(T...) = T;

// Add a tool = add its module here (and to the Makefile TOOLS list).
alias Tools = AliasSeq!(tools.yes, tools.ls, tools.rm,
	tools.cp, tools.ln, tools.mkdir, tools.mv, tools.rmdir, tools.touch);

private void usage()
{
	gerr.put("dubox ");
	gerr.put(duboxVersion);
	gerr.put(" (multicall)\nUsage: dubox TOOL [ARGS]...\nTools:");
	static foreach (m; Tools)
	{
		gerr.putc(' ');
		gerr.put(m.info.name);
	}
	gerr.putc('\n');
	gerr.flush();
}

private int dispatch(int argc, char** argv) @trusted
{
	auto name = baseName(fromC(argv[0]));
	if (eq(name, "dubox"))
	{
		if (argc < 2)
		{
			usage();
			return 1;
		}
		++argv;
		--argc;
		name = fromC(argv[0]);
	}

	// `static foreach` unrolls this into a chain of ifs at compile time.
	static foreach (m; Tools)
	{
		if (eq(name, m.info.name))
		{
			return m.run(argc, argv);
		}
	}

	diagMsg("dubox", "unknown tool");
	usage();
	return 127;
}

extern (C) int main(int argc, char** argv)
{
	initIo();
	return finishIo(dispatch(argc, argv));
}
