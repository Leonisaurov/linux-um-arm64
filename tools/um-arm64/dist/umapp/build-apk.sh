#!/bin/bash
# Build the umarm APK without Gradle.
#
# Gradle would drag in a whole Android project layout and a network fetch of its
# own toolchain; this needs four tools and about ten seconds. The pieces:
#
#   aapt2 / aapt  package resources and the manifest into a partial APK
#   javac         compile the one Activity against android.jar
#   d8            translate the .class files into classes.dex
#   apksigner     sign it (Android refuses to install an unsigned APK)
#
# The native binaries are the interesting part. An Android app runs in the
# untrusted_app SELinux domain, which forbids executing anything the app itself
# wrote -- so the kernel, the stub, passt and umnet cannot simply be unpacked
# into the app's data directory and run. The one exception is the native library
# directory the platform unpacks from the APK, so each binary is shipped as a
# lib*.so under lib/arm64-v8a/ and executed from getApplicationInfo()
# .nativeLibraryDir. They are ordinary executables, not shared libraries; the
# name is what matters, not the format.
# -e as well as -uo pipefail. Without it a failing aapt2 or d8 left the previous
# umarm.apk sitting on disk, the script carried on to "signing" and printed the
# usual "install with: ..." line, and `adb install` then reported Success --
# for the build before the change being tested. A broken manifest looked
# exactly like a working one until the behaviour on the device made no sense.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# <kernel>/tools/um-arm64/dist/umapp -> <kernel>/tools/um-arm64, which is the
# layout the paths below assume. It used to be the author's /root/mlu-arm64,
# which made the script work in exactly one place.
ROOT=${ROOT:-$(cd "$HERE/../.." && pwd)}
# Newest first, and $ANDROID_HOME is where it looks before /tmp: the CI runner
# ships the SDK under that variable, and a scratch unpack under /tmp should not
# have to be moved for this to work. r34's d8 throws an internal
# NullPointerException on classes compiled by JDK 21 ("Cannot invoke
# String.length() because <parameter1> is null"), which reads like a bug in the
# app source and is not one -- r35's d8 takes the identical .class files. Picking
# the lowest version found made that failure depend on which build-tools happened
# to be unpacked.
SDK=${ANDROID_HOME:-/usr/local/lib/android/sdk}
# The globs are expanded by the shell and filtered here rather than passed to
# ls: `ls` exits 2 when one of its arguments matches nothing, and under
# `set -o pipefail` that status becomes the pipeline's, which the assignment
# inherits, which `set -e` turns into a silent exit. That is exactly what happened
# on the CI runner, where /tmp/bt*/android-* does not exist: the script printed
# nothing and exited 2, because `2>/dev/null` had discarded ls's complaint.
# A picker that always succeeds leaves the checks below to report a missing
# toolchain in words.
pick() {
	local p
	for p in "$@"; do
		if [ -e "$p" ]; then printf '%s\n' "$p"; fi
	done
	return 0
}
BT=${BT:-$(pick "$SDK"/build-tools/* /tmp/bt*/android-* | sort -V | tail -1)}
ANDROID_JAR=${ANDROID_JAR:-$(pick "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)}
OUT=${OUT:-$HERE/build}
APK=${APK:-$HERE/umarm.apk}

# What goes in as a "native library". Each entry is src:libname.
BINARIES=(
	"$ROOT/artifacts/linux-bionic:libuml.so"
	"$ROOT/artifacts/stub_exe_bionic:libstub.so"
	# The pty half of the terminal: Termux's terminal-emulator fork/execs the
	# "shell" -- here the kernel -- on a pseudoterminal, which is what makes the
	# guest console a real tty instead of a pipe. Unlike every other entry here it
	# is an ordinary shared object, loaded with System.loadLibrary("termux").
	"$ROOT/artifacts/libtermux_bionic:libtermux.so"
	# A scratch slot for probes: whatever is here can be exec'd in the app's
	# own uid and SELinux domain via `run-as`, which /data/local/tmp cannot be.
	"$ROOT/artifacts/sockprobe_bionic:libprobe.so"
	"$ROOT/dist/umdebian/umnet:libumnet.so"
	"$ROOT/dist/umdebian/passt:libpasst.so"
	"$ROOT/dist/umdebian/appseccomp:libappseccomp.so"
	# The USB/IP server side of the passthrough. Absent until it is built,
	# and the app says so rather than failing obscurely: with "usb" ticked
	# and no libumusb.so it prints "not in this build" and boots without it.
	"$ROOT/dist/umdebian/umusb:libumusb.so"
)
INITRAMFS=${INITRAMFS:-$ROOT/rootfs/initramfs-alpine.cpio.gz}
rm -f "$(dirname "$0")/umarm.apk"

# Off by default: a gzipped ext4 to bake into the APK. The app downloads its
# guest image from a release instead, so this is for a build that has to run with
# no network at all -- ci-umapp.sh still checks it when it is present.
ROOTFS_GZ=${ROOTFS_GZ:-}

for t in "$BT/aapt2" "$BT/d8" "$BT/apksigner"; do
	[ -x "$t" ] || { echo "build-apk: missing $t" >&2; exit 2; }
done
[ -f "$ANDROID_JAR" ] || { echo "build-apk: no android.jar (set ANDROID_JAR)" >&2; exit 2; }
command -v javac >/dev/null || { echo "build-apk: no javac" >&2; exit 2; }

rm -rf "$OUT"
mkdir -p "$OUT/res" "$OUT/classes" "$OUT/lib/arm64-v8a" "$OUT/assets"

# The app's identity: a digest of everything that goes into it, baked into the
# manifest as org.umarm.recipe and written beside the APK as build/recipe. It is
# what the update check compares with the newest umarm-* release, so an update is
# published and offered only when something actually changed. A version code
# bumped by hand would work too, but it is a thing to forget; a digest of the
# inputs cannot forget.
#
# The binaries are hashed by content, not by path: the kernel is most of the APK,
# and a kernel rebuilt from a changed tree has to produce a new identity.
#
# $HERE/AndroidManifest.xml is hashed with the __UMARM_RECIPE__ placeholder still
# in it, which is what keeps this from depending on its own output.
RECIPE=$(
	{
		printf 'manifest\n'; cat "$HERE/AndroidManifest.xml"
		printf 'res\n';      find "$HERE/res" -type f -print0 | sort -z | xargs -0 -r cat
		printf 'src\n';      find "$HERE/src" -type f -print0 | sort -z | xargs -0 -r cat
		printf 'jni\n';      find "$HERE/jni" -type f -print0 | sort -z | xargs -0 -r cat
		printf 'build\n';    cat "$HERE/build-apk.sh"
		printf 'initramfs\n'; md5sum "$INITRAMFS"
		for b in "${BINARIES[@]}"; do
			src=${b%%:*}
			printf 'bin %s\n' "$b"
			if [ -f "$src" ]; then md5sum "$src"; else printf 'missing\n'; fi
		done
	} | md5sum | cut -c1-12
)
printf '%s\n' "$RECIPE" > "$OUT/recipe"
echo "== recipe $RECIPE"

# The checked-in manifest carries the placeholder; the digest is not known until
# the files have been hashed, so it is substituted into a copy rather than being
# given a resource id.
sed "s/__UMARM_RECIPE__/$RECIPE/" "$HERE/AndroidManifest.xml" > "$OUT/AndroidManifest.xml"

# aapt2 compiles a directory tree, and $OUT is wiped on every build, so the
# checked-in resources have to be copied into it. res/xml/device_filter.xml is
# what the manifest's @xml/device_filter points at; without this copy aapt2
# link fails on an unresolved reference rather than producing an APK that is
# merely missing the USB attach filter.
if [ -d "$HERE/res" ]; then
	cp -a "$HERE/res/." "$OUT/res/"
fi

echo "== staging native binaries =="
for b in "${BINARIES[@]}"; do
	src=${b%%:*}; dst=${b##*:}
	if [ -f "$src" ]; then
		cp -f "$src" "$OUT/lib/arm64-v8a/$dst"
		printf '   %-14s %s\n' "$dst" "$(du -hL "$src" | cut -f1)"
	else
		echo "   WARNING: $src missing, $dst will be absent"
	fi
done

# The kernel is stripped once it is staged. Debug info is 131 MB of the 143 MB an
# unstripped one weighs, no phone reads it, and this is the file a person
# downloads -- so it ships the way a kernel is normally shipped. --strip-debug
# keeps .symtab. The CI android job strips too; a second pass over an
# already-stripped file is a no-op.
STRIP=${STRIP:-$(command -v llvm-strip || command -v aarch64-linux-gnu-strip || true)}
if [ -n "$STRIP" ] && [ -f "$OUT/lib/arm64-v8a/libuml.so" ]; then
	before=$(stat -c%s "$OUT/lib/arm64-v8a/libuml.so")
	"$STRIP" --strip-debug "$OUT/lib/arm64-v8a/libuml.so"
	after=$(stat -c%s "$OUT/lib/arm64-v8a/libuml.so")
	[ "$before" = "$after" ] || printf '   %-14s %s -> %s bytes\n' "stripped" "$before" "$after"
fi

echo "== staging assets =="
cp -f "$INITRAMFS" "$OUT/assets/initramfs.cpio.gz"
printf '   %-14s %s\n' "initramfs" "$(du -h "$INITRAMFS" | cut -f1)"
if [ -n "$ROOTFS_GZ" ] && [ -f "$ROOTFS_GZ" ]; then
	cp -f "$ROOTFS_GZ" "$OUT/assets/rootfs.ext4.gz"
	printf '   %-14s %s\n' "rootfs" "$(du -h "$ROOTFS_GZ" | cut -f1)"
fi

echo "== compiling =="
"$BT/aapt2" compile --dir "$OUT/res" -o "$OUT/res.zip" 2>/dev/null

# Each of these checks its own status rather than being filtered through a
# pipeline. `cmd | grep -v ... | head` cannot report failure under pipefail --
# and worse, grep -v exits 1 when it filters everything away, so a *clean*
# javac aborted the script once set -e was added.
# The vendored Termux terminal lives in com.termux.view / com.termux.terminal
# and refers to its own R class by those package names -- which is what a Gradle
# library module gets for free and this single-package, no-Gradle build does not.
# --extra-packages makes aapt2 emit the same R again under those names, so the
# sources resolve without the app's build growing a module system.
if ! "$BT/aapt2" link \
	-o "$OUT/base.apk" \
	-I "$ANDROID_JAR" \
	--manifest "$OUT/AndroidManifest.xml" \
	--java "$OUT/classes" \
	--extra-packages com.termux.view \
	--extra-packages com.termux.terminal \
	${ROOTFS_GZ:+} \
	"$OUT/res.zip" > "$OUT/aapt2.log" 2>&1; then
	echo "aapt2 link failed:" >&2
	head -20 "$OUT/aapt2.log" >&2
	exit 2
fi

if ! javac -source 8 -target 8 -nowarn \
	-bootclasspath "$ANDROID_JAR" \
	-classpath "$ANDROID_JAR" \
	-d "$OUT/classes" \
	$(find "$HERE/src" "$OUT/classes" -name '*.java') > "$OUT/javac.log" 2>&1; then
	echo "javac failed:" >&2
	grep -v "^Note:" "$OUT/javac.log" | head -20 >&2
	exit 2
fi

# --lib is not optional: without the framework on d8's classpath it fails with
# an internal NullPointerException on the first nested anonymous class, which
# looks like a compiler bug rather than a missing argument.
"$BT/d8" --min-api 26 --lib "$ANDROID_JAR" --output "$OUT" \
	$(find "$OUT/classes" -name '*.class') 2>&1 | head -5 || exit 2

echo "== packaging =="
# aapt2 link produced base.apk with resources and the manifest; add dex, libs
# and assets to it. Native libraries are stored uncompressed so the platform
# can extract them; assets are compressed because they are just data.
cd "$OUT"
cp base.apk staged.apk
zip -q -0 staged.apk classes.dex
zip -q -0 -r staged.apk lib
zip -q -9 -r staged.apk assets

echo "== signing =="
# debug.keystore is committed, not generated per build. Android refuses to
# update an app whose signing certificate changed -- the install fails with
# INSTALL_FAILED_UPDATE_INCOMPATIBLE, which reads as a certificate error -- and
# a key generated on first use changes the moment the file is lost or the build
# moves to another machine or CI runner. It is a self-signed debug key with a
# public password; that is all it is. The keytool line is the fallback for a
# tree that somehow lacks it.
KS="$HERE/debug.keystore"
if [ ! -f "$KS" ]; then
	keytool -genkeypair -keystore "$KS" -storepass umarmumarm -keypass umarmumarm \
		-alias umarm -keyalg RSA -keysize 2048 -validity 10000 \
		-dname "CN=umarm, OU=dev, O=umarm, L=x, S=x, C=xx" >/dev/null 2>&1
fi

"$BT/zipalign" -f -p 4 staged.apk aligned.apk >/dev/null 2>&1 || cp staged.apk aligned.apk
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:umarmumarm --key-pass pass:umarmumarm \
	--min-sdk-version 26 --out "$APK" aligned.apk || exit 2

echo
echo "APK: $APK  ($(du -h "$APK" | cut -f1))"
echo "install with:  adb install -r -t $APK"
