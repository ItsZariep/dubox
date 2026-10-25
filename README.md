# Dubox

> **D** **U**nified **box**, also referencing busybox

Core utilities in D.

See `doc/RESEARCH.md` for more development information

See `doc/TOOLS.md` to see all available tools

## Build and test

```bash
make # bin/yes bin/ls bin/rm + bin/dubox (multicall)
make links # bin/multicall/{yes,ls,rm} -> ../dubox (dispatch by argv[0])
make test # builds everything, runs tests/smoke.sh
make MODE=debug # asserts + bounds checks everywhere, debug info
```

```bash
bin/ls -aF /etc # standalone binary
bin/dubox ls -aF /etc # multicall, explicit
bin/multicall/ls -aF /etc # multicall, via symlink name
```

## Status

Linux (x86_64, aarch64) only. Need to do a proper smoke script

This suite is not suitable for a system-level replacement
