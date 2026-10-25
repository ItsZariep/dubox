/*
	Strategy: build chunk containing the line repeated many times, then call
	write(2) on that chunk in a loop. No per-line work, no stdio, no allocation
	after setup.

	Chunk size matters more than it looks.
	4-8 KiB chunks pushed ~2.6 GB/s through a pipe, 64 KiB only ~1.45 GB/s.
	A write as large as the pipe (64 KiB) forces writer and reader to take turns;
	small writes let them overlap. So bigger is not automatically faster.
*/

module tools.yes;

import common.args;
import common.entry : StandaloneMain;
import common.io : diagErr, diagMsg, writeAll;
import core.checkedint : addu;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, strlen;

@nogc nothrow:

enum toolName = "yes";

static immutable ToolInfo info = ToolInfo(toolName, "yes [STRING]...\n  or:  yes OPTION",
	"Repeatedly output a line with all specified STRING(s), or 'y'.");

static immutable Opt[] opts = [];

enum chunkTarget = 8 * 1024; // see the note at the top before changing this

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

	// Line length: every operand is followed by ' ' or, for the last one, '\n'.
	size_t lineLen = 2; // "y\n"
	if (p.count != 0)
	{
		lineLen = 0;
		bool overflow = false;
		foreach (i; 0 .. p.count)
			lineLen = addu(lineLen, strlen(p.operands[i]) + 1, overflow);
		if (overflow)
		{
			diagMsg(toolName, "argument list too long");
			return 1;
		}
	}

	const copies = lineLen >= chunkTarget ? 1 : chunkTarget / lineLen;
	const total = copies * lineLen; // never overflows: copies * lineLen <= chunkTarget or == lineLen
	auto buf = cast(char*) malloc(total);
	if (buf is null)
	{
		diagMsg(toolName, "memory exhausted");
		return 1;
	}

	// Write the first line
	if (p.count == 0)
	{
		buf[0] = 'y';
		buf[1] = '\n';
	}
	else
	{
		size_t off = 0;
		foreach (i; 0 .. p.count)
		{
			const n = strlen(p.operands[i]);
			memcpy(buf + off, p.operands[i], n);
			off += n;
			buf[off++] = (i + 1 == p.count) ? '\n' : ' ';
		}
	}

	//  double the line until the chunk is full (log2(copies) memcpy calls).
	size_t filled = lineLen;
	while (filled < total)
	{
		const n = filled < total - filled ? filled : total - filled;
		memcpy(buf + filled, buf, n);
		filled += n;
	}

	int err;
	while ((err = writeAll(1, buf[0 .. total])) == 0)
	{}
	diagErr(toolName, "standard output", err);
	free(buf);
	return 1;
}

mixin StandaloneMain!run;
