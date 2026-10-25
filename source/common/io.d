// Buffered output and diagnostics.
module common.io;

import core.stdc.errno : errno, EINTR;
import core.stdc.stdlib : exit;
import core.stdc.string : memcpy, strerror;
import core.sys.posix.unistd : write;
import common.cstr : fromC;

@nogc nothrow:

// Write the whole buffer, retrying on EINTR and short writes.
// Returns 0 on success or the errno of the failing write.
int writeAll(int fd, const(void)[] data) @trusted
{
	auto p = cast(const(ubyte)*) data.ptr;
	size_t left = data.length;
	while (left)
	{
		const n = write(fd, p, left);
		if (n < 0)
		{
			const e = errno;
			if (e == EINTR)
				continue;
			return e;
		}
		p += n;
		left -= cast(size_t) n;
	}
	return 0;
}

// Fixed-size output buffer bound to a file descriptor.
// Lives in .bss when used as a __gshared global, so it costs no binary size.
struct Out(size_t N)
{
	int fd;
	bool failed;
	int err;
	size_t len;
	ubyte[N] buf;

	void put(const(char)[] s) @trusted
	{
		if (s.length == 0) return;
		if (s.length > N - len)
		{
			flush();
			if (s.length >= N)
			{
				direct(s);
				return;
			}
		}
		memcpy(buf.ptr + len, s.ptr, s.length);
		len += s.length;
	}

	void putc(char c) @trusted
	{
		if (len == N)
			flush();
		buf[len++] = c;
	}

	void flush() @trusted
	{
		if (len)
		{
			direct(buf[0 .. len]);
			len = 0;
		}
	}

	private void direct(const(void)[] d) @trusted
	{
		if (failed) return;
		const e = writeAll(fd, d);
		if (e)
		{
			failed = true;
			err = e;
		}
	}
}

__gshared Out!(1 << 16) gout; // stdout
__gshared Out!4096 gerr; // stderr

void initIo()
{
	gout.fd = 1;
	gerr.fd = 2;
}

// Flush everything; turn a stdout write failure into a non-zero exit status.
int finishIo(int rc) @trusted
{
	gout.flush();
	if (rc == 0 && gout.failed)
	{
		gerr.put("write error: ");
		gerr.put(fromC(strerror(gout.err)));
		gerr.putc('\n');
		rc = 1;
	}
	gerr.flush();
	return rc;
}

// "prog: what 'path': strerror(err)" (err == 0 omits the reason)
void diag(const(char)[] prog, const(char)[] what, const(char)[] path, int err) @trusted
{
	gout.flush(); // keep stdout/stderr ordering sane on a terminal
	gerr.put(prog);
	gerr.put(": ");
	gerr.put(what);
	gerr.put(" '");
	gerr.put(path);
	gerr.put("'");
	if (err)
	{
		gerr.put(": ");
		gerr.put(fromC(strerror(err)));
	}
	gerr.putc('\n');
	gerr.flush();
}

// "prog: what: strerror(err)"
void diagErr(const(char)[] prog, const(char)[] what, int err) @trusted
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": ");
	gerr.put(what);
	if (err)
	{
		gerr.put(": ");
		gerr.put(fromC(strerror(err)));
	}
	gerr.putc('\n');
	gerr.flush();
}

// "prog: msg"
void diagMsg(const(char)[] prog, const(char)[] msg)
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": ");
	gerr.put(msg);
	gerr.putc('\n');
	gerr.flush();
}

// "prog: {head}'path'{tail}[: strerror(err)]"   e.g. cannot stat 'x': No such file or directory
void diagQ(const(char)[] prog, const(char)[] head, const(char)[] path, const(char)[] tail, int err) @trusted
{
	diagQ2(prog, head, path, "", "", tail, err, false);
}

// "prog: {head}'a'{mid}'b'{tail}[: strerror(err)]"   e.g. cannot move 'a' to 'b': Directory not empty
void diagQ2(const(char)[] prog, const(char)[] head, const(char)[] a, const(char)[] mid,
		const(char)[] b, const(char)[] tail, int err, bool withB = true) @trusted
{
	gout.flush();
	gerr.put(prog);
	gerr.put(": ");
	gerr.put(head);
	gerr.put("'");
	gerr.put(a);
	gerr.put("'");
	if (withB)
	{
		gerr.put(mid);
		gerr.put("'");
		gerr.put(b);
		gerr.put("'");
	}
	gerr.put(tail);
	if (err)
	{
		gerr.put(": ");
		gerr.put(fromC(strerror(err)));
	}
	gerr.putc('\n');
	gerr.flush();
}

// Print a fatal message and exit(1). Used for OOM.
void die(const(char)[] msg) @trusted
{
	diagMsg("dubox", msg);
	exit(1);
}

