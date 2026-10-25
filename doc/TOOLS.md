> See PRIORITIES.md to get more information about this.

| Tool | Priority | Highlights |
| --- | --- | --- |
| `yes` | performance | pre-built chunk, `write(2)` loop, chunk size tuned by measurement |
| `ls` | startup time | no locale/passwd/stdio, bytewise sort, `-U` streams with O(1) memory |
| `rm` | security | fd-relative recursion (`openat`/`unlinkat`), root/`.`/`..` guards, `--one-file-system` |
| `cp` | security | fd-relative tree walk (`O_NOFOLLOW` below the operands), never writes through symlinks found while recursing, same-file check before truncating, copy-into-itself guard, `FICLONE` → `copy_file_range` → `read`/`write` |
| `mv` | security | one `renameat(2)`; on `EXDEV` copies (attributes kept) and removes the source only if the whole copy succeeded, never merges into an existing directory across devices, `-n` uses `RENAME_NOREPLACE` |
| `ln` | security | links go through one directory fd (`linkat`/`symlinkat`/`unlinkat`), same-file check before `-f` removes anything, `-r` relative symlinks |
| `mkdir` | startup time | single `mkdirat`; `-p` walks components holding one fd at a time, `-m` ignores the umask like GNU |
| `rmdir` | startup time | single `unlinkat(AT_REMOVEDIR)`, never recursive; `-p` climbs by path prefix |
| `touch` | startup time | `utimensat`/`futimens`, `-a`/`-m`/`-c`/`-h`, `-r`, `-t`, `-d` (subset of GNU date syntax) |



## Deviations from GNU coreutils

- `cp`: no `-i`, `-u`, `-l`, `-s`, `--reflink`, `--sparse`; `-a` does not preserve hard links; special files (FIFO, device) are recreated only with `-R` and are never opened for reading.
- `cp`: inside a recursive copy an existing destination symlink is an error (or replaced with `-f`), not written through. A destination named on the command line is still followed.
- `mv`: no `-i`, `-u`, `-b`; cross-device moves of a directory onto an existing directory fail instead of merging.
- `mkdir`: `-m` takes octal modes only.
- `touch`: `-d` accepts only `@EPOCH`, `YYYY-MM-DD` and `YYYY-MM-DD hh:mm[:ss]`; no `--time`.
- `ln`: no `-i`, `-b`, `-L`, `-P`.
- `rmdir -p` resolves parent prefixes by string; nothing is ever deleted recursively.