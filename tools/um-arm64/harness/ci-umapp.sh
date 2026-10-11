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
minsdk=$(printf '%s\n' "$badging" | sed -n "s/^sdkVersion:'\([^']*\)'.*/\1/p")
native=$(printf '%s\n' "$badging" | sed -n "s/^native-code: \(.*\)/\1/p")

[ "$pkg" = "org.umarm.debian" ] && ok "package is org.umarm.debian" || bad "package is '$pkg', expected org.umarm.debian"
[ -n "$minsdk" ] && ok "minSdkVersion is $minsdk" || bad "no minSdkVersion in the manifest"
case "$native" in
*arm64-v8a*) ok "the manifest declares arm64-v8a native code" ;;
*) bad "the manifest declares native-code '$native', not arm64-v8a" ;;
esac
printf '%s\n' "$badging" | grep -q "uses-permission: name='android.permission.INTERNET'" \
    && ok "INTERNET is requested" || bad "INTERNET is not requested"
printf '%s\n' "$badging" | grep -q 'device_filter' \
    && ok "the USB device filter is declared" || bad "the USB device filter is not declared"

# --- the contents -----------------------------------------------------------
list=$(unzip -l "$APK" 2>/dev/null)
[ -n "$list" ] || { bad "the APK is not a readable zip"; list=""; }

for entry in classes.dex \
             lib/arm64-v8a/libuml.so lib/arm64-v8a/libstub.so \
             lib/arm64-v8a/libumnet.so lib/arm64-v8a/libpasst.so \
             assets/initramfs.cpio.gz; do
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
for lib in libuml.so libstub.so; do
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

echo "checks=$CHECKS failed=$FAILED"
[ "$FAILED" = 0 ] && echo "verdict=PASS" || echo "verdict=FAIL"
[ "$FAILED" = 0 ] && echo "UMAPP_OK checks=$CHECKS"
[ "$FAILED" = 0 ]
