# why Dubox exists and why it looks the way it does

## Why do this at all?

This is first of all a **learning project**. The goals, in priority order:

1. Learn systems programming in D by rewriting tools whose behaviour is precisely specified and easy to compare against a reference (GNU coreutils).
2. Show off what D is good at: templates and CTFE removing boilerplate, `@safe`/`@trusted` islands, slices instead of pointer+length, `static foreach` / mixins for composition.
3. Be fast, with *speed over everything else* when there is a trade-off, but never by giving up memory safety in the parts that touch untrusted input.
4. Share sources the way BusyBox does, yet still be able to produce either one multicall
   binary or one binary per tool from the same code.

It is explicitly **not** (yet) a drop-in replacement for any complete suite

## Does it already exist? (search, October 2026)

As far i could search, I didn't find anything with the same concept, maybe `icy/dusybox`, but not even complete or comparable


## What are the actual benefits of using D? (and what does Phobos not give)

Initial hypothesis: "i want security that only Phobos can provide". After looking at where
coreutils-style bugs come from, **that hypothesis was wrong**, and the design changed:

| Real risk in coreutils-style tools | What addresses it | Needs Phobos? |
| --- | --- | --- |
| Buffer overruns / off-by-one | bounds-checked slices, `@safe` | No (language) |
| Integer overflow in sizes/counts | `core.checkedint` | No (druntime, works in `-betterC`) |
| Symlink / TOCTOU races (`rm -r`, `cp -r`, `chown -R`) | `openat`/`unlinkat`/`fstatat` on held fds | **No, and Phobos' path-based `std.file` is the wrong tool** |
| Invalid UTF-8 / locale quirks | validate or avoid decoding | `std.utf` helps, optional |
| Unbounded memory on big inputs | streaming design | No |


So Phobos is optional here. The "D benefits" going to be used are language features: slices, `@safe`,
templates, CTFE, mixins, `static foreach`, `scope`/RAII destructors, `final switch`.

## Design decisions

### `-betterC` hybrid; no Phobos linked in this base

**Decision:** compile every tool with `-betterC`. Use `core.stdc`/`core.sys.posix` and a
few druntime templates (`core.checkedint`). No GC, no exceptions, no classes, no stdio.
Nothing in this base imports Phobos.

**Why [measured]**, time to `exec` an empty program, 3000 runs each:

| Variant | ms/exec | Size | Dynamic deps |
| --- | --- | --- | --- |
| `/bin/true` (GNU, the exec floor) | 1.23 | n/a | libc |
| D `-betterC` | 1.24 – 1.37 | 15 KB | libc |
| D druntime linked statically (`void main(){}`) | 1.82 – 1.90 | 630 KB | libc |
| D + Phobos `std.stdio`, linked statically | 1.93 | 1.1 MB | libc, **libz, libm, libgcc_s** |
| D + Phobos `std.stdio`, shared Phobos | 3.01 | 29 KB | libphobos, libdruntime, ... |


Takeaways:

- `-betterC` sits at the floor of what `exec` costs.
- **Most of the D startup cost is druntime initialization (~0.6 ms here), not Phobos.**
  Static linking removes the shared-library cost (~1 ms) but *not* druntime init.

**Cost:** no exceptions, no `std.algorithm` on dynamic arrays that allocate, no Phobos string
formatting. Everything that allocates uses `Vec!T` from `common/vec.d`.

**Escape hatch:** a tool that really needs Phobos (say, `sort` with a fancy comparator) can be
built without `-betterC` and with static druntime. It would pay ~0.6 ms startup, and that
should be a conscious, benchmarked decision per tool.

### Own buffered output, no stdio

`common/io.d`: a fixed-size `Out!N` buffer over `write(2)`, instantiated as `__gshared`
globals, so it lives in `.bss` and costs nothing in the binary. `writeAll` retries on `EINTR`
and short writes. Stdout write failures turn into a non-zero exit status.

### Safety model

- Default to `@safe`; `@trusted` only on tiny wrappers (a `strlen`, a `write`).
- **Bounds checks stay on in release.** **[measured]** With `-O3 -release -betterC` an out-of-range index in a `@safe` function terminates the process (SIGSEGV, exit 139) and with `-boundscheck=off` the *same* program silently returns out-of-bounds data. So D's `-release`keeps checks in `@safe` code by default, which is the wanted behaviour. (Failure is a bare crash with no message in `-betterC`: fail-closed but unfriendly.)
- All arithmetic on sizes/counts that come from user input goes through `core.checkedint` (`yes` checks the total line length; `Vec` checks capacity overflow).
- OOM aborts with a message (`must(...)`) instead of continuing with a null pointer.

### One source tree, two products

`mixin StandaloneMain!run` at the bottom of each tool emits `main` *unless* the build passes
`-version=Multicall`, in which case `multicall.d` owns `main` and dispatches on `argv[0]` (or
`Dubox TOOL ...`) through a `static foreach` over the tool modules.

**[measured]** sizes: `yes` 21 KB, `ls` 26 KB, `rm` 30 KB standalone (77 KB total) vs one 44 KB
multicall binary. Start-up for `ls` on a 2-file dir: standalone 1.26 ms, multicall 1.34 ms,

### Declarative option parsing

Tools declare `static immutable Opt[] opts = [...]`. `common/args.d` derives parsing,
`--help` and `--version` from the table, and `enum iForce = optIndex(opts, "force")` resolves
flag indices at compile time, so a typo is a **compile error**, not a silently-false flag.
Deliberate rules: no long-option abbreviations (they break when options are added), options
may follow operands (like GNU getopt), `--` ends options.

### System libc, dynamically linked

the tools depend only on `libc.so.6` and the loader (`ldd bin/ls`). Static Phobos is not needed, because Phobos is not linked at all.

### `rm`: file-descriptor-relative recursion

The classic `rm -r` race: delete `a/b/c` by path string, and an attacker with write access to
`a` swaps `b` for a symlink between your check and your use. Defence:

1. open each directory once with `O_NOFOLLOW | O_DIRECTORY`, keep the fd;
2. do everything below it with `unlinkat` / `openat` / `fstatat` on that fd;
3. never re-resolve a path string below the command-line operand.

The path buffer in `rm.d` is used **only for messages**. Additional rules:

- `/` is detected by **device + inode**, so `//`, `/.`, `/../..` are caught too; if `/` cannot be stat'ed we **fail closed**. There is intentionally **no** `--no-preserve-root`.
- `.` and `..` operands are refused (GNU message wording).
- Trailing slashes are stripped before use: `rm -r link/` removes the *link*, never the target's  contents. (TODO: GNU's behaviour may differ, please confirm)
- A directory that turns into a file (or the reverse) mid run is handled by retrying with the other call (`EISDIR` -> treat as directory), never by following anything.
- After a pass, the directory is rescanned until empty, because POSIX allows `readdir` to skip entries when you delete while iterating.
- `--one-file-system` compares `st_dev` using `fstat` on the *opened fd*.

Tested: symlink to an outside directory is not followed (the target survives), 200 level and
5000 file trees, `.`/`..` refusal, `-v` output equals GNU's as a set.

### `ls`: only what keeps startup minimal

No locale initialisation, no `getpwuid`/`getgrgid` (that is what makes `-l` slow, so there is
no `-l` yet), no columns. Bytewise sort (== `LC_ALL=C`) via `qsort` over an offset table into
one arena. `-U` without `-F` **streams** entries from `readdir` with O(1) memory.
`d_type` is used whenever it is conclusive, with `fstatat` only as a fallback.

### `yes`: chunk size is a trap

Throughput through a pipe into `head -c 2000000000 > /dev/null`, best of 3:

| Chunk | 4 KiB | 8 KiB | 16 KiB | 32 KiB | 64 KiB | 128 KiB | 1 MiB |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GB/s | 2.59 | 2.57 | 1.80 | 1.50 | 1.45 | 1.38 | 1.47 |


My first version used 64 KiB (the pipe capacity) on the theory that "one write fills the
pipe". It was 1.8x *slower* than 8 KiB: a pipe-sized write makes writer and reader take turns
instead of overlapping. After switching to 8 KiB: Dubox `yes` ≈ 2.5 GB/s vs GNU 9.4 ≈ 2.6 GB/s,
i.e. parity, not a win. Ideas not yet tried: `vmsplice`, `F_SETPIPE_SZ`, testing with other
consumers than `head`.

### Linux-only for now

`x86_64` and `aarch64`. The few constants that druntime does not reliably expose
(`O_DIRECTORY`, `O_NOFOLLOW`, `AT_*`, `DT_*`) are declared in `common/sys.d` and verified
against the C headers by `tests/check_abi.sh` (21 constants, all match on my tests)


## A bug the tests caught (worth remembering)

`Vec!char.terminate()` first wrote `T.init`. In D **`char.init` is `0xFF`, not `'\0'`**, so the "C string" passed to `fstatat` had a garbage terminator and every `rm` of an existing file reported `No such file or directory`. Fixed with `memset(..., 0, ...)`. Lesson: never rely on `.init` for "zero" in D.

## Open questions / next experiments

1. Multicall vs separate binaries at 20+ tools: page faults, `perf stat`, cold cache.
2. Is `getdents64` directly (skipping libc `DIR*`) measurably faster for `ls -U`?
3. `rm`: replace recursion with an explicit stack and close parent fds early to lift the depth limit; add a stress test with a concurrent attacker thread swapping symlinks.
5. Re-run all benchmarks on real hardware with `hyperfine`; this sandbox inflates syscalls.