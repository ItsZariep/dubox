/*
	raw OS bindings

	Tools never talk to libc directly for anything security relevant.
	They go through the *at() family declared here, which operate on directory
	file descriptors instead of re-resolving path strings.
*/

module common.sys;

public import core.sys.posix.sys.stat : stat_t;
public import core.sys.posix.dirent : DIR, dirent, opendir, readdir, closedir, rewinddir;
public import core.sys.posix.unistd : close, read, write;
public import core.sys.posix.time : timespec;

enum AT_FDCWD = -100;
enum AT_SYMLINK_NOFOLLOW = 0x100;
enum AT_REMOVEDIR = 0x200;

enum AT_SYMLINK_FOLLOW = 0x400;

enum O_RDONLY = 0;
enum O_WRONLY = 1;
enum O_CREAT = 0x40;
enum O_EXCL = 0x80;
enum O_NOCTTY = 0x100;
enum O_TRUNC = 0x200;
enum O_NONBLOCK = 0x800;
enum O_CLOEXEC = 0x80000;

enum RENAME_NOREPLACE = 1;
enum long UTIME_NOW = (1L << 30) - 1;
enum long UTIME_OMIT = (1L << 30) - 2;
enum FICLONE = 0x40049409UL; // same value on x86_64 and aarch64

version (X86_64)
{
	enum O_DIRECTORY = 0x10000;
	enum O_NOFOLLOW = 0x20000;
}
else version (AArch64)
{
	enum O_DIRECTORY = 0x4000;
	enum O_NOFOLLOW = 0x8000;
}
else
{
	static assert(0, "add O_DIRECTORY / O_NOFOLLOW for this architecture");
}

enum : ubyte
{
	DT_UNKNOWN = 0,
	DT_FIFO = 1,
	DT_CHR = 2,
	DT_DIR = 4,
	DT_BLK = 6,
	DT_REG = 8,
	DT_LNK = 10,
	DT_SOCK = 12,
}

enum S_IFMT = 0xF000;
enum S_IFIFO = 0x1000;
enum S_IFDIR = 0x4000;
enum S_IFREG = 0x8000;
enum S_IFLNK = 0xA000;
enum S_IFSOCK = 0xC000;

pure nothrow @nogc @safe
{
	bool isDirMode(uint mode)
	{
		return (mode & S_IFMT) == S_IFDIR;
	}

	bool isRegMode(uint mode)
	{
		return (mode & S_IFMT) == S_IFREG;
	}

	bool isLnkMode(uint mode)
	{
		return (mode & S_IFMT) == S_IFLNK;
	}
}

// Nanosecond timestamps of a stat result, whichever field layout druntime exposes.
timespec atimeOf(ref const stat_t st) @trusted nothrow @nogc
{
	timespec t;
	static if (__traits(hasMember, stat_t, "st_atim"))
	{
		t.tv_sec = st.st_atim.tv_sec;
		t.tv_nsec = st.st_atim.tv_nsec;
	}
	else
	{
		t.tv_sec = st.st_atime;
		t.tv_nsec = st.st_atimensec;
	}
	return t;
}

timespec mtimeOf(ref const stat_t st) @trusted nothrow @nogc
{
	timespec t;
	static if (__traits(hasMember, stat_t, "st_mtim"))
	{
		t.tv_sec = st.st_mtim.tv_sec;
		t.tv_nsec = st.st_mtim.tv_nsec;
	}
	else
	{
		t.tv_sec = st.st_mtime;
		t.tv_nsec = st.st_mtimensec;
	}
	return t;
}

alias CompareFn = extern (C) int function(const(void)*, const(void)*) nothrow @nogc;

extern (C) nothrow @nogc
{
	int openat(int dirfd, const(char)* path, int flags, ...);
	int unlinkat(int dirfd, const(char)* path, int flags);
	int fstatat(int dirfd, const(char)* path, stat_t* buf, int flags);
	int fstat(int fd, stat_t* buf);
	DIR* fdopendir(int fd);
	int dirfd(DIR* dir);
	void qsort(void* base, size_t nmemb, size_t size, CompareFn compar);

	int mkdirat(int dirfd, const(char)* path, uint mode);
	int symlinkat(const(char)* target, int newdirfd, const(char)* linkpath);
	int linkat(int olddirfd, const(char)* oldpath, int newdirfd, const(char)* newpath, int flags);
	int renameat(int olddirfd, const(char)* oldpath, int newdirfd, const(char)* newpath);
	int renameat2(int olddirfd, const(char)* oldpath, int newdirfd, const(char)* newpath, uint flags);
	ptrdiff_t readlinkat(int dirfd, const(char)* path, char* buf, size_t bufsiz);
	int mknodat(int dirfd, const(char)* path, uint mode, ulong dev);
	int utimensat(int dirfd, const(char)* path, const(timespec)* times, int flags);
	int futimens(int fd, const(timespec)* times);
	int fchmod(int fd, uint mode);
	int fchmodat(int dirfd, const(char)* path, uint mode, int flags);
	int fchown(int fd, uint uid, uint gid);
	int fchownat(int dirfd, const(char)* path, uint uid, uint gid, int flags);
	int ftruncate(int fd, long length);
	int ioctl(int fd, ulong request, ...);
	ptrdiff_t copy_file_range(int fdIn, long* offIn, int fdOut, long* offOut, size_t len, uint flags);
	uint umask(uint mask);
	char* realpath(const(char)* path, char* resolved);
}

