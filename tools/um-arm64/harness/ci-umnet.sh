#!/bin/bash
# Gate the networking helpers. The kernel gates cannot reach them.
#
# umnet sits between UML's vector `fd` transport and passt: a datagram socketpair
# towards the kernel, a stream socketpair towards passt, and a pump that reframes
# between the two. CI gives the guest no network, so nothing in the boot matrix
# runs any of this -- and the bug this gate exists for was invisible there for a
# second reason as well: it is not about the packets.
#
# The bug. The UML side of the pump is a SOCK_DGRAM socketpair, and closing the
# peer of a datagram socketpair produces no POLLHUP and no EOF. When the guest
# halted, UML exited, and umnet stayed in poll() forever with the kernel as an
# unreaped zombie. Measured on a phone: the shipped launcher printed the
# command's answer and never returned, so a run that had finished looked exactly
# like one that had hung. The fix is a SIGCHLD self-pipe in the pump's poll set.
#
# None of this needs a kernel, passt, or root. What it needs is a "passt" that
# starts, accepts umnet's argument list and stays alive -- probe/fake-passt.c.
# With the bug present, the runs below never return, so the timeouts are the
# assertion and the elapsed time is the evidence.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$PWD/umnet-ci}
CC=${CC:-cc}

rm -rf "$WORK"
mkdir -p "$WORK"

log() { echo "[umnet] $*"; }

"$CC" -O2 -Wall -Wextra -o "$WORK/umnet" "$HERE/umnet.c"
"$CC" -O2 -Wall -Wextra -o "$WORK/fake-passt" "$HERE/probe/fake-passt.c"
log "built with $("$CC" --version | head -1)"

FAILED=0
: > "$WORK/checks.txt"

# run <label> <expected-rc> <expected-stderr-substring> <passt> <command...>
# The elapsed time is bounded by timeout(1): a hang is a failure, not a wait.
run() {
	local label=$1 want_rc=$2 want_err=$3 passt=$4
	shift 4

	local t0 t1 rc out
	t0=$(date +%s)
	set +e
	out=$(cd "$WORK" && timeout 20 ./umnet --passt "$passt" -- "$@" 2>&1)
	rc=$?
	set -e
	t1=$(date +%s)

	if [ "$rc" = "$want_rc" ] && { [ -z "$want_err" ] || printf '%s' "$out" | grep -qF -- "$want_err"; }; then
		echo "ok   $label (rc=$rc, $((t1 - t0))s)"
		printf '%s\trc=%s\t%ss\n' "$label" "$rc" "$((t1 - t0))" >> "$WORK/checks.txt"
		return 0
	fi

	echo "FAIL $label: rc=$rc (wanted $want_rc) after $((t1 - t0))s (124 = it hung)"
	printf '%s\n' "$out" | tail -5 | sed 's/^/     /'
	FAILED=1
	return 0
}

# The regression itself: "passt" alive, kernel exits, umnet must notice. Before
# the fix this hung until the timeout; --passt is the real helper's protocol, so
# the fake one is what makes the *exit notification* the only variable.
run "kernel-exits"   0 ""    ./fake-passt sh -c 'sleep 2'

# The other half of the same code path, and the reason the file's comments care:
# the kernel's exit status has to reach the caller. It was WNOHANG with a
# discarded status once, which reported every failure as success.
run "kernel-status"  7 "kernel exited 7" ./fake-passt sh -c 'exit 7'

# A passt that cannot start must fail loudly, not silently leave a guest with no
# network. This path did work before the fix, which is what makes it worth
# keeping: it is the control. The status reported is the kernel's -- 3 here --
# with passt's own 127 alongside it.
run "passt-missing"  3 "exec passt" ./no-such-passt sh -c 'exit 3'

{
	echo "checks=$(wc -l < "$WORK/checks.txt")"
	echo "failed=$FAILED"
	echo "cc=$("$CC" --version | head -1)"
	echo "host=$(uname -srm)"
} > "$WORK/result.txt"

cat "$WORK/result.txt"

if [ "$FAILED" != 0 ]; then
	log "verdict=FAIL"
	exit 1
fi

log "verdict=PASS"
echo "UMNET_OK checks=$(wc -l < "$WORK/checks.txt")"
