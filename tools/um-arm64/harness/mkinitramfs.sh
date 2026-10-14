#!/bin/bash
# Build an initramfs.
#
# Two of them, for two different jobs:
#
#   DISTRO=guestinit  (default)  the gate-2 fixture: an initramfs whose /init is
#       the freestanding guestinit probe. No busybox, no libc, no external root
#       filesystem, so the fixture cannot fail for a reason that is not the
#       kernel: guestinit has its own _start, issues raw svc #0 calls, exercises
#       one guest capability per line, prints UMARM_GUEST_OK and powers off.
#
#   DISTRO=alpine  the guest the app boots when it has no disk image, and the
#       fixture the Alpine-initramfs gate boots. The Alpine minirootfs is
#       repacked with an /init of its own, so the archive carries a real busybox,
#       a real musl loader and a real libc -- which is the point: a static
#       freestanding /init cannot tell a complete archive from an empty one.
#
#   CC=clang ./mkinitramfs.sh /tmp/initramfs.cpio.gz
#   DISTRO=alpine ./mkinitramfs.sh /tmp/initramfs-alpine.cpio.gz
#
# The newc archive is written by an inline Python writer rather than by cpio(1),
# so this depends on nothing that is not already required to build the kernel.
# cpio is not installed on Termux and is an avoidable moving part.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$PWD/initramfs.cpio.gz}
DISTRO=${DISTRO:-guestinit}
CC=${CC:-clang}
TARGET=${TARGET:-aarch64-linux-gnu}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/umarm-initrd.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

case "$DISTRO" in
guestinit)
    # -fno-pic: guestinit supplies its own _start and there is no dynamic loader
    # in an initramfs. A position-independent image would need a relocation pass
    # that nothing performs, and the failure would look like a kernel bug.
    "$CC" --target="$TARGET" -static -nostdlib -ffreestanding -O1 \
          -fno-stack-protector -fno-pic \
          -o "$TMP/init" "$HERE/probe/guestinit.c"

    INIT="$TMP/init" OUT="$OUT" python3 - <<'PY'
import os, struct, sys

# Every header's mtime is a constant, not the time of the build. This archive is
# an input to the APK's identity -- build-apk.sh hashes it -- so a timestamp here
# would give every run a different identity, and every installed app would be
# offered an update to a build that differs only in when it was made. The
# `gzip -9n` at the end is the other half of the same rule.
MTIME = 0

init = os.environ["INIT"]
out = os.environ["OUT"]

data = open(init, "rb").read()
if len(data) < 1024:
    sys.exit("mkinitramfs: /init is suspiciously small")
# e_type at offset 16: 2 is ET_EXEC. A DYN image here would not be relocated.
if data[:4] != b"\x7fELF" or struct.unpack_from("<H", data, 16)[0] != 2:
    sys.exit("mkinitramfs: /init is not a static ET_EXEC aarch64 ELF")

def entry(name, mode, body):
    hdr = b"070701" + b"".join(
        b"%08X" % v for v in (
            1,            # ino
            mode,         # mode
            0, 0,         # uid, gid
            1,            # nlink
            MTIME,        # mtime
            len(body),    # filesize
            0, 0,         # devmajor, devminor
            0, 0,         # rdevmajor, rdevminor
            len(name) + 1,  # namesize
            0,            # check
        )
    )
    return hdr + name + b"\0" + b"\0" * (-(110 + len(name) + 1) % 4) \
         + body + b"\0" * (-len(body) % 4)

blob = entry(b"init", 0o100755, data) + entry(b"TRAILER!!!", 0, b"")
with open(out, "wb") as f:
    f.write(blob)
PY
    ;;

alpine)
    . "$HERE/pins.sh"

    fetch "$ALPINE_TARBALL"
    echo "$ALPINE_SHA256  $CACHE/$ALPINE_TARBALL" | sha256sum -c - >&2 || {
        echo "mkinitramfs.sh: sha256 mismatch for $ALPINE_TARBALL" >&2
        exit 1
    }

    ROOT="$TMP/root"
    mkdir -p "$ROOT"
    # --no-same-owner because the tarball records uid/gid and this runs as an
    # ordinary user on the runner. Nothing in the image needs to be root-owned:
    # /init is PID 1 either way, and the minirootfs carries no device nodes --
    # devtmpfs provides /dev -- which is the one thing that would have needed
    # privilege to reproduce.
    tar -xzf "$CACHE/$ALPINE_TARBALL" -C "$ROOT" --no-same-owner

    install -m 0755 "$HERE/initrd/alpine-init" "$ROOT/init"

    ROOT="$ROOT" OUT="$OUT" python3 - <<'PY'
import os, stat, struct, sys

# As above: the time of the build is not part of the build, and this archive's
# bytes are part of the APK's identity.
MTIME = 0

root = os.environ["ROOT"]
out = os.environ["OUT"]

def entry(name, mode, body=b"", nlink=1):
    if isinstance(name, str):
        name = name.encode()
    hdr = b"070701" + b"".join(
        b"%08X" % v for v in (
            1,            # ino
            mode,         # mode
            0, 0,         # uid, gid
            nlink,        # nlink
            MTIME,        # mtime
            len(body),    # filesize
            0, 0,         # devmajor, devminor
            0, 0,         # rdevmajor, rdevminor
            len(name) + 1,  # namesize
            0,            # check
        )
    )
    return hdr + name + b"\0" + b"\0" * (-(110 + len(name) + 1) % 4) \
         + body + b"\0" * (-len(body) % 4)

blob = b""
entries = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    filenames.sort()
    rel = os.path.relpath(dirpath, root)
    if rel != ".":
        st = os.lstat(dirpath)
        blob += entry(rel, st.st_mode)
        entries += 1
    for fn in filenames:
        path = os.path.join(dirpath, fn)
        st = os.lstat(path)
        name = os.path.join(rel, fn) if rel != "." else fn
        if stat.S_ISLNK(st.st_mode):
            blob += entry(name, st.st_mode, os.readlink(path).encode())
        elif stat.S_ISREG(st.st_mode):
            with open(path, "rb") as f:
                blob += entry(name, st.st_mode, f.read())
        else:
            # Device nodes and fifos are skipped rather than faked: the init
            # mounts devtmpfs, so /dev is the kernel's, not the archive's.
            continue
        entries += 1

blob += entry(b"TRAILER!!!", 0)
if entries < 100:
    sys.exit("mkinitramfs: only %d entries -- the tarball did not unpack" % entries)
with open(out, "wb") as f:
    f.write(blob)
sys.stderr.write("mkinitramfs: %d entries\n" % entries)
PY
    ;;

*)
    echo "mkinitramfs.sh: DISTRO must be guestinit or alpine, not '$DISTRO'" >&2
    exit 2
    ;;
esac

gzip -9n -c "$OUT" > "$OUT.gz" && mv "$OUT.gz" "$OUT" 2>/dev/null || \
    { echo "mkinitramfs.sh: gzip failed" >&2; exit 1; }

echo "$OUT ($(stat -c %s "$OUT") bytes, DISTRO=$DISTRO)"
