#!/bin/bash
# Verify the shipped artifact, not the kernel underneath it.
#
# The rest of CI gates the kernel: it boots, it forks, it keeps FP state, it
# writes to hostfs. This gates dist/umdebian, which is the thing a person
# actually uses, and whose contract is the *launcher*: a command in, its output
# out, its exit status propagated, a host directory shared both ways, and a
# sentence instead of a stack trace when the image is already in use. None of
# that is kernel behaviour, and all of it is shell between a user and a booted
# kernel -- which is exactly the kind of code that breaks silently.
#
# It runs on a real arm64 host with the same kernel and the same image as a
# phone, so the only thing it does not cover is Android's uid and SELinux
# domain. The launcher is started with `sh` instead of its /system/bin/sh
# shebang, which is the one Android-specific line in it.
#
#   KERNEL_BIN=artifacts/default/linux-um-arm64 IMAGE=debian.ext4 ./ci-umdebian.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL_BIN=${KERNEL_BIN:?set KERNEL_BIN to the UML kernel to ship}
IMAGE=${IMAGE:?set IMAGE to the Debian rootfs image}
WORK=${WORK:-$PWD/umdebian-ci}
DIST=$WORK/umdebian

log() { echo "[umdebian] $*"; }

# mktemp or a plain directory: this runs once per CI job, and a stale directory
# from a rerun must not be able to contribute a file the guest finds.
rm -rf "$WORK"
mkdir -p "$DIST/share"

# The launcher's own file names, because that is the interface as shipped: it
# looks for ./linux-um and (by default) ./debian.ext4 next to itself.
install -m 0755 "$KERNEL_BIN" "$DIST/linux-um"
install -m 0755 "$HERE/../dist/umdebian/deb" "$DIST/deb"
# Hard-linked rather than copied: 2 GB through the page cache buys nothing here,
# and the guest is going to write to the image anyway. Falls back to a copy when
# the two are on different filesystems.
ln "$IMAGE" "$DIST/debian.ext4" 2>/dev/null || install -m 0644 "$IMAGE" "$DIST/debian.ext4"

FAILED=0
: > "$WORK/checks.txt"

# run <command-string>; leaves the launcher's output in OUT and its status in RC.
# A leading "-v " goes to the launcher as a flag, not as part of the command.
run() {
	local cmd=$1 vflag=()

	case "$cmd" in
	"-v "*) vflag=(-v); cmd=${cmd#-v } ;;
	esac
	set +e
	OUT=$(cd "$DIST" && sh ./deb "${vflag[@]}" "$cmd" 2>&1)
	RC=$?
	set -e
}

# A check names itself, the status it expects and a substring the output must
# contain (empty = do not care). Every failure prints the launcher's output:
# this is the layer where the interesting failure is usually a sentence the
# launcher printed, not a status.
#
# It never returns non-zero: under `set -e` the first failure would end the run
# and the remaining checks -- which are independent, and cheap -- would never
# say anything.
expect() {
	local name=$1 want_rc=$2 want=$3 cmd=$4

	if run "$cmd" && [ "$RC" = "$want_rc" ]; then
		if [ -z "$want" ] || printf '%s' "$OUT" | grep -qF -- "$want"; then
			echo "ok   $name (rc=$RC)"
			printf '%s\t%s\t%s\n' "$name" "rc=$RC" "$(printf '%s' "$OUT" | head -1)" \
				>> "$WORK/checks.txt"
			return 0
		fi
		echo "FAIL $name: output does not contain '$want'"
	else
		echo "FAIL $name: exit $RC, wanted $want_rc"
	fi
	printf '%s\n' "$OUT" | sed 's/^/     /'
	FAILED=1
	return 0
}

# Hashed once each: the image is 2 GB and md5sum walks all of it.
KERNEL_MD5=$(md5sum "$KERNEL_BIN" | cut -d' ' -f1)
IMAGE_MD5=$(md5sum "$IMAGE" | cut -d' ' -f1)
log "kernel $KERNEL_MD5 $(stat -c %s "$KERNEL_BIN") bytes"
log "image  $IMAGE_MD5 $(stat -c %s "$IMAGE") bytes"

# --- the contract -----------------------------------------------------------
# The command runs, on the real architecture, and its output comes back by
# itself. This is the check the whole artifact exists for.
expect "uname"        0 "aarch64"            "uname -m"
expect "uname-all"    0 "GNU/Linux"          "uname -a"
expect "shell-pipe"   0 "3"                  "echo one two three | wc -w"

# Exit status propagates. Without this the launcher composes with a shell the
# way a shell does, which is the only way it is usable in a script.
expect "exit-42"     42 ""                   "exit 42"
expect "false"        1 ""                   "false"
expect "exit-0"       0 ""                   "true"

# Only the command's output, and all of it: the boot log is hundreds of lines
# and none of them may leak into a one-shot run.
run "echo hello"
if [ "$(printf '%s' "$OUT")" = "hello" ]; then
	echo "ok   output-is-exactly-the-command's"
	printf '%s\t%s\t%s\n' "output-exact" "rc=$RC" "hello" >> "$WORK/checks.txt"
else
	echo "FAIL output-is-exactly-the-command's: got '$OUT'"
	FAILED=1
fi

# -v shows the boot log *and* still reports the command's status. It used to
# return 0 unconditionally, which is a launcher quietly changing what it ran.
if run "-v exit 7" && [ "$RC" = 7 ] && printf '%s' "$OUT" | grep -q "umarm-init:"; then
	echo "ok   verbose-exit-status (rc=$RC, boot log present)"
	printf '%s\t%s\n' "verbose" "rc=$RC" >> "$WORK/checks.txt"
else
	echo "FAIL verbose-exit-status: rc=$RC"
	printf '%s\n' "$OUT" | tail -20 | sed 's/^/     /'
	FAILED=1
fi

# --- the host share, both directions ---------------------------------------
# host -> guest: a file this side of the boundary, read inside.
printf 'hello-from-host\n' > "$DIST/share/from-host.txt"
expect "share-read"   0 "hello-from-host"    "cat /host/from-host.txt"

# guest -> host: the proof is on this side. A guest that claims it wrote
# something is not evidence; the file existing here is.
expect "share-write"  0 ""                   "echo written-by-guest > /host/from-guest.txt"
if [ "$(cat "$DIST/share/from-guest.txt" 2>/dev/null)" = "written-by-guest" ]; then
	echo "ok   share-write-visible-on-the-host"
else
	echo "FAIL share-write-visible-on-the-host: nothing (or the wrong bytes) in share/"
	FAILED=1
fi

# A command with shell metacharacters, which is the reason the command travels
# through the share and not the kernel command line -- a cmdline cannot carry
# quoting or spaces.
expect "quoting"      0 "a b"                "printf '%s %s\n' a b"

# --- the image is in use ----------------------------------------------------
# UML takes an fcntl(F_SETLK) write lock on the backing file, so the second
# instance gets "Failed to lock '<file>'" and then a root-mount panic with a
# stack trace, which reads like a corrupt filesystem. The launcher turns that
# into a sentence. The lock has to be the same *kind*: flock(2) does not
# conflict with fcntl locks, so `flock(1)` would make this check pass against a
# guest that booted perfectly.
python3 - "$DIST/debian.ext4" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "r+b")
fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
time.sleep(60)
PY
HOLDER=$!
sleep 1
expect "image-in-use" 1 "already running" "uname -m"
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true

# --- verdict ----------------------------------------------------------------
{
	echo "checks=$(wc -l < "$WORK/checks.txt")"
	echo "failed=$FAILED"
	echo "kernel_md5=$KERNEL_MD5"
	echo "image_md5=$IMAGE_MD5"
	echo "host=$(uname -srm)"
	# getconf is not on every host this runs on; python3 is, because the lock
	# check below already needs it.
	echo "page_size=$(getconf PAGESIZE 2>/dev/null ||
		python3 -c 'import os; print(os.sysconf("SC_PAGE_SIZE"))' 2>/dev/null ||
		echo unknown)"
} > "$WORK/result.txt"

cat "$WORK/result.txt"

if [ "$FAILED" != 0 ]; then
	log "verdict=FAIL"
	exit 1
fi

log "verdict=PASS"
echo "UMDEBIAN_E2E_OK checks=$(wc -l < "$WORK/checks.txt")"
