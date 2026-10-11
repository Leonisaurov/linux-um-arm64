#!/bin/bash
# Build the two userspace networking helpers against bionic, for the app.
#
# The guest's network is umnet + passt: umnet reframes between UML's vector
# `fd` transport and qemu's length-prefixed socket protocol, passt is the
# userspace TCP/IP stack that turns guest packets into ordinary outbound
# sockets. Neither needs any privilege, which is the whole point -- but both
# are separate processes, and until now both were glibc binaries.
#
# That is why networking works under `adb shell` and not in the app. An app
# process is started by zygote with a seccomp filter already installed, and
# glibc's startup issues rseq(2) and set_robust_list(2), which that filter
# kills: a glibc helper dies before main() with status 159 and no output at
# all. So the helpers have to be bionic binaries, exactly like the kernel that
# harness/build-bionic.sh produces.
#
# Unlike the kernel, neither helper has a kbuild to shim, so this script drives
# the NDK compiler directly. What it has to work around instead is passt's
# source: it was written for glibc and musl, and bionic differs from both in
# several headers. Those differences are fixed in the sources themselves and
# kept as dist/passt-bionic.patch, which explains each hunk; this script only
# makes sure the patch is applied to whatever tree it builds.
#
# The result is two static binaries. Static because Android has no dynamic
# loader available to an app, and an app may only exec from its
# nativeLibraryDir anyway -- same reasoning as CONFIG_STATIC_LINK for the
# kernel.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Same layout detection as build-bionic.sh: the harness lives at <repo>/harness
# in this tree and at <linux>/tools/um-arm64/harness when imported into a kernel
# tree, and the kernel source is the parent of whichever one this is.
if [ -f "$HERE/../linux/Makefile" ]; then
    TREE=${TREE:-$(cd "$HERE/.." && pwd)/linux}
elif [ -f "$HERE/../../../Makefile" ]; then
    TREE=${TREE:-$(cd "$HERE/../../.." && pwd)}
else
    TREE=${TREE:-$(cd "$HERE/.." && pwd)}
fi

SRC=${SRC:-}				# passt checkout at the pinned commit, patched or not
[ -n "$SRC" ] || {
    echo "build-net-bionic.sh: set SRC=/path/to/passt" >&2
    echo "  the pin and the patch are recorded in CI.md; the short version is" >&2
    echo "  git clone https://passt.top/passt && git checkout defc25b9444c508d21badb6bc9a0b835ddd01126" >&2
    exit 2
}
# Derived from where this script is, not from a home directory: this file used
# to name /root/mlu-arm64, which told anyone else reading it very little and
# made the script unusable anywhere else.
UMNET=${UMNET:-$HERE/umnet.c}
# The app-side helpers. Not networking, but the same thing: statically linked
# bionic binaries the app execs out of nativeLibraryDir. They are built here
# rather than in a script of their own so that "what the app can exec" is
# defined in one place and CI has one call to keep working.
APPSECCOMP=${APPSECCOMP:-$HERE/probe/appseccomp.c}
UMUSB=${UMUSB:-$HERE/umusb.c}
SOCKPROBE=${SOCKPROBE:-$HERE/probe/sockprobe.c}
PATCH=${PATCH:-$HERE/../dist/passt-bionic.patch}
ART=${ART:-$TREE/../artifacts}
# Same level the kernel is built at, for the same reason: 30 is the oldest
# bionic that declares everything used directly. The phone is API 35.
API=${API:-30}
O=${O:-/tmp/umnet-build-bionic}

# The largest page size these binaries have to run on. It is used twice.
#
# The link needs it: ld defaults to 4K segment alignment, and the kernel's ELF
# loader mmaps each LOAD segment at its own page granularity, so a binary whose
# (p_vaddr - p_offset) is only 4K-aligned cannot be loaded at all on a 16K-page
# kernel -- and Android 15 devices ship those. The kernel image dodges this by
# linking at 64K; these two get told explicitly.
#
# passt also bakes PAGE_SIZE in at compile time, from the *build* host's
# getconf, which cannot answer for the phone. It uses it only to align pkt_buf,
# to round the log rotation size and to round the MSS offered to the guest, so
# a value larger than the target's is harmless where a smaller one under-aligns.
PAGE=${PAGE:-16384}

# Widen passt's own seccomp allowlist if bionic turns out to need a syscall
# glibc did not -- the symptom would be passt dying on SIGSYS right after
# start-up, and the likely candidates are the ones Android's malloc uses:
# EXTRA_SYSCALLS="madvise mmap munmap mprotect". Empty by default, because
# every entry weakens the sandbox and no addition has been needed: the same
# sources built for x86_64-Android install the filter, survive it, answer ARP
# and complete a DHCP handshake on this build machine.
EXTRA_SYSCALLS=${EXTRA_SYSCALLS:-}

# The NDK, discovered the same way build-bionic.sh does it rather than assuming
# one path: $NDK and the two variables Google's tooling sets first, then the
# usual install locations, and the prebuilt for *this* host -- the stock NDK
# carries linux-x86_64 only, so an aarch64 machine needs a repacked one.
prebuilt_for_host() {
    local prefer other d

    case "$(uname -m)" in
    aarch64 | arm64) prefer=linux-aarch64 ;;
    x86_64 | amd64)  prefer=linux-x86_64 ;;
    *)               prefer= ;;
    esac
    [ "$prefer" = linux-aarch64 ] && other=linux-x86_64 || other=linux-aarch64

    for d in $prefer $other; do
        [ -x "$1/toolchains/llvm/prebuilt/$d/bin/clang" ] && { echo "$d"; return 0; }
    done
    return 1
}

if [ -z "${NDK:-}" ]; then
    for c in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" \
             "$HOME"/Android/ndk/* "$HOME"/Library/Android/sdk/ndk/* \
             /usr/lib/android-ndk /opt/android-ndk* \
             "${TMPDIR:-/tmp}"/ndk/android-ndk-*; do
        [ -n "$c" ] && prebuilt_for_host "$c" >/dev/null && NDK=$c
    done
fi
HOSTPRE=$(prebuilt_for_host "${NDK:-/nonexistent}") || {
    echo "build-net-bionic.sh: no Android NDK found for this host (set NDK=)" >&2
    echo "  looked at \$NDK, \$ANDROID_NDK_HOME, \$ANDROID_NDK_ROOT," >&2
    echo "  ~/Android/ndk/*, /opt/android-ndk*, ${TMPDIR:-/tmp}/ndk/*" >&2
    exit 2
}
TOOL=$NDK/toolchains/llvm/prebuilt/$HOSTPRE/bin
CC="$TOOL/clang --target=aarch64-linux-android$API"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$ART/build-net-bionic-$STAMP.log
mkdir -p "$O" "$ART"

{
    echo "### net helpers bionic build $STAMP"
    echo "### ndk=$NDK api=$API page=$PAGE host_prebuilt=$HOSTPRE"
    echo "### passt=$SRC head=$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"
} > "$LOG"

# check_bin() - Fail unless $1 is a helper an Android app can actually exec
#
# All three of these fail the same silent way -- the app execs the helper and
# gets nothing, no output, no clue -- so check them here rather than on the
# phone: a PT_INTERP is an interpreter the app cannot load, the wrong libc dies
# in zygote's seccomp filter before main(), and LOAD segments aligned below the
# device's page size make the ELF unloadable outright.
check_bin() {
    local f=$1 align

    if "$TOOL/llvm-readelf" -l "$f" | grep -q INTERP; then
	echo "$f: has PT_INTERP, not usable in an app" >&2
	return 1
    fi

    # Built against bionic, which is the whole point of this build -- and
    # checked through the ELF rather than through file(1)'s opinion of it.
    # The check used to require "for Android" in file -b's output, which is a
    # property of the file(1) version: Termux's prints it, Ubuntu's does not,
    # so the same binary passed here and failed on the runner. What the NDK's
    # linker actually writes is the .note.android.ident section, and readelf
    # is the tool that reads it.
    if ! "$TOOL/llvm-readelf" -h "$f" | grep -q 'Machine:.*AArch64'; then
	echo "$f: not an aarch64 binary: $(file -b "$f")" >&2
	return 1
    fi
    if ! "$TOOL/llvm-readelf" -n "$f" | grep -q 'Android'; then
	echo "$f: no Android note, so not a bionic build: $(file -b "$f")" >&2
	return 1
    fi

    for align in $("$TOOL/llvm-readelf" -l "$f" | awk '$1 == "LOAD" { print $NF }'); do
	if [ "$((align))" -lt "$PAGE" ]; then
	    echo "$f: LOAD aligned $align < $PAGE, will not load on a $PAGE-page kernel" >&2
	    return 1
	fi
    done
    return 0
}

### umnet -- one translation unit, nothing to work around
$CC -O2 -Wall -Wextra -static -Wl,-z,max-page-size="$PAGE" \
    -o "$O/umnet" "$UMNET" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { echo "umnet build failed rc=$rc log=$LOG"; exit "$rc"; }

### the app helpers -- one translation unit each, nothing to work around
for spec in "$APPSECCOMP:appseccomp" "$UMUSB:umusb" "$SOCKPROBE:sockprobe"; do
    src=${spec%:*}; name=${spec#*:}
    [ -f "$src" ] || { echo "$name: no source at $src" >&2; exit 2; }
    $CC -O2 -Wall -static -Wl,-z,max-page-size="$PAGE" \
        -o "$O/$name" "$src" 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo "$name build failed rc=$rc log=$LOG"; exit "$rc"; }
    check_bin "$O/$name" || exit 1
    cp -f "$O/$name" "$ART/${name}_bionic"
done

### passt
#
# Build from a copy, never in $SRC: concurrent builds for other targets share
# that checkout, and passt builds in-tree.
rm -rf "$O/passt-src"
mkdir -p "$O/passt-src"
tar -C "$SRC" --exclude=.git -cf - . | tar -C "$O/passt-src" -xf -
cd "$O/passt-src" || exit 1

# A checkout that has been built in still holds those outputs, and the copy
# keeps their mtimes -- so make would happily ship a stale glibc binary, or
# worse, reuse a seccomp.h generated for another architecture, whose AUDIT_ARCH
# check kills passt on its first syscall. Delete them and let make regenerate.
rm -f passt pasta passt-repair pesto passt.avx2 pasta.avx2 \
      seccomp.h seccomp_repair.h seccomp_pesto.h

# Accept either a pristine or an already-patched tree, so this works both from
# the working checkout and from a fresh clone at the patch's base commit.
if patch -p1 -R --dry-run --silent < "$PATCH" >/dev/null 2>&1; then
    echo "### sources already carry $PATCH" | tee -a "$LOG"
elif patch -p1 --silent < "$PATCH" >/dev/null 2>&1; then
    echo "### applied $PATCH" | tee -a "$LOG"
else
    echo "$PATCH applies neither forwards nor backwards to $SRC" >&2
    exit 2
fi

# TARGET/ARCH: the Makefile derives both from `$(CC) -dumpmachine`, which for
# the NDK driver reports the *host*. ARCH in particular feeds seccomp.sh, which
# turns it into the AUDIT_ARCH_* the generated filter checks against.
#
# CFLAGS/CPPFLAGS land after the Makefile's own, which is what makes -static
# and the PAGE_SIZE override stick; -U first because a second -D of a macro
# already given on the command line is a redefinition.
VERSION=$(git -C "$SRC" describe --tags --always HEAD 2>/dev/null || echo unknown)
make CC="$CC" ARCH=aarch64 TARGET=aarch64-linux-android \
     VERSION="$VERSION-bionic" EXTRA_SYSCALLS="$EXTRA_SYSCALLS" \
     CFLAGS="-static -Wl,-z,max-page-size=$PAGE" \
     CPPFLAGS="-UPAGE_SIZE -DPAGE_SIZE=$PAGE" \
     passt 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { echo "passt build failed rc=$rc log=$LOG"; exit "$rc"; }

check_bin "$O/umnet" && check_bin "$O/passt-src/passt" || exit 1

cp -f "$O/umnet" "$ART/umnet_bionic"
cp -f "$O/passt-src/passt" "$ART/passt_bionic"
{
    echo "umnet_bionic: $(file -b "$ART/umnet_bionic" | cut -c1-90)"
    echo "passt_bionic: $(file -b "$ART/passt_bionic" | cut -c1-90)"
    for n in appseccomp umusb sockprobe; do
        echo "${n}_bionic: $(file -b "$ART/${n}_bionic" | cut -c1-90)"
    done
    echo "md5=$(md5sum "$ART/umnet_bionic" | cut -c1-8)/$(md5sum "$ART/passt_bionic" | cut -c1-8)"
} | tee -a "$LOG"
echo "net helpers bionic build rc=0 log=$LOG"
exit 0
