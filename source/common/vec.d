// A tiny growable array on the C heap.
module common.vec;

import core.checkedint : addu, mulu;
import core.stdc.stdlib : free, realloc;
import core.stdc.string : memcpy, memset;
import common.io : die;

@nogc nothrow:

struct Vec(T)
{
	private T* ptr_;
	private size_t len_;
	private size_t cap_;

	@disable this(this); // no accidental copies => no double free

	~this() @trusted
	{
		free(ptr_);
	}

	size_t length() const pure @safe
	{
		return len_;
	}

	inout(T)[] data() inout @trusted
	{
		return ptr_[0 .. len_];
	}

	// Ensure room for `want` elements. Returns false on overflow / OOM.
	bool reserve(size_t want) @trusted
	{
		if (want <= cap_) return true;

		size_t n = cap_ ? cap_ : 64;
		while (n < want)
		{
			if (n > size_t.max / 2)
				return false;
			n *= 2;
		}

		bool overflow;
		const bytes = mulu(n, T.sizeof, overflow);
		if (overflow) return false;

		auto p = cast(T*) realloc(ptr_, bytes);
		if (p is null) return false;
		ptr_ = p;
		cap_ = n;
		return true;
	}

	bool push(T v) @trusted
	{
		if (!reserve(len_ + 1))
			return false;
		ptr_[len_++] = v;
		return true;
	}

	bool append(const(T)[] s) @trusted
	{
		if (s.length == 0) return true;
		bool overflow;
		const want = addu(len_, s.length, overflow);
		if (overflow || !reserve(want)) return false;
		memcpy(ptr_ + len_, s.ptr, s.length * T.sizeof);
		len_ = want;
		return true;
	}

	void truncate(size_t n) @safe
	{
		if (n < len_)
			len_ = n;
	}

	// Make `data.ptr[length]` an all-zero element without growing `length`.
	// For `Vec!char` this gives a NUL-terminated C string.
	// (Zero bytes on purpose: in D, `char.init` is 0xFF, not '\0'.)
	bool terminate() @trusted
	{
		if (!reserve(len_ + 1)) return false;
		memset(ptr_ + len_, 0, T.sizeof);
		return true;
	}
}

// Abort on allocation failure. Wrap Vec calls: `must(v.push(x));`
void must(bool ok)
{
	if (!ok)
	{
		die("memory exhausted");
	}
}
