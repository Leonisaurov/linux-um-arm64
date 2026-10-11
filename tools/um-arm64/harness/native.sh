#!/bin/bash
# Native run domain: boot ./linux as an ordinary aarch64 process on this host.
#
# This is the counterpart of boot.sh for hosts that are already aarch64 -- a
# GitHub `ubuntu-24.04-arm` runner, a phone under Termux. boot.sh drives a
# qemu-system-aarch64 VM over ssh because the documented build host was x86_64;
# where no emulation is needed there is no VM to drive, and running the binary
# directly is both faster and a truer test (a real arm64 kernel on real arm64
# hardware, not TCG).
#
# The verdict logic is deliberately the same as boot.sh, because that logic is
# the part that cost real incidents to get right:
#   * success is a marker string in the log, never an exit code;
#   * a separate, independent scan for BUG:/WARNING: -- a run that reaches its
#     marker while the kernel reports a defect has not passed;
#   * on a fatal signal, a real backtrace instead of "it does not boot".
#
#   BIN=./linux MARKER=UMARM_GUEST_OK INIT=/init INITRD=initramfs.cpio.gz \
#       GATE=g2 ./native.sh
#
# Extra options added by the arm64 port are passed through EXTRA_ARGS, e.g.
# EXTRA_ARGS="seccomp=on nosysemu". STUB_EXE=<path> forwards stub_exe=<path>,
# which Android's untrusted_app domain needs because it refuses execveat on a
# memfd (confirmed on-device; see doc/70-android.md).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:-$(cd "$HERE/../../.." && pwd)}
ART=${ART:-$ROOT/artifacts}
GATE=${GATE:-gate}
BIN=${BIN:-$ROOT/linux}
TIMEOUT=${TIMEOUT:-300}
MARKER=${MARKER:-UMARM_BOOT_OK}
MEM=${MEM:-512M}
EXTRA_ARGS=${EXTRA_ARGS:-}
INITRD=${INITRD:-}
UBD0=${UBD0:-}
INIT=${INIT:-/bin/sh}
STUB_EXE=${STUB_EXE:-}
CON=${CON:-null}
CON0=${CON0:-null,fd:1}

log() { printf '[native] %s\n' "$*"; }

[ -f "$BIN" ] || { echo "native.sh: no kernel at BIN=$BIN" >&2; exit 2; }
# GitHub Actions artifacts do not carry the executable bit back out of the zip,
# so a kernel that was 0755 when uploaded arrives 0644. Fix it here rather than
# in each caller, and only if the file is actually there.
[ -x "$BIN" ] || chmod +x "$BIN"          2>/dev/null || true
[ -x "$BIN" ] || { echo "native.sh: $BIN is not executable" >&2; exit 2; }
[ -z "$STUB_EXE" ] || chmod +x "$STUB_EXE" 2>/dev/null || true

# One run at a time. A UML that outlived its timeout still holds locks on its
# ubd image; a second run would then fail for reasons that have nothing to do
# with the kernel under test. flock is not present on every Termux install, so
# the lock is taken when it can be and skipped when it cannot.
if command -v flock >/dev/null 2>&1; then
    exec 9>"${TMPDIR:-/tmp}/umarm-native.lock"
    if ! flock -w "${LOCK_WAIT:-3600}" 9; then
        echo "native.sh: another native run holds the run domain" >&2
        exit 2
    fi
fi

command -v timeout >/dev/null 2>&1 || {
    echo "native.sh: timeout(1) is required (coreutils)" >&2
    exit 2
}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$ART/$GATE/$STAMP"
mkdir -p "$OUT"

cp -f "$BIN" "$OUT/linux"
[ -n "$STUB_EXE" ] && cp -f "$STUB_EXE" "$OUT/stub_exe"
if [ -x "$HERE/env-check.sh" ]; then
    bash "$HERE/env-check.sh" > "$OUT/env.txt" 2>&1 || true
fi

# con0=null,fd:1 and not fd:0,fd:1: UML registers its console descriptors with
# epoll, and epoll_ctl on a regular file fails with EPERM. In CI both stdin and
# stdout are files, after which the console simply stops and the boot looks like
# it died. `null,fd:1` is the documented option for a non-pollable stdin.
CMDLINE="mem=$MEM panic=-1 init=$INIT con=$CON con0=$CON0 $EXTRA_ARGS"
[ -n "$STUB_EXE" ] && CMDLINE="stub_exe=$STUB_EXE $CMDLINE"
[ -n "$INITRD" ] && CMDLINE="initrd=$INITRD $CMDLINE"
[ -n "$UBD0" ] && CMDLINE="ubd0=$UBD0 root=/dev/ubda $CMDLINE"
printf '%s\n' "$CMDLINE" > "$OUT/cmdline"

log "gate=$GATE timeout=${TIMEOUT}s marker='$MARKER'"
log "cmdline: $CMDLINE"

# setsid + a process-group kill keeps the stub children from outliving a
# timeout; the exit status of timeout is preserved separately from the pipeline.
if command -v setsid >/dev/null 2>&1; then
    setsid timeout --signal=KILL --kill-after=10 "$TIMEOUT" \
        "$BIN" $CMDLINE > "$OUT/boot.log" 2>&1 </dev/null
else
    timeout --signal=KILL --kill-after=10 "$TIMEOUT" \
        "$BIN" $CMDLINE > "$OUT/boot.log" 2>&1 </dev/null
fi
RC=$?
echo "RC=$RC" >> "$OUT/boot.log"

# --- kernel diagnostics, scanned independently of the marker ----------------
# Deliberately not matching "Kernel panic": gates whose init exits end in
# "Attempted to kill init!" and panic under panic=-1 *after* the marker, which
# is an expected end state. The signatures below are ones the kernel only emits
# when something is actually wrong.
grep -aE '^(BUG:|WARNING:|Oops|INFO: rcu|INFO: task .* blocked|Unable to handle kernel|kernel BUG at)' \
     "$OUT/boot.log" 2>/dev/null | tr -d '\r' | sort | uniq -c | sort -rn > "$OUT/kernel-bugs.txt"
KBUGS=$(awk '{n += $1} END {print n+0}' "$OUT/kernel-bugs.txt")

# A gate's own init reporting a failed check is the most specific diagnosis
# available, and it is a guest-level verdict: the kernel booted, the root
# filesystem mounted, and then the fixture decided the port was wrong. Without
# this the run shows up as SIGNAL (init exiting is a panic under panic=-1) and
# the actual reason is only in the log.
GUESTFAIL=$(grep -acE '^GATE[A-Z0-9_]*_FAIL' "$OUT/boot.log" 2>/dev/null || true)
GUESTFAIL=${GUESTFAIL:-0}

# --- verdict ----------------------------------------------------------------
if grep -qF "$MARKER" "$OUT/boot.log" 2>/dev/null; then
    if [ "$KBUGS" -gt 0 ]; then VERDICT=BUG; else VERDICT=PASS; fi
elif [ "$GUESTFAIL" -gt 0 ]; then
    VERDICT=GUEST_FAIL
elif [ "$RC" = "137" ] || [ "$RC" = "124" ]; then
    VERDICT=HANG
elif grep -qE "Kernel panic|BUG:|Oops" "$OUT/boot.log" 2>/dev/null; then
    VERDICT=PANIC
else
    VERDICT=FAIL
fi

# --- on a fatal signal, get a real backtrace --------------------------------
# 132=SIGILL 133=SIGTRAP 134=SIGABRT 135=SIGBUS 136=SIGFPE 139=SIGSEGV
case "$RC" in
132|133|134|135|136|139)
    case "$VERDICT" in PASS|BUG) ;; *) VERDICT=SIGNAL ;; esac
    if command -v gdb >/dev/null 2>&1; then
        log "fatal signal (rc=$RC), capturing backtrace"
        timeout 90 gdb -batch -nx \
            -ex 'set pagination off' \
            -ex 'set follow-fork-mode parent' \
            -ex "run $CMDLINE" \
            -ex 'thread apply all bt full' \
            -ex 'info registers' \
            --args "$BIN" $CMDLINE > "$OUT/backtrace.txt" 2>&1
    fi
    ;;
esac

# --- summary ----------------------------------------------------------------
{
    echo "gate=$GATE"
    echo "stamp=$STAMP"
    echo "verdict=$VERDICT"
    echo "rc=$RC"
    echo "marker=$MARKER"
    echo "cmdline=$CMDLINE"
    echo "boot_log_lines=$(wc -l < "$OUT/boot.log" 2>/dev/null || echo 0)"
    echo "kernel_bugs=$KBUGS"
    echo "guest_fail=$GUESTFAIL"
    echo "bin_md5=$(md5sum "$OUT/linux" 2>/dev/null | cut -d' ' -f1)"
    echo "host=$(uname -srm)"
} > "$OUT/result.txt"

if [ "$KBUGS" -gt 0 ]; then
    log "kernel reported $KBUGS diagnostic line(s):"
    sed 's/^/[native]   /' "$OUT/kernel-bugs.txt"
fi

ln -sfn "$OUT" "$ART/$GATE-latest"
log "verdict=$VERDICT rc=$RC -> $OUT"
cat "$OUT/result.txt"

# A grep-able one-liner for CI logs, independent of the artifact upload.
echo "UMARM_VERDICT=$VERDICT gate=$GATE bin_md5=$(sed -n 's/^bin_md5=//p' "$OUT/result.txt")"

[ "$VERDICT" = PASS ]
