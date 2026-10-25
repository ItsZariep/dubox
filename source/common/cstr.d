// C-string and slice helpers.
// Everything here should be @nogc nothrow and betterC-safe.
module common.cstr;

import core.stdc.string : memcmp, strlen;

@nogc nothrow:

// View a NUL terminated C string as a D slice (no copy, no allocation).
const(char)[] fromC(const(char)* p) @trusted
{
	return p[0 .. strlen(p)];
}

// Byte-wise slice equality that does not depend on druntime's array hooks.
bool eq(const(char)[] a, const(char)[] b) @trusted
{
	return a.length == b.length && (a.length == 0 || memcmp(a.ptr, b.ptr, a.length) == 0);
}

// Last path component, ignoring trailing slashes ("a/b//" -> "b"; "/" -> "/").
const(char)[] baseName(const(char)[] path)
{
	size_t end = path.length;
	while (end > 1 && path[end - 1] == '/')
	{
		--end;
	}
	if (end == 1 && path[0] == '/')
	{
		return path[0 .. 1];
	}
	size_t start = end;
	while (start > 0 && path[start - 1] != '/')
	{
		--start;
	}
	return path[start .. end];
}

// True for the directory entries "." and "..".
bool isDotOrDotDot(const(char)* name) @trusted
{
	return name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}


// Parse an octal file mode ("755", "0644", "4755"): 1-4 digits 0-7. False on anything else.
bool parseOctalMode(const(char)[] s, ref uint mode) @safe
{
	if (s.length == 0 || s.length > 4)
	{
		return false;
	}
	uint m = 0;
	foreach (c; s)
	{
		if (c < '0' || c > '7')
		{
			return false;
		}
		m = (m << 3) | cast(uint)(c - '0');
	}
	mode = m;
	return true;
}

// Parse a non-negative decimal number that fits in a long. False on overflow / junk.
bool parseDecimal(const(char)[] s, ref long v) @safe
{
	if (s.length == 0 || s.length > 18)
	{
		return false;
	}
	long r = 0;
	foreach (c; s)
	{
		if (c < '0' || c > '9')
		{
			return false;
		}
		r = r * 10 + (c - '0');
	}
	v = r;
	return true;
}
