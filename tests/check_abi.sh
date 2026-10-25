#!/usr/bin/env bash

# Verify the hand-written constants in source/common/sys.d against the real
# C headers of THIS machine. Run after touching sys.d or porting to a new arch.

set -eu
cd "$(dirname "$0")/.."
cc=${CC:-cc}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/abi.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/stat.h>
int main(void) {
	printf("AT_FDCWD=%d\nAT_SYMLINK_NOFOLLOW=%d\nAT_REMOVEDIR=%d\n", AT_FDCWD, AT_SYMLINK_NOFOLLOW, AT_REMOVEDIR);
	printf("O_RDONLY=%d\nO_CLOEXEC=%d\nO_DIRECTORY=%d\nO_NOFOLLOW=%d\n", O_RDONLY, O_CLOEXEC, O_DIRECTORY, O_NOFOLLOW);
	printf("DT_UNKNOWN=%d\nDT_FIFO=%d\nDT_CHR=%d\nDT_DIR=%d\nDT_BLK=%d\nDT_REG=%d\nDT_LNK=%d\nDT_SOCK=%d\n",
		DT_UNKNOWN, DT_FIFO, DT_CHR, DT_DIR, DT_BLK, DT_REG, DT_LNK, DT_SOCK);
	printf("S_IFMT=%d\nS_IFIFO=%d\nS_IFDIR=%d\nS_IFREG=%d\nS_IFLNK=%d\nS_IFSOCK=%d\n", S_IFMT, S_IFIFO, S_IFDIR, S_IFREG, S_IFLNK, S_IFSOCK);
	return 0;
}
EOF
$cc -o "$tmp/abi" "$tmp/abi.c"
"$tmp/abi" | sort > "$tmp/c.txt"

# Print the same names from sys.d by letting LDC evaluate them at compile time.
{
	echo 'import core.stdc.stdio; import common.sys;'
	echo 'extern (C) int main() {'
	while IFS== read -r name _; do
		echo "  printf(\"$name=%d\\n\", cast(int) $name);"
	done < "$tmp/c.txt"
	echo '  return 0; }'
} > "$tmp/abi.d"
ldmd2 -betterC -Isource -of="$tmp/abid" "$tmp/abi.d" source/common/sys.d >/dev/null
"$tmp/abid" | sort > "$tmp/d.txt"

if diff -u "$tmp/c.txt" "$tmp/d.txt"; then
	echo "sys.d constants match the C headers ($(wc -l < "$tmp/c.txt") checked)"
else
	echo "MISMATCH between sys.d and C headers" >&2
	exit 1
fi
