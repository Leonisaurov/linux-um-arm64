#!/bin/bash
# Build the minimal boot gate fixture: an initramfs whose /init is the
# freestanding guestinit probe.
#
# No busybox, no libc, no external root filesystem, so the fixture cannot fail
# for a reason that is not the kernel: guestinit has its own _start, issues raw
# svc #0 calls, exercises one guest capability per line, prints UMARM_GUEST_OK
# and powers the machine off. That is the whole of gate 2.
#
#   CC=clang ./mkinitramfs.sh /tmp/initramfs.cpio.gz
#
# The newc archive is written by an inline Python writer rather than by cpio(1),
# so the fixture depends on nothing that is not already required to build the
# kernel. cpio is not installed on Termux and is an avoidable moving part.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$PWD/initramfs.cpio.gz}
CC=${CC:-clang}
TARGET=${TARGET:-aarch64-linux-gnu}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/umarm-initrd.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# -fno-pic: guestinit supplies its own _start and there is no dynamic loader in
# an initramfs. A position-independent image would need a relocation pass that
# nothing performs, and the failure would look like a kernel bug.
"$CC" --target="$TARGET" -static -nostdlib -ffreestanding -O1 \
      -fno-stack-protector -fno-pic \
      -o "$TMP/init" "$HERE/probe/guestinit.c"

INIT="$TMP/init" OUT="$OUT" python3 - <<'PY'
import os, struct, sys, time

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
            int(time.time()),  # mtime
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

gzip -9n -c "$OUT" > "$OUT.gz" && mv "$OUT.gz" "$OUT" 2>/dev/null || \
    { echo "mkinitramfs.sh: gzip failed" >&2; exit 1; }

echo "$OUT ($(stat -c %s "$OUT") bytes)"
