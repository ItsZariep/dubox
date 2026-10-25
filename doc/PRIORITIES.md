
This project expect 3 kinds of program priorities:

## 1.- Boot performance

Programs like `ls`, for example, where almost all of the wall-clock time is process startup, so that tool avoids everything that cost startup, no locate init, no passwd/group lookups, no stdio, no GC. Output is bytewise sorted (== LC_ALL=C)

## 2.- Security

Programs like `rm` for example have many dangerous cases, The dangerous part of rm is recursion: if you remove "a/b/c" by path string, an attacker who can write in "a" can swap "b" for a symlink between you check and your unlink (a TOCTOU race) and make you delete something elsewhere. The defence used here:

1. Open each directory once with `O_NOFOLLOW | O_DIRECTORY` and keep the fd.
2. Do every later operation relative to that fd (unlinkat, openat, fstatat).
3. Never re-resolve a path string below the command-line operand. So a swapped-in symlink is either not followed (O_NOFOLLOW) or the operation stays inside an already holded directory. The `path` buffer below is only used to print messages.
 
### Extra guard rails: 

- refuses "/" (by device+inode, so "//" and "/." are caught)
- refuses "." and ".." operands, fails closed if it cannot verify, and offers --one-file-system.  There is deliberately no --no-preserve-root.

## 3. Performance

In programs like `yes`, raw throughput is the priority, so for example here a solid strategy is wanted, even if is less secure or have a "longer" boot time.

For example, here the strategy is build one chunk containing the line repeated many times, then call write(2) on that chunk in a loop. So no per-line work, no stdio, no allocation after setup.