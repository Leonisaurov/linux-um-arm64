#!/bin/bash
# Install umdebian onto an Android device over adb.
#
#   ./install.sh                          # ./linux-um-16k + ./debian.ext4
#   KERNEL=... IMAGE=... ./install.sh      # from wherever they are
#   ADB="adb -s 1A2B3C" DEST=/data/local/tmp/umdebian ./install.sh
#
# Nothing is installed in the Android sense: three files are copied into one
# directory, and deleting that directory removes everything. No root, no apk, no
# mounts, no package manager on the Android side.
#
# The one check that matters is the page size. A guest page is a host mmap, so a
# guest page size *below* the host's cannot work at all -- and it does not fail
# loudly, it hangs on the first fault. Refusing is cheaper than diagnosing that.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ADB=${ADB:-adb}
DEST=${DEST:-/data/local/tmp/umdebian}
KERNEL=${KERNEL:-$HERE/linux-um-16k}
IMAGE=${IMAGE:-$HERE/debian.ext4}
LAUNCHER=${LAUNCHER:-$HERE/deb}
STUB=${STUB:-$HERE/stub_exe}

command -v "${ADB%% *}" >/dev/null 2>&1 || {
	echo "install.sh: no '${ADB%% *}' in PATH" >&2
	exit 2
}
$ADB get-state >/dev/null 2>&1 || {
	echo "install.sh: no device (adb get-state failed)" >&2
	exit 2
}

for f in "$KERNEL" "$IMAGE" "$LAUNCHER"; do
	[ -f "$f" ] || { echo "install.sh: missing $f" >&2; exit 2; }
done

# The guest page size of an arbitrary kernel binary is not recorded anywhere
# convenient, so it comes from the file name (-4k / -16k, how the builds are
# published) or from GUEST_PAGESIZE. Guessing is not an option: the failure mode
# is a silent hang.
GUEST_PAGESIZE=${GUEST_PAGESIZE:-}
if [ -z "$GUEST_PAGESIZE" ]; then
	case "$(basename "$KERNEL")" in
	*-4k*)  GUEST_PAGESIZE=4096 ;;
	*-16k*) GUEST_PAGESIZE=16384 ;;
	*)
		echo "install.sh: cannot tell the guest page size from '$(basename "$KERNEL")'" >&2
		echo "            set GUEST_PAGESIZE=4096 or 16384" >&2
		exit 2
		;;
	esac
fi

HOST_PAGESIZE=$($ADB shell getconf PAGESIZE | tr -d '\r')
case "$HOST_PAGESIZE" in
'' | *[!0-9]*)
	echo "install.sh: cannot read the device page size: '$HOST_PAGESIZE'" >&2
	exit 2
	;;
esac

echo "install.sh: device page size $HOST_PAGESIZE, guest page size $GUEST_PAGESIZE"
if [ "$GUEST_PAGESIZE" -lt "$HOST_PAGESIZE" ]; then
	cat >&2 <<EOF
install.sh: REFUSING to install a $GUEST_PAGESIZE-byte guest page on a
            $HOST_PAGESIZE-byte host. A guest page is a host mmap, so this
            cannot work, and it hangs rather than failing. Use the -16k build:
            it runs on 4 KiB and 16 KiB hosts alike.
EOF
	exit 1
fi

echo "install.sh: pushing to $DEST"
$ADB shell mkdir -p "$DEST"
$ADB push "$KERNEL" "$DEST/linux-um"
$ADB push "$LAUNCHER" "$DEST/deb"
$ADB shell chmod 755 "$DEST/linux-um" "$DEST/deb"

# The stub is optional and only matters on an Android host, where execveat() on a
# memfd is refused: UML then has to exec a file, and this is it. The launcher
# picks it up from its own directory.
if [ -f "$STUB" ]; then
	$ADB push "$STUB" "$DEST/stub_exe"
	$ADB shell chmod 755 "$DEST/stub_exe"
	echo "install.sh: pushed stub_exe (needed where a memfd cannot be exec'd)"
fi

# The image is ~1.4 GB on disk and pushing it raw takes noticeably longer than
# compressing it does, so it goes over gzipped. gzip and not zstd: toybox ships
# gunzip on every Android version this targets, and zstd is not in toybox at
# all. NO_COMPRESS=1 pushes it as it is.
if [ "${NO_COMPRESS:-0}" = 1 ] || ! command -v gzip >/dev/null 2>&1; then
	$ADB push "$IMAGE" "$DEST/debian.ext4"
else
	echo "install.sh: compressing $(basename "$IMAGE") ($(du -h "$IMAGE" | cut -f1))"
	gzip -1 -c "$IMAGE" > "$IMAGE.gz"
	$ADB push "$IMAGE.gz" "$DEST/debian.ext4.gz"
	rm -f "$IMAGE.gz"
	$ADB shell "gzip -d -f $DEST/debian.ext4.gz"
fi

# Prove it on the device rather than reporting success from the fact that three
# pushes exited 0. adb's exit status is not evidence -- `adb shell` reports 0
# whatever the remote command did -- so the check is the output.
echo "install.sh: checking, $(basename "$KERNEL") on the device"
out=$($ADB shell "cd $DEST && sh ./deb uname -a" 2>&1)
printf '%s\n' "$out"

case "$out" in
*aarch64*)
	echo "install.sh: ok -- $DEST boots ($(basename "$KERNEL"))"
	echo "install.sh: cd $DEST && ./deb"
	;;
*)
	echo "install.sh: the guest did not report aarch64; the output above is the boot log" >&2
	exit 1
	;;
esac
