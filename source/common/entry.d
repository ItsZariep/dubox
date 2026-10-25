// Glue that lets one tool source file become either a standalone binary or a
// member of the multicall binary, avoiding duplicated code.
module common.entry;

enum duboxVersion = "0.0.1";

// Mix this into a tool module: mixin StandaloneMain!run;

// default build: emits `main`, so `tools/ls.d` is a complete program
// -version=Multicall: emits nothing; `multicall.d` owns `main` and dispatches
mixin template StandaloneMain(alias run)
{
	version (Multicall) {}
	else
	{
		extern (C) int main(int argc, char** argv)
		{
			import common.io : initIo, finishIo;

			initIo();
			return finishIo(run(argc, argv));
		}
	}
}
