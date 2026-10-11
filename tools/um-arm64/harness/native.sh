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
PRELOAD=${PRELOAD:-}
PRELOAD_MARKER=${PRELOAD_MARKER:-}
# EXPECT_BUG is set only by a negative control. It still needs a default: the
# script runs under set -u, so `[ -n "$EXPECT_BUG" ]` is itself an unbound
# variable error when the caller did not set it -- which is every ordinary gate.
# The local test that missed this passed EXPECT_BUG="" for the ordinary cases,
# and defined-but-empty is not the same thing as unset.
EXPECT_BUG=${EXPECT_BUG:-}
# REQUIRE is a space-separated list of strings that must appear in the log, for
# markers a guest cannot check for itself. fptorture is the case that made it
# necessary: it opens /dev/console and writes there through a descriptor of its
# own, so no redirection inside the guest captures it, and the boot log -- this
# side of the boundary -- is the only place that output exists.
REQUIRE=${REQUIRE:-}
# HOSTFS is a directory on this machine that the guest will mount through UML's
# hostfs. The path travels in the kernel command line, not inside the guest
# image: an image that carries its own host path stops working the moment it
# moves to another machine, which is exactly what happened to gate 5 in the
# original repository.
HOSTFS=${HOSTFS:-}
HOSTFS_CHECK=${HOSTFS_CHECK:-}
HOSTFS_VALUE=${HOSTFS_VALUE:-}
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
# PRELOAD is an LD_PRELOAD shim for the *host* process -- noaslr_preload.so
# makes personality(ADDR_NO_RANDOMIZE) fail, which is what an Android host does.
if [ -n "$PRELOAD" ]; then
    [ -f "$PRELOAD" ] || { echo "native.sh: no preload library at $PRELOAD" >&2; exit 2; }
fi

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
[ -n "$PRELOAD" ] && cp -f "$PRELOAD" "$OUT/preload.so"
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
if [ -n "$HOSTFS" ]; then
    mkdir -p "$HOSTFS"
    [ -d "$HOSTFS" ] || { echo "native.sh: HOSTFS=$HOSTFS is not a directory" >&2; exit 2; }
    # hostfs= both sets the default root and *confines* every hostfs mount to
    # that tree, which is what makes it safe to hand the guest a directory.
    CMDLINE="hostfs=$HOSTFS $CMDLINE"
    # The share is a declared input, not whatever the last run left behind: a
    # gate that silently reads nothing is worse than one that fails. The
    # previous run's output is removed so the host-side check can only be
    # satisfied by this run.
    printf 'hello-from-host\n' > "$HOSTFS/from-host.txt"
    rm -f "$HOSTFS/from-guest.txt"
fi
printf '%s\n' "$CMDLINE" > "$OUT/cmdline"

log "gate=$GATE timeout=${TIMEOUT}s marker='$MARKER'"
log "cmdline: $CMDLINE"

# setsid + a process-group kill keeps the stub children from outliving a
# timeout; the exit status of timeout is preserved separately from the pipeline.
PRELOAD_ENV=()
[ -n "$PRELOAD" ] && PRELOAD_ENV=(env "LD_PRELOAD=$PRELOAD")

if command -v setsid >/dev/null 2>&1; then
    setsid "${PRELOAD_ENV[@]}" timeout --signal=KILL --kill-after=10 "$TIMEOUT" \
        "$BIN" $CMDLINE > "$OUT/boot.log" 2>&1 </dev/null
else
    "${PRELOAD_ENV[@]}" timeout --signal=KILL --kill-after=10 "$TIMEOUT" \
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

# hostfs is a bridge to *this* filesystem, so the only proof it worked is on this
# side of it: the guest's write has to be readable here, as a file the guest
# could not have created any other way.
HOSTFS_MISSING=0
if [ -n "$HOSTFS_CHECK" ]; then
    if [ ! -s "$HOSTFS/$HOSTFS_CHECK" ]; then
        HOSTFS_MISSING=1
    elif [ -n "$HOSTFS_VALUE" ] && \
         [ "$(cat "$HOSTFS/$HOSTFS_CHECK")" != "$HOSTFS_VALUE" ]; then
        HOSTFS_MISSING=2
    fi
fi

# A gate configured with a preload is only testing what it claims if the
# library actually loaded. A wrong path, a wrong ABI or a refused load all fail
# silently, and the gate would pass while exercising an ordinary host, so the
# shim's own constructor line is required when PRELOAD_MARKER names it. This is
# checked before the marker: an invalid run must not be able to pass at all.
PRELOAD_MISSING=0
if [ -n "$PRELOAD" ] && [ -n "$PRELOAD_MARKER" ]; then
    grep -qF "$PRELOAD_MARKER" "$OUT/boot.log" 2>/dev/null || PRELOAD_MISSING=1
fi

# A run configured with EXPECT_BUG is a negative control: the same workload on a
# kernel deliberately built with the defect, where the defect appearing is the
# expected result. It exists because "the bug is gone" and "the workload never
# reached the code" look identical from here, and only a control separates them.
# So a control that does *not* reproduce fails, loudly, as a failure of the
# control -- passing quietly would be the one outcome that teaches nothing.
EXPECT_HITS=0
if [ -n "$EXPECT_BUG" ]; then
    # Counted only when a control is configured: grep -F with an empty pattern
    # matches every line, so an unguarded count would report the log's length as
    # hits on every ordinary gate.
    EXPECT_HITS=$(grep -acF "$EXPECT_BUG" "$OUT/boot.log" 2>/dev/null || true)
    EXPECT_HITS=${EXPECT_HITS:-0}
fi
EXPECT_MISSING=0
if [ -n "$EXPECT_BUG" ] && [ "$EXPECT_HITS" = 0 ]; then
    EXPECT_MISSING=1
fi

# Checked before the marker, like the others: a run that did not do what it
# claims must not be able to pass at all.
REQUIRE_MISSING=""
for want in $REQUIRE; do
    grep -qF "$want" "$OUT/boot.log" 2>/dev/null || REQUIRE_MISSING="$REQUIRE_MISSING $want"
done

# --- verdict ----------------------------------------------------------------
if [ "$PRELOAD_MISSING" = 1 ]; then
    VERDICT=PRELOAD_FAIL
elif [ "$HOSTFS_MISSING" != 0 ]; then
    VERDICT=HOSTFS_FAIL
elif [ -n "$REQUIRE_MISSING" ]; then
    VERDICT=REQUIRE_FAIL
elif [ "$EXPECT_MISSING" = 1 ]; then
    VERDICT=CONTROL_FAIL
elif grep -qF "$MARKER" "$OUT/boot.log" 2>/dev/null; then
    # On a control the diagnostic *is* the expectation, so it does not make the
    # verdict BUG; expect_bug_hits in result.txt is the evidence that it fired.
    if [ -n "$EXPECT_BUG" ] || [ "$KBUGS" -eq 0 ]; then VERDICT=PASS; else VERDICT=BUG; fi
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
    echo "preload=${PRELOAD:-none}"
    echo "preload_marker=${PRELOAD_MARKER:-none}"
    echo "preload_missing=$PRELOAD_MISSING"
    echo "hostfs=${HOSTFS:-none}"
    echo "hostfs_check=${HOSTFS_CHECK:-none}"
    echo "hostfs_missing=$HOSTFS_MISSING"
    echo "expect_bug=${EXPECT_BUG:-none}"
    echo "expect_bug_hits=$EXPECT_HITS"
    echo "require=${REQUIRE:-none}"
    echo "require_missing=${REQUIRE_MISSING:-none}"
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
