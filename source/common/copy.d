// Copying and removing file trees

module common.copy;

import core.stdc.errno : errno, EEXIST, EINTR, EINVAL, ENOENT, ENOSYS,
	ENOTEMPTY, EOPNOTSUPP, EPERM, EXDEV, EISDIR, EBADF, ETXTBSY, EACCES, ELOOP;
import common.cstr : fromC, isDotOrDotDot;
import common.io : diag, diagQ, diagQ2, writeAll;
import common.sys;
import common.vec;

@nogc nothrow:

struct CopyCtx
{
	string prog; // for messages: "cp" or "mv"
	bool recursive; // -R
	bool force; // -f: replace destinations that cannot be opened
	bool noClobber; // -n: never overwrite
	bool verbose; // -v
	bool preserve; // -p: mode, ownership, timestamps
	bool derefTop; // -H / -L: follow symlinks named on the command line
	bool derefAll; // -L: follow every symlink
	uint umaskBits; // process umask, read once

	// Set while copying one top-level directory: the destination root, so that
	// "cp -r a a/b" does not recurse into its own output forever.
	bool haveGuard;
	ulong guardDev;
	ulong guardIno;
}

private __gshared ubyte[1 << 17] copyBuf; // read/write fallback buffer (.bss)

// data //

// Copy everything from sfd to dfd.
// Returns 0 on success, a positive errno for a read error, a negative errno for a write error.
private int copyData(int sfd, int dfd) @trusted
{
	if (ioctl(dfd, FICLONE, sfd) == 0)
	{
		return 0; // reflink: instant, shares extents
	}

	bool kernel = true;
	bool any = false;
	for (;;)
	{
		if (kernel)
		{
			const n = copy_file_range(sfd, null, dfd, null, 1 << 30, 0);
			if (n > 0)
			{
				any = true;
				continue;
			}
			if (n == 0)
			{
				if (any)
				{
					return 0;
				}
				// zero bytes at the very start: could be a real empty file or a
				// /proc-style file that reports size 0. read(2) settles it.
				kernel = false;
				continue;
			}
			const e = errno;
			if (e == EINTR)
			{
				continue;
			}
			if (e == EXDEV || e == ENOSYS || e == EINVAL || e == EOPNOTSUPP || e == EPERM || e == EBADF || e == ETXTBSY)
			{
				kernel = false;
				continue;
			}
			return e; // EIO, ENOSPC, EFBIG... (attributed to the read side; the message names no side)
		}

		const n = read(sfd, copyBuf.ptr, copyBuf.length);
		if (n < 0)
		{
			const e = errno;
			if (e == EINTR)
			{
				continue;
			}
			return e;
		}
		if (n == 0)
		{
			return 0;
		}
		const w = writeAll(dfd, copyBuf[0 .. cast(size_t) n]);
		if (w)
		{
			return -w;
		}
	}
}

// helpers //

private bool sameInode(ref const stat_t a, ref const stat_t b)
{
	return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

// Remove a non-directory destination so something else can take its place.
// Returns 0 on success, or the errno to report.
private int clearDest(int ddfd, const(char)* dname) @trusted
{
	stat_t ds;
	if (fstatat(ddfd, dname, &ds, AT_SYMLINK_NOFOLLOW) != 0)
	{
		return errno == ENOENT ? 0 : errno;
	}
	if (isDirMode(ds.st_mode))
	{
		return EISDIR;
	}
	if (unlinkat(ddfd, dname, 0) != 0 && errno != ENOENT)
	{
		return errno;
	}
	return 0;
}

private void applyTimes(int fd, ref const stat_t st) @trusted
{
	timespec[2] ts;
	ts[0] = atimeOf(st);
	ts[1] = mtimeOf(st);
	futimens(fd, ts.ptr);
}

private void say(ref const CopyCtx c, ref Vec!char sp, ref Vec!char dp) @trusted
{
	import common.io : gout;

	if (c.verbose)
	{
		gout.put("'");
		gout.put(sp.data);
		gout.put("' -> '");
		gout.put(dp.data);
		gout.put("'\n");
	}
}

// regular file //

private bool copyReg(ref CopyCtx c, int sdfd, const(char)* sname, int ddfd, const(char)* dname,
	ref Vec!char sp, ref Vec!char dp, bool top, bool follow) @trusted
{
	int sflags = O_RDONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK;
	if (!follow)
	{
		sflags |= O_NOFOLLOW;
	}
	const sfd = openat(sdfd, sname, sflags);
	if (sfd < 0)
	{
		diagQ(c.prog, "cannot open ", sp.data, " for reading", errno);
		return false;
	}

	stat_t ss;
	if (fstat(sfd, &ss) != 0)
	{
		diagQ(c.prog, "cannot stat ", sp.data, "", errno);
		close(sfd);
		return false;
	}
	if (!isRegMode(ss.st_mode))
	{
		// swapped for something else between stat and open: refuse rather than read a FIFO
		diagQ(c.prog, "", sp.data, " is not a regular file", 0);
		close(sfd);
		return false;
	}

	// Create exclusively first; only if that says EEXIST do we deal with an existing file.
	bool created = true;
	int dfd = openat(ddfd, dname, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, ss.st_mode & 0x1FF);
	if (dfd < 0 && errno == EEXIST)
	{
		created = false;
		if (c.noClobber)
		{
			close(sfd);
			return true;
		}

		// An existing destination named on the command line may be a symlink to the real
		// target. Anything found while recursing is never followed.
		const int nf = top ? 0 : O_NOFOLLOW;
		dfd = openat(ddfd, dname, O_WRONLY | O_CLOEXEC | O_NOCTTY | O_NONBLOCK | nf);
		if (dfd < 0)
		{
			int why = errno;
			if (why == EISDIR)
			{
				diagQ2(c.prog, "cannot overwrite directory ", dp.data, " with non-directory ", sp.data, "", 0);
				close(sfd);
				return false;
			}
			if (why == ELOOP && !c.force)
			{
				diagQ(c.prog, "not writing through symbolic link ", dp.data, "", 0);
				close(sfd);
				return false;
			}
			if (c.force)
			{
				// -f: replace what we cannot open (or refuse to write through)
				const ce = clearDest(ddfd, dname);
				if (ce)
				{
					diagQ(c.prog, "cannot remove ", dp.data, "", ce);
					close(sfd);
					return false;
				}
				dfd = openat(ddfd, dname, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, ss.st_mode & 0x1FF);
				created = true;
				why = errno;
			}
			if (dfd < 0)
			{
				diagQ(c.prog, "cannot create regular file ", dp.data, "", why);
				close(sfd);
				return false;
			}
		}
	}
	else if (dfd < 0)
	{
		diagQ(c.prog, "cannot create regular file ", dp.data, "", errno);
		close(sfd);
		return false;
	}

	bool ok = true;
	stat_t ds;
	if (fstat(dfd, &ds) != 0)
	{
		diagQ(c.prog, "cannot stat ", dp.data, "", errno);
		ok = false;
	}
	else if (!created)
	{
		// Decide *before* truncating: "cp a a" must not destroy a.
		if (sameInode(ss, ds))
		{
			diagQ2(c.prog, "", sp.data, " and ", dp.data, " are the same file", 0);
			ok = false;
		}
		else if (!isRegMode(ds.st_mode))
		{
			diagQ(c.prog, "cannot overwrite non-regular file ", dp.data, "", 0);
			ok = false;
		}
		else if (ftruncate(dfd, 0) != 0)
		{
			diagQ(c.prog, "cannot truncate ", dp.data, "", errno);
			ok = false;
		}
	}

	if (ok)
	{
		const r = copyData(sfd, dfd);
		if (r > 0)
		{
			diagQ(c.prog, "error reading ", sp.data, "", r);
			ok = false;
		}
		else if (r < 0)
		{
			diagQ(c.prog, "error writing ", dp.data, "", -r);
			ok = false;
		}
	}

	if (ok && c.preserve)
	{
		fchown(dfd, ss.st_uid, ss.st_gid); // EPERM for non-root is expected; ignore
		fchmod(dfd, ss.st_mode & 0xFFF);
		applyTimes(dfd, ss);
	}

	if (close(dfd) != 0 && ok)
	{
		diagQ(c.prog, "failed to close ", dp.data, "", errno);
		ok = false;
	}
	close(sfd);
	if (ok)
	{
		say(c, sp, dp);
	}
	return ok;
}

// symbolic link //

private bool copySymlink(ref CopyCtx c, int sdfd, const(char)* sname, int ddfd, const(char)* dname,
	ref Vec!char sp, ref Vec!char dp) @trusted
{
	char[4097] buf;
	const n = readlinkat(sdfd, sname, buf.ptr, buf.length - 1);
	if (n < 0)
	{
		diagQ(c.prog, "cannot read symbolic link ", sp.data, "", errno);
		return false;
	}
	buf[cast(size_t) n] = '\0';

	int r = symlinkat(buf.ptr, ddfd, dname);
	if (r != 0 && errno == EEXIST)
	{
		if (c.noClobber)
		{
			return true;
		}
		const ce = clearDest(ddfd, dname);
		if (ce == EISDIR)
		{
			diagQ2(c.prog, "cannot overwrite directory ", dp.data, " with non-directory ", sp.data, "", 0);
			return false;
		}
		if (ce)
		{
			diagQ(c.prog, "cannot remove ", dp.data, "", ce);
			return false;
		}
		r = symlinkat(buf.ptr, ddfd, dname);
	}
	if (r != 0)
	{
		diagQ(c.prog, "cannot create symbolic link ", dp.data, "", errno);
		return false;
	}

	if (c.preserve)
	{
		stat_t ss;
		if (fstatat(sdfd, sname, &ss, AT_SYMLINK_NOFOLLOW) == 0)
		{
			fchownat(ddfd, dname, ss.st_uid, ss.st_gid, AT_SYMLINK_NOFOLLOW);
			timespec[2] ts;
			ts[0] = atimeOf(ss);
			ts[1] = mtimeOf(ss);
			utimensat(ddfd, dname, ts.ptr, AT_SYMLINK_NOFOLLOW);
		}
	}
	say(c, sp, dp);
	return true;
}

// FIFOs, sockets, device nodes (only with -R; never opened for reading) //
private bool copySpecial(ref CopyCtx c, ref const stat_t st, int ddfd, const(char)* dname,
	ref Vec!char sp, ref Vec!char dp) @trusted
{
	if (!c.recursive)
	{
		diagQ(c.prog, "cannot copy special file ", sp.data, " without -R", 0);
		return false;
	}
	int r = mknodat(ddfd, dname, st.st_mode, st.st_rdev);
	if (r != 0 && errno == EEXIST)
	{
		if (c.noClobber)
		{
			return true;
		}
		const ce = clearDest(ddfd, dname);
		if (ce)
		{
			diagQ(c.prog, "cannot remove ", dp.data, "", ce);
			return false;
		}
		r = mknodat(ddfd, dname, st.st_mode, st.st_rdev);
	}
	if (r != 0)
	{
		diagQ(c.prog, "cannot create special file ", dp.data, "", errno);
		return false;
	}
	if (c.preserve)
	{
		fchownat(ddfd, dname, st.st_uid, st.st_gid, AT_SYMLINK_NOFOLLOW);
		timespec[2] ts;
		ts[0] = atimeOf(st);
		ts[1] = mtimeOf(st);
		utimensat(ddfd, dname, ts.ptr, AT_SYMLINK_NOFOLLOW);
	}
	say(c, sp, dp);
	return true;
}

// directory //

private bool copyDir(ref CopyCtx c, int sdfd, const(char)* sname, ref const stat_t st, int ddfd,
	const(char)* dname, ref Vec!char sp, ref Vec!char dp, bool top, bool follow) @trusted
{
	if (!c.recursive)
	{
		diag(c.prog, "-r not specified; omitting directory", sp.data, 0);
		return false;
	}
	if (c.haveGuard && st.st_dev == c.guardDev && st.st_ino == c.guardIno)
	{
		diagQ2(c.prog, "cannot copy a directory, ", sp.data, ", into itself, ", dp.data, "", 0);
		return false;
	}

	const uint srcMode = st.st_mode & 0xFFF;
	const uint finalMode = c.preserve ? srcMode : (srcMode & 0x1FF & ~c.umaskBits);

	// owner rwx while we fill it; the final mode is set at the end
	bool created = true;
	if (mkdirat(ddfd, dname, finalMode | 0x1C0 /* 0700 */ ) != 0)
	{
		const e = errno;
		stat_t ds;
		if (e == EEXIST && fstatat(ddfd, dname, &ds, top ? 0 : AT_SYMLINK_NOFOLLOW) == 0 && isDirMode(ds.st_mode))
		{
			created = false; // merge into the existing directory
		}
		else if (e == EEXIST && fstatat(ddfd, dname, &ds, AT_SYMLINK_NOFOLLOW) == 0)
		{
			diagQ2(c.prog, "cannot overwrite non-directory ", dp.data, " with directory ", sp.data, "", 0);
			return false;
		}
		else
		{
			diagQ(c.prog, "cannot create directory ", dp.data, "", e);
			return false;
		}
	}

	const int dflags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (top ? 0 : O_NOFOLLOW);
	const ndfd = openat(ddfd, dname, dflags);
	if (ndfd < 0)
	{
		diagQ(c.prog, "cannot open directory ", dp.data, "", errno);
		return false;
	}

	stat_t dst;
	if (fstat(ndfd, &dst) != 0)
	{
		diagQ(c.prog, "cannot stat ", dp.data, "", errno);
		close(ndfd);
		return false;
	}
	if (!created && sameInode(st, dst))
	{
		diagQ2(c.prog, "", sp.data, " and ", dp.data, " are the same file", 0);
		close(ndfd);
		return false;
	}

	const int sflags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (follow ? 0 : O_NOFOLLOW);
	const nsfd = openat(sdfd, sname, sflags);
	if (nsfd < 0)
	{
		diagQ(c.prog, "cannot open directory ", sp.data, "", errno);
		close(ndfd);
		return false;
	}
	stat_t again;
	if (fstat(nsfd, &again) != 0 || !sameInode(st, again))
	{
		diagQ(c.prog, "", sp.data, " changed while being copied", 0);
		close(nsfd);
		close(ndfd);
		return false;
	}

	const bool setGuard = top;
	if (setGuard)
	{
		c.haveGuard = true;
		c.guardDev = dst.st_dev;
		c.guardIno = dst.st_ino;
	}

	DIR* d = fdopendir(nsfd);
	if (d is null)
	{
		diagQ(c.prog, "cannot open directory ", sp.data, "", errno);
		close(nsfd);
		close(ndfd);
		if (setGuard)
		{
			c.haveGuard = false;
		}
		return false;
	}

	bool ok = true;
	const spLen = sp.length;
	const dpLen = dp.length;
	if (spLen == 0 || sp.data[spLen - 1] != '/')
	{
		must(sp.push('/'));
	}
	if (dpLen == 0 || dp.data[dpLen - 1] != '/')
	{
		must(dp.push('/'));
	}
	const spBase = sp.length;
	const dpBase = dp.length;

	for (;;)
	{
		errno = 0;
		dirent* de = readdir(d);
		if (de is null)
		{
			if (errno != 0)
			{
				diagQ(c.prog, "reading directory ", sp.data[0 .. spLen], "", errno);
				ok = false;
			}
			break;
		}
		const(char)* nm = de.d_name.ptr;
		if (isDotOrDotDot(nm))
		{
			continue;
		}
		const(char)[] nmS = fromC(nm);
		must(sp.append(nmS));
		must(dp.append(nmS));
		if (!copyEntry(c, dirfd(d), nm, ndfd, nm, sp, dp, false))
		{
			ok = false;
		}
		sp.truncate(spBase);
		dp.truncate(dpBase);
	}
	closedir(d); // also closes nsfd
	sp.truncate(spLen);
	dp.truncate(dpLen);

	if (created)
	{
		fchmod(ndfd, finalMode);
	}
	if (c.preserve)
	{
		fchown(ndfd, st.st_uid, st.st_gid);
		fchmod(ndfd, srcMode);
		applyTimes(ndfd, st);
	}
	close(ndfd);
	if (setGuard)
	{
		c.haveGuard = false;
	}
	if (ok)
	{
		say(c, sp, dp);
	}
	return ok;
}

// dispatch //

// Copy `sname` (relative to sdfd) to `dname` (relative to ddfd). `top` marks a command-line
// operand: symlinks there may be followed (-H/-L) and an existing destination symlink is honoured.
bool copyEntry(ref CopyCtx c, int sdfd, const(char)* sname, int ddfd, const(char)* dname,
	ref Vec!char sp, ref Vec!char dp, bool top) @trusted
{
	const bool follow = !c.recursive || (top ? c.derefTop : c.derefAll);
	stat_t st;
	if (fstatat(sdfd, sname, &st, follow ? 0 : AT_SYMLINK_NOFOLLOW) != 0)
	{
		diagQ(c.prog, "cannot stat ", sp.data, "", errno);
		return false;
	}
	const m = st.st_mode;
	if (isDirMode(m))
	{
		return copyDir(c, sdfd, sname, st, ddfd, dname, sp, dp, top, follow);
	}
	if (isLnkMode(m))
	{
		return copySymlink(c, sdfd, sname, ddfd, dname, sp, dp);
	}
	if (isRegMode(m))
	{
		return copyReg(c, sdfd, sname, ddfd, dname, sp, dp, top, follow);
	}
	return copySpecial(c, st, ddfd, dname, sp, dp);
}

// Copy one command-line operand. `src` is resolved exactly once (by AT_FDCWD);
// `dname` is relative to `ddfd`. The two display strings are only for messages.
bool copyTop(ref CopyCtx c, const(char)* src, int ddfd, const(char)* dname,
	const(char)[] srcShown, const(char)[] dstShown) @trusted
{
	Vec!char sp, dp;
	must(sp.append(srcShown));
	must(dp.append(dstShown));
	c.haveGuard = false;
	return copyEntry(c, AT_FDCWD, src, ddfd, dname, sp, dp, true);
}

// removal (used by mv after a successful cross-device copy) //

/*
	Remove `name` (relative to pdfd) and everything below it, fd-relative and without
	following symlinks. A directory that is still non-empty after one pass (readdir can
	skip entries when the directory changes under it) is scanned again a few times.
*/
bool removeAt(string prog, int pdfd, const(char)* name, ref Vec!char path) @trusted
{
	if (unlinkat(pdfd, name, 0) == 0)
	{
		return true;
	}
	int e = errno;
	if (e == ENOENT)
	{
		return true;
	}
	if (e != EISDIR && e != EPERM)
	{
		diagQ(prog, "cannot remove ", path.data, "", e);
		return false;
	}

	const fd = openat(pdfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0)
	{
		e = errno;
		if (e == ENOENT)
		{
			return true;
		}
		diagQ(prog, "cannot remove ", path.data, "", e);
		return false;
	}
	DIR* d = fdopendir(fd);
	if (d is null)
	{
		diagQ(prog, "cannot remove ", path.data, "", errno);
		close(fd);
		return false;
	}

	bool ok = true;
	const plen = path.length;
	if (plen == 0 || path.data[plen - 1] != '/')
	{
		must(path.push('/'));
	}
	const base = path.length;

	for (int pass = 0; pass < 4; ++pass)
	{
		rewinddir(d);
		for (;;)
		{
			errno = 0;
			dirent* de = readdir(d);
			if (de is null)
			{
				break;
			}
			const(char)* nm = de.d_name.ptr;
			if (isDotOrDotDot(nm))
			{
				continue;
			}
			must(path.append(fromC(nm)));
			if (!removeAt(prog, dirfd(d), nm, path))
			{
				ok = false;
			}
			path.truncate(base);
		}
		if (!ok)
		{
			break;
		}
		if (unlinkat(pdfd, name, AT_REMOVEDIR) == 0)
		{
			closedir(d);
			path.truncate(plen);
			return true;
		}
		e = errno;
		if (e == ENOENT)
		{
			closedir(d);
			path.truncate(plen);
			return true;
		}
		if (e != ENOTEMPTY && e != EEXIST)
		{
			break;
		}
	}
	closedir(d);
	path.truncate(plen);
	if (ok)
	{
		diagQ(prog, "cannot remove ", path.data, "", e);
	}
	return false;
}
