#!/bin/bash
# Verify a built umarm APK, on the machine that built it.
#
# There is no device here, so this cannot be "install it and see". What it can do
# is check the things that only fail on a device, at the point where a failure is
# cheap to read:
#
#   * the signature verifies, because Android refuses to install an unsigned
#     APK, and that refusal happens on the phone, after the download;
#   * the native binaries are actually inside lib/arm64-v8a/ and are aarch64
#     static executables -- the whole reason they are shipped as lib*.so is that
#     the app's data directory cannot be executed from, and an ELF for the wrong
#     architecture or a dynamic one would only show up as a failure to exec;
#   * the assets the app reads at startup are present, including the initramfs
#     without which the kernel has nothing to boot;
#   * the manifest says what the app needs to say: the package name, an SDK range
#     the binaries can run in, and the USB device filter that makes the
#     passthrough attach prompt appear.
#
#   ci-umapp.sh <umarm.apk>
#
# Exits non-zero if any check fails.
set -uo pipefail

APK=${1:?usage: ci-umapp.sh <umarm.apk>}
BT=${BT:-$(ls -d "${ANDROID_HOME:-/usr/local/lib/android/sdk}"/build-tools/* 2>/dev/null | sort -V | tail -1)}
AAPT2=${AAPT2:-$BT/aapt2}
APKSIGNER=${APKSIGNER:-$BT/apksigner}

CHECKS=0
FAILED=0

ok() {
    CHECKS=$((CHECKS + 1))
    printf 'ok   %s\n' "$*"
}

bad() {
    CHECKS=$((CHECKS + 1))
    FAILED=$((FAILED + 1))
    printf 'FAIL %s\n' "$*"
}

check() { # check <description> <command...>
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

[ -f "$APK" ] || { echo "ci-umapp.sh: no APK at $APK" >&2; exit 2; }
[ -x "$AAPT2" ] || { echo "ci-umapp.sh: no aapt2 at $AAPT2" >&2; exit 2; }
[ -x "$APKSIGNER" ] || { echo "ci-umapp.sh: no apksigner at $APKSIGNER" >&2; exit 2; }

echo "apk $(stat -c %s "$APK") bytes, build-tools $(basename "$BT")"

# --- the signature, which is what the phone checks first --------------------
sig=$("$APKSIGNER" verify --print-certs "$APK" 2>&1)
if [ $? = 0 ]; then
    ok "the signature verifies"
    printf '%s\n' "$sig" | grep -m1 'Signer #1 certificate DN' | sed 's/^/     /'
else
    bad "the signature does not verify"
    printf '%s\n' "$sig" | head -5 | sed 's/^/     /'
fi

# --- the manifest -----------------------------------------------------------
badging=$("$AAPT2" dump badging "$APK" 2>&1)
pkg=$(printf '%s\n' "$badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
# aapt2 spells the minimum SDK differently across versions: the old aapt printed
# sdkVersion, newer aapt2 prints minSdkVersion. Both are accepted, and the lines
# that carry an SDK version are printed as evidence -- a format change should show
# up in the log as a format change, not as a mysterious FAIL.
printf '%s\n' "$badging" | grep -i 'dkversion' | sed 's/^/     /'
minsdk=$(printf '%s\n' "$badging" | sed -n "s/^\(min\)\?[sS]dkVersion:'\([^']*\)'.*/\2/p" | head -1)
native=$(printf '%s\n' "$badging" | sed -n "s/^native-code: \(.*\)/\1/p")

[ "$pkg" = "org.umarm.debian" ] && ok "package is org.umarm.debian" || bad "package is '$pkg', expected org.umarm.debian"
[ -n "$minsdk" ] && ok "minSdkVersion is $minsdk" || bad "no minSdkVersion in the badging output"
case "$native" in
*arm64-v8a*) ok "the manifest declares arm64-v8a native code" ;;
*) bad "the manifest declares native-code '$native', not arm64-v8a" ;;
esac
printf '%s\n' "$badging" | grep -q "uses-permission: name='android.permission.INTERNET'" \
    && ok "INTERNET is requested" || bad "INTERNET is not requested"

# --- the contents -----------------------------------------------------------
list=$(unzip -l "$APK" 2>/dev/null)
[ -n "$list" ] || { bad "the APK is not a readable zip"; list=""; }

for entry in classes.dex \
             lib/arm64-v8a/libuml.so lib/arm64-v8a/libstub.so \
             lib/arm64-v8a/libtermux.so \
             lib/arm64-v8a/libumnet.so lib/arm64-v8a/libpasst.so \
             lib/arm64-v8a/libprobe.so lib/arm64-v8a/libappseccomp.so \
             lib/arm64-v8a/libumusb.so \
             assets/initramfs.cpio.gz \
             assets/rootfs.ext4.gz \
             res/xml/device_filter.xml; do
    if printf '%s\n' "$list" | grep -q " $entry\$"; then
        size=$(printf '%s\n' "$list" | awk -v e="$entry" '$NF == e { print $1 }')
        ok "$entry is in the APK ($size bytes)"
    else
        bad "$entry is missing from the APK"
    fi
done

# The kernel is the point of the app, so it gets the same check the kernel
# artifact gets: an aarch64 ELF with no interpreter. A lib*.so that is a dynamic
# library, or built for the host, would extract fine and then fail to exec.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for lib in libuml.so libstub.so libumnet.so libpasst.so \
           libprobe.so libappseccomp.so libumusb.so; do
    if unzip -p "$APK" "lib/arm64-v8a/$lib" > "$tmp/$lib" 2>/dev/null && [ -s "$tmp/$lib" ]; then
        desc=$(file -b "$tmp/$lib")
        case "$desc" in
        *"ARM aarch64"*) ok "$lib is an aarch64 ELF" ;;
        *) bad "$lib is not an aarch64 ELF: $desc" ;;
        esac
        if readelf -l "$tmp/$lib" 2>/dev/null | grep -q INTERP; then
            bad "$lib has PT_INTERP, so it needs a dynamic loader the app cannot provide"
        else
            ok "$lib has no PT_INTERP (static)"
        fi
    else
        bad "$lib could not be extracted"
    fi
done

# libtermux.so is the one native piece that is *not* a static executable: it is
# an ordinary shared object loaded into the app process, and it is what turns
# the guest console into a pty. Checking it as "aarch64 with no PT_INTERP" would
# pass for the wrong reason, so it gets its own two checks -- the right kind of
# ELF, and the JNI entry point the terminal calls.
if unzip -p "$APK" lib/arm64-v8a/libtermux.so > "$tmp/libtermux.so" 2>/dev/null && [ -s "$tmp/libtermux.so" ]; then
    desc=$(file -b "$tmp/libtermux.so")
    case "$desc" in
    *"shared object"*"ARM aarch64"*) ok "libtermux.so is an aarch64 shared object" ;;
    *) bad "libtermux.so is not an aarch64 shared object: $desc" ;;
    esac
    if readelf -sW "$tmp/libtermux.so" > "$tmp/libtermux.syms" 2>/dev/null &&
       grep -q "Java_com_termux_terminal_JNI_createSubprocess" "$tmp/libtermux.syms"; then
        ok "libtermux.so exports Java_com_termux_terminal_JNI_createSubprocess"
    else
        bad "libtermux.so does not export the pty entry point"
    fi
else
    bad "libtermux.so could not be extracted"
fi

# The terminal is vendored as Java sources, so an APK that lost the resource
# merge or the extra R classes still builds and signs perfectly -- and then
# crashes with NoClassDefFoundError on the phone. Ask the dex directly.
for cls in com/termux/view/TerminalView \
           com/termux/terminal/TerminalEmulator \
           com/termux/terminal/TerminalSession \
           com/termux/terminal/JNI \
           org/umarm/debian/MainActivity; do
    if unzip -p "$APK" classes.dex > "$tmp/dex" 2>/dev/null && grep -aq "L$cls;" "$tmp/dex"; then
        ok "classes.dex contains $cls"
    else
        bad "classes.dex does not contain $cls"
    fi
done

echo "checks=$CHECKS failed=$FAILED"
[ "$FAILED" = 0 ] && echo "verdict=PASS" || echo "verdict=FAIL"
[ "$FAILED" = 0 ] && echo "UMAPP_OK checks=$CHECKS"
[ "$FAILED" = 0 ]
