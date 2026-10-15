#!/bin/bash
# Growth gate driver: two boots of the same data disk, with the file enlarged in
# between exactly the way the app does it (a sparse truncate), and a base image
# copied and enlarged the same way. A filesystem can only grow if it is smaller
# than its device, so the check is that the second boot reports more blocks than
# the first -- on both disks.
#
#   BIN=.../linux-um-arm64 IMG=.../alpine-docker.ext4 harness/growfs.sh
#
# Both boots run init=/grow-init from harness/guest, which is installed into the
# docker image alongside every other guest script.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:-$(cd "$HERE/../../.." && pwd)}
BIN=${BIN:-$ROOT/linux}
IMG=${IMG:-$ROOT/tools/um-arm64/alpine-docker.ext4}

[ -f "$BIN" ] || { echo "growfs.sh: no kernel at BIN=$BIN" >&2; exit 2; }
[ -f "$IMG" ] || { echo "growfs.sh: no docker image at IMG=$IMG" >&2; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/umarm-growfs.XXXXXX")
trap 'rm -rf "$T"' EXIT

cp "$IMG" "$T/base.ext4"

boot() { # boot <gate> <log> [ubd1-size]
	local gate=$1 log=$2 size=${3:-}
	BIN="$BIN" ART="$T/art" GATE="$gate" INIT=/grow-init \
		MARKER=UMARM_GROW_OK EXTRA_ARGS=rw MEM=512M \
		UBD1_SIZE="$size" UBD0="$T/base.ext4" UBD1="$T/data.ext4" \
		"$HERE/native.sh" >"$log" 2>&1
}

# Boot 1: a 256 MiB data disk and the release-sized base. This formats and
# mounts both, and reports the block counts the filesystem was born with.
echo "growfs: boot 1 (256M data disk)"
boot growth-1 "$T/boot1.log" 256M || {
	grep -a 'GATE_GROW_FAIL' "$T/art/growth-1-latest/boot.log" 2>/dev/null || true
	echo "growfs.sh: the first boot failed; see $T/boot1.log and suffix .1" >&2
	cp -r "$T" "${TMPDIR:-/tmp}/umarm-growfs-failed" 2>/dev/null || true
	exit 1
}
b1=$(grep -ao 'GATE_GROW base_blocks=[0-9]* data_blocks=[0-9]*' \
	"$T/art/growth-1-latest/boot.log" | tail -1)

# What the app does: a sparse setLength, on both files. No data is written, so
# this is instant; the guest finds the devices larger on the next boot.
truncate -s 768M "$T/data.ext4"
truncate -s 1536M "$T/base.ext4"

echo "growfs: boot 2 (768M data disk, 1.5G base)"
boot growth-2 "$T/boot2.log" || {
	echo "growfs.sh: the second boot failed; see $T/boot2.log" >&2
	exit 1
}
b2=$(grep -ao 'GATE_GROW base_blocks=[0-9]* data_blocks=[0-9]*' \
	"$T/art/growth-2-latest/boot.log" | tail -1)

echo "boot1: $b1"
echo "boot2: $b2"

fail=0
for disk in base data; do
	a=$(printf '%s\n' "$b1" | sed -n "s/.*${disk}_blocks=\([0-9]*\).*/\1/p")
	c=$(printf '%s\n' "$b2" | sed -n "s/.*${disk}_blocks=\([0-9]*\).*/\1/p")
	if [ -z "$a" ] || [ -z "$c" ] || [ "$c" -le "$a" ]; then
		echo "GATE_GROW_FAIL $disk did not grow ($a -> $c)"
		fail=1
	fi
done
[ "$fail" = 0 ] || exit 1
echo "UMARM_GROW_PASS"
