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
# The pins and the fetcher come from one place: mkinitramfs.sh builds an initramfs
# out of the same Alpine release, and two copies of a version string drift the
# moment one of them is updated.
. "$HERE/pins.sh"

# tar as an ordinary user applies the umask (--no-same-permissions is its
# default for non-root), which is how /etc/passwd and executables end up 0600
# and 0700 in these images. Ask tar for the archived modes, and fix the result
# afterwards so it does not depend on the tar either.
umask 022

CC=${CC:-clang}
TARGET=${TARGET:-aarch64-linux-gnu}

mkdir -p "$CACHE"

command -v mke2fs >/dev/null 2>&1 || {
    echo "mkrootfs.sh: mke2fs not found (install e2fsprogs)" >&2
    exit 2
}

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/umarm-rootfs.XXXXXX")

# debootstrap leaves a root-owned tree -- which is what the image has to contain,
# so chowning it to the invoking user is not an option -- and mke2fs records that
# ownership. Everything written into $STAGE after debootstrap therefore needs the
# same privilege, and so does deleting it again: the first version of this ran
# `rm -rf $STAGE` as the user, failed on every file debootstrap had left, and
# turned a successful build into exit 1 at the trap.
in_stage() {
    if [ "$DISTRO" = debian ]; then
        $SUDO "$@"
    else
        "$@"
    fi
}

cleanup() {
    in_stage rm -rf "$STAGE" 2>/dev/null || true
    return 0
}
trap cleanup EXIT

case "$DISTRO" in
alpine)
    fetch "$ALPINE_TARBALL" || { echo "mkrootfs.sh: cannot download $ALPINE_TARBALL" >&2; exit 2; }

    # Verify before extracting, always -- the cache is not trusted either.
    echo "$ALPINE_SHA256  $CACHE/$ALPINE_TARBALL" | sha256sum -c - >&2 || {
        echo "mkrootfs.sh: sha256 mismatch for $ALPINE_TARBALL" >&2
        rm -f "$CACHE/$ALPINE_TARBALL"
        exit 2
    }

    tar -xpzf "$CACHE/$ALPINE_TARBALL" -C "$STAGE" --no-same-owner
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
    printf '%s\n' umarm-guest | in_stage tee "$STAGE/etc/hostname" >/dev/null
    printf '127.0.0.1\tlocalhost umarm-guest\n' | in_stage tee "$STAGE/etc/hosts" >/dev/null
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
    in_stage install -m 0755 "$f" "$STAGE/$(basename "$f")"
done

# The Alpine image's PID 1 is the Alpine script, not the Debian one that
# guest/umarm-init is: this loop installs the whole guest directory into both
# distros, so the Debian init lands in the Alpine tree too. Put the right one
# back under the name both launchers boot (init=/umarm-init).
if [ "$DISTRO" = alpine ]; then
    in_stage install -m 0755 "$HERE/guest/umarm-init-alpine" "$STAGE/umarm-init"
fi

compile_probe() {
    local src=$1 name=$2 tmp

    tmp=$(mktemp "${TMPDIR:-/tmp}/umarm-probe.XXXXXX")

    # Compiled as the invoking user and installed with the tree's privilege:
    # there is no reason to run a compiler as root, and on the Debian path the
    # destination is not writable without it.
    "$CC" --target="$TARGET" -static -nostdlib -ffreestanding -O1 \
          -fno-stack-protector -fno-pic -o "$tmp" "$src"

    # ET_EXEC, not ET_DYN: nothing relocates a PIE in a rootfs whose loader is
    # the guest's, and a DYN probe would fail in a way that looks like the
    # kernel faulting on the first instruction.
    python3 - "$tmp" <<'PY'
import struct, sys
p = sys.argv[1]
d = open(p, "rb").read(20)
if d[:4] != b"\x7fELF" or struct.unpack_from("<H", d, 16)[0] != 2:
    sys.exit(f"{p} is not a static ET_EXEC aarch64 ELF")
PY

    in_stage install -m 0755 "$tmp" "$STAGE/$name"
    rm -f "$tmp"
}

compile_probe "$HERE/probe/fptorture.c" fptorture
# The clock rate gate: the guest's CLOCK_MONOTONIC against the host's wall time.
# Freestanding like the rest, because that is the only thing this path can build
# -- clockcheck.c wants printf and cannot be linked here at all.
compile_probe "$HERE/probe/clockprobe.c" clockprobe
# The fork+reap volume for the fault-injection gate, from a binary: a shell
# cannot survive its own fork failing. See harness/probe/stubfork.c.
compile_probe "$HERE/probe/stubfork.c" stubfork

# e2fsprogs refuses to overwrite an existing filesystem unless forced, and CI
# reuses $OUT across attempts. The Debian tree carries device nodes and root
# ownership from debootstrap, so that image is written with the same privilege
# debootstrap needed.
#
# The Alpine tree needs the same treatment for a reason that is not housekeeping.
# tar cannot restore the tarball's root:root without privilege, so an
# unprivileged extraction leaves the whole tree owned by the build user -- and
# the directories 0700, because that is what the extraction umask and the umask
# of whoever created them produce. mke2fs -d records whatever lstat(2) reports,
# so a non-root build bakes that ownership into the image. The guest root gets
# away with it through CAP_DAC_OVERRIDE, which is why every gate but one passes;
# inside a user namespace the on-disk uid has no mapping, capable_wrt_inode_uidgid()
# fails, and unshare(CLONE_NEWUSER) followed by any execve returns EACCES. That
# was reported as a kernel bug and is harness/guest/userns-init's subject.
if [ "$DISTRO" = alpine ]; then
    $SUDO chown -R 0:0 "$STAGE"
    # a+rX adds read everywhere, and execute where it is already meaningful (a
    # directory, or a file that had it) without flattening setuid, setgid or the
    # sticky bit: /tmp stays 1777, and /root is put back to 0700 below.
    $SUDO chmod -R a+rX "$STAGE"
    $SUDO chmod 0640 "$STAGE/etc/shadow" "$STAGE/etc/gshadow" 2>/dev/null || true
    $SUDO chmod 0700 "$STAGE/root" 2>/dev/null || true
fi

MKE2FS=()
[ "$DISTRO" = debian ] && MKE2FS=("$SUDO")
# mke2fs has to see the fixed ownership, so it runs with the same privilege the
# chown needed on the Alpine path too.
[ "$DISTRO" = alpine ] && MKE2FS=("$SUDO")
rm -f "$OUT"
"${MKE2FS[@]}" mke2fs -q -F -t ext4 -b 4096 -L "umarm-$DISTRO" -d "$STAGE" "$OUT" "$SIZE"

# The image has to belong to the invoking user, not to whoever ran mke2fs. With
# sudo the file is created root-owned, and then UML cannot open it for writing --
# and open_ubd_file() *silently* falls back to read-only on EACCES:
#
#     if (!openflags->w || ((fd != -EROFS) && (fd != -EACCES)))
#             return fd;
#     openflags->w = 0;
#
# So `rw` on the command line was quietly ignored, the guest got a read-only
# root, and nothing said so. No gate had ever written to the Debian image, which
# is why this went unnoticed until one did.
if [ "$DISTRO" = debian ]; then
    $SUDO chown "$(id -u):$(id -g)" "$OUT"
fi

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
