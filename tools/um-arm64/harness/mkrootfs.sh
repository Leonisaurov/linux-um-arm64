#!/bin/bash
# Build the gate-3 root filesystem: an ext4 image populated from Alpine's
# minirootfs, with the gate's init injected.
#
# No root is needed anywhere. `mke2fs -d <dir>` builds a filesystem from a
# directory tree with libext2fs -- it never mounts anything -- and the Alpine
# minirootfs tarball contains no device nodes, which is the one thing that would
# have required privileges. That is what makes a real block-device gate possible
# inside CI (and on a phone) instead of debootstrapping with loop mounts.
#
#   ./mkrootfs.sh /tmp/alpine.ext4
#
# The Alpine release is pinned by URL and sha256, not fetched by "latest", so a
# gate cannot silently change its guest underneath itself.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$PWD/alpine.ext4}
SIZE=${SIZE:-64M}

ALPINE_VERSION=${ALPINE_VERSION:-3.21.4}
ALPINE_BASE=${ALPINE_BASE:-https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64}
ALPINE_TARBALL=alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz
ALPINE_SHA256=${ALPINE_SHA256:-4ccfb9feda48b4f40fd9aceaf32b61e575d407387589deaabbd77cd9ed51e165}

CC=${CC:-clang}
TARGET=${TARGET:-aarch64-linux-gnu}

CACHE=${CACHE:-${TMPDIR:-/tmp}/umarm-rootfs-cache}
mkdir -p "$CACHE"

command -v mke2fs >/dev/null 2>&1 || {
    echo "mkrootfs.sh: mke2fs not found (install e2fsprogs)" >&2
    exit 2
}

fetch() {
    local f=$1
    [ -f "$CACHE/$f" ] && return 0
    echo "downloading $ALPINE_BASE/$f" >&2
    curl -fsSL --retry 3 --retry-all-errors -o "$CACHE/$f.part" "$ALPINE_BASE/$f"
    mv "$CACHE/$f.part" "$CACHE/$f"
}

fetch "$ALPINE_TARBALL" || { echo "mkrootfs.sh: cannot download $ALPINE_TARBALL" >&2; exit 2; }

# Verify before extracting, always -- the cache is not trusted either.
echo "$ALPINE_SHA256  $CACHE/$ALPINE_TARBALL" | sha256sum -c - >&2 || {
    echo "mkrootfs.sh: sha256 mismatch for $ALPINE_TARBALL" >&2
    rm -f "$CACHE/$ALPINE_TARBALL"
    exit 2
}

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/umarm-rootfs.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

tar -xzf "$CACHE/$ALPINE_TARBALL" -C "$STAGE"

# Unprivileged builds may not restore ownership from the tarball; the contents
# are root:root inside the image regardless, which is what matters.
#
# Guest-side files. The gate inits are plain shell and go in as-is; the probes
# are freestanding binaries (their own _start, raw svc #0), so no guest libc and
# no dynamic loader are involved and --target alone selects the architecture.
for f in "$HERE"/guest/*; do
    install -m 0755 "$f" "$STAGE/$(basename "$f")"
done

compile_probe() {
    local src=$1 name=$2

    "$CC" --target="$TARGET" -static -nostdlib -ffreestanding -O1 \
          -fno-stack-protector -fno-pic -o "$STAGE/$name" "$src"

    # ET_EXEC, not ET_DYN: nothing relocates a PIE in a rootfs whose loader is
    # the guest's, and a DYN probe would fail in a way that looks like the
    # kernel faulting on the first instruction.
    python3 - "$STAGE/$name" <<'PY'
import struct, sys
p = sys.argv[1]
d = open(p, "rb").read(20)
if d[:4] != b"\x7fELF" or struct.unpack_from("<H", d, 16)[0] != 2:
    sys.exit(f"{p} is not a static ET_EXEC aarch64 ELF")
PY
}

compile_probe "$HERE/probe/fptorture.c" fptorture

# e2fsprogs refuses to overwrite an existing filesystem unless forced, and CI
# reuses $OUT across attempts.
rm -f "$OUT"
mke2fs -q -F -t ext4 -b 4096 -L alpine -d "$STAGE" "$OUT" "$SIZE"

# A populated image is the point; an empty one would still "build" and the gate
# would then fail with "no /gate3-init" instead of naming the real problem.
stats=$(dumpe2fs -h "$OUT" 2>/dev/null | awk -F: '
    /^Block count/ { total = $2 }
    /^Free blocks/ { free = $2 }
    END {
        gsub(/ /, "", total); gsub(/ /, "", free)
        printf "blocks=%s used=%s", total, total - free
    }')
used=$(printf '%s' "$stats" | sed -n 's/.*used=\([0-9]*\).*/\1/p')
[ "${used:-0}" -gt 0 ] || { echo "mkrootfs.sh: the image is empty" >&2; exit 1; }

echo "$OUT ($(stat -c %s "$OUT") bytes, $stats)"
