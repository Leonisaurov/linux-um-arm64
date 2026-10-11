#!/bin/bash
# Build a gate root filesystem: an ext4 image populated from a distribution,
# with the gate inits and the freestanding probes injected.
#
#   ./mkrootfs.sh /tmp/alpine.ext4                    # alpine (default, 64M)
#   DISTRO=debian SIZE=2G ./mkrootfs.sh /tmp/debian.ext4
#
# The Alpine path needs no root at all: `mke2fs -d <dir>` builds a filesystem
# from a directory tree with libext2fs and never mounts anything, and the Alpine
# minirootfs tarball contains no device nodes, which is the one thing that would
# have needed privileges. That is what makes a real block-device gate possible
# inside CI (and on a phone) instead of debootstrapping with loop mounts.
#
# The Debian path needs root twice, and only for reasons that have nothing to do
# with UML: debootstrap chowns and makes device nodes inside the tree it builds,
# and mke2fs records ownership and device nodes. Neither mounts anything, so
# there is still no loop device and no mount namespace involved -- the difference
# from the Alpine path is privilege, not mechanism. On a native arm64 host
# debootstrap needs no --foreign stage and no qemu-user.
#
# Both sources are pinned -- Alpine by URL and sha256, Debian by suite and
# mirror -- so a gate cannot silently change its guest underneath itself.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$PWD/alpine.ext4}
DISTRO=${DISTRO:-alpine}
SIZE=${SIZE:-64M}

ALPINE_VERSION=${ALPINE_VERSION:-3.21.4}
ALPINE_BASE=${ALPINE_BASE:-https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64}
ALPINE_TARBALL=alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz
ALPINE_SHA256=${ALPINE_SHA256:-4ccfb9feda48b4f40fd9aceaf32b61e575d407387589deaabbd77cd9ed51e165}

DEBIAN_SUITE=${DEBIAN_SUITE:-bookworm}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
# iproute2 and nftables are for the docker prerequisites gate: a veth pair into a
# bridge, and nftables, which is what Debian's iptables-nft actually speaks.
DEBIAN_INCLUDE=${DEBIAN_INCLUDE:-build-essential,file,procps,psmisc,ca-certificates,iproute2,nftables,util-linux,kmod,gzip,xz-utils}
SUDO=${SUDO:-sudo}

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

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/umarm-rootfs.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

case "$DISTRO" in
alpine)
    fetch "$ALPINE_TARBALL" || { echo "mkrootfs.sh: cannot download $ALPINE_TARBALL" >&2; exit 2; }

    # Verify before extracting, always -- the cache is not trusted either.
    echo "$ALPINE_SHA256  $CACHE/$ALPINE_TARBALL" | sha256sum -c - >&2 || {
        echo "mkrootfs.sh: sha256 mismatch for $ALPINE_TARBALL" >&2
        rm -f "$CACHE/$ALPINE_TARBALL"
        exit 2
    }

    tar -xzf "$CACHE/$ALPINE_TARBALL" -C "$STAGE"
    ;;
debian)
    command -v debootstrap >/dev/null 2>&1 || {
        echo "mkrootfs.sh: debootstrap not found (install debootstrap)" >&2
        exit 2
    }
    echo "debootstrap $DEBIAN_SUITE -> $STAGE" >&2
    $SUDO debootstrap --arch=arm64 --variant=minbase \
        --include="$DEBIAN_INCLUDE" "$DEBIAN_SUITE" "$STAGE" "$DEBIAN_MIRROR"
    # Identification, and a root that needs no password: this guest is reached
    # only through the UML console, never over a network.
    echo umarm-guest > "$STAGE/etc/hostname"
    printf '127.0.0.1\tlocalhost umarm-guest\n' > "$STAGE/etc/hosts"
    ;;
*)
    echo "mkrootfs.sh: unknown DISTRO=$DISTRO (alpine|debian)" >&2
    exit 2
    ;;
esac

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
# reuses $OUT across attempts. The Debian tree carries device nodes and root
# ownership from debootstrap, so that image is written with the same privilege
# debootstrap needed; the Alpine image is written unprivileged.
MKE2FS=()
[ "$DISTRO" = debian ] && MKE2FS=("$SUDO")
rm -f "$OUT"
"${MKE2FS[@]}" mke2fs -q -F -t ext4 -b 4096 -L "umarm-$DISTRO" -d "$STAGE" "$OUT" "$SIZE"

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
