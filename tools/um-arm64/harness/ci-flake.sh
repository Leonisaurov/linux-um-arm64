#!/bin/bash
# Run the gate matrix repeatedly and tally it, in CI.
#
# The point is flakiness, not coverage: a port that passes each gate once has not
# been shown to work, it has been shown not to fail on the first try. The port's
# own harness/loop.sh does this, deliberately serially, because the run domain is
# one machine and running gates concurrently creates timeouts that look exactly
# like the flakes being hunted. This is that loop with two differences.
#
# The first is the perturbation. Loading a module changes vmalloc usage and the
# guest's address-space layout, which is where the stub pages live, so the matrix
# here runs against the kernel built with config/modules.config and includes
# flake-init, which loads a module and *then* does the fork/exec, the FP torture,
# the file mapping and the hostfs write in the same boot. A module loaded in one
# UML process says nothing about the next one, so the perturbation has to be
# inside a boot for the loop to mean anything.
#
# The second is the criterion. loop.sh's verdict is the marker string, and the
# marker is exactly the criterion that missed the rss leak: a run that printed its
# marker was never scanned. native.sh already scans for kernel diagnostics
# independently of the marker and reports verdict=BUG, so a run with a defect in
# its log cannot pass here even with its marker present.
#
#   ART=<artifact dir> KERNEL=<dir> N=200 bash ci-flake.sh
#
# ART holds the fixtures (alpine.ext4, debian.ext4, initramfs.cpiogz) and the
# kernels and .ko live under KERNEL. Exits non-zero if any iteration did not pass.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ART=${ART:?set ART to the directory holding the disk images and the initramfs}
KERNEL=${KERNEL:?set KERNEL to the directory holding linux-um-arm64 and the modules/}
N=${N:-200}
OUT=${OUT:-$PWD/flake-$(date -u +%Y%m%dT%H%M%SZ)}
HOSTFS=${HOSTFS:-$OUT/hostshare}

mkdir -p "$OUT" "$HOSTFS"
TSV="$OUT/results.tsv"
printf 'iter\tgate\tverdict\trc\tseconds\tartifact\n' > "$TSV"

# name | init | ubd0 | initrd | mem | hostfs | every | timeout
#
# "every" samples the expensive rows. g4 spawns 2000 processes and fp runs ~8500
# verify iterations; running both on every pass would put the loop past a day,
# which means it would not actually be run. The cheap rows -- which is where boot
# and teardown flakes live -- run every time, and flake-init runs every time
# because it is the perturbation and a sampled perturbation is not one.
MATRIX=(
"g2mini|/init||initramfs.cpiogz|512M||1|180"
"g3|/gate3-init|alpine.ext4||512M||1|300"
"flake|/flake-init|alpine.ext4||512M|yes|1|300"
"g4|/gate4-init|alpine.ext4||512M||5|900"
"fp|/fp-init|alpine.ext4||512M||5|900"
"rss|/rss-init|debian.ext4||512M||5|900"
)

BIN="$KERNEL/linux-um-arm64"
[ -f "$BIN" ] || { echo "ci-flake.sh: no kernel at $BIN" >&2; exit 2; }
[ -f "$KERNEL/modules/binfmt_misc.ko" ] || {
    echo "ci-flake.sh: no modules under $KERNEL/modules -- this loop is about a" >&2
    echo "             kernel that has loaded one, so an empty set is a setup error" >&2
    exit 2
}

echo "flake loop: N=$N out=$OUT"
echo "  kernel  $BIN ($(md5sum "$BIN" | cut -c1-8))"
echo "  modules $(ls "$KERNEL/modules" | tr '\n' ' ')"
echo "  fixtures $(ls "$ART" | tr '\n' ' ')"

declare -A pass fail runs
declare -A firstfail
start=$SECONDS
for i in $(seq 1 "$N"); do
    for row in "${MATRIX[@]}"; do
        IFS='|' read -r name init ubd0 initrd mem hf every tmo <<< "$row"
        [ $(( i % ${every:-1} )) -eq 0 ] || continue
        t0=$SECONDS

        env_args=(
            GATE="flake-$name-$i"
            BIN="$BIN"
            ART="$OUT/run"
            TIMEOUT="$tmo"
            MARKER="UMARM_BOOT_OK"
            INIT="$init"
            MEM="$mem"
            EXTRA_ARGS="rw"
        )
        [ -z "$ubd0" ] || env_args+=(UBD0="$ART/$ubd0")
        [ -z "$initrd" ] || env_args+=(INITRD="$ART/$initrd")
        if [ -n "$hf" ]; then
            env_args+=(HOSTFS="$HOSTFS")
            # The module gates load the .ko from the share, so it goes in before
            # every iteration: the previous one's copy is not assumed to survive.
            cp "$KERNEL/modules/"*.ko "$HOSTFS/" 2>/dev/null || true
            rm -f "$HOSTFS/from-guest-flake.txt"
        fi

        env "${env_args[@]}" bash "$HERE/native.sh" >/dev/null 2>&1
        rc=$?
        secs=$((SECONDS - t0))

        latest="$OUT/run/flake-$name-$i-latest"
        verdict=$(sed -n 's/^verdict=//p' "$latest/result.txt" 2>/dev/null)
        verdict=${verdict:-NOVERDICT}

        runs[$name]=$(( ${runs[$name]:-0} + 1 ))
        if [ "$verdict" = PASS ]; then
            pass[$name]=$(( ${pass[$name]:-0} + 1 ))
        else
            fail[$name]=$(( ${fail[$name]:-0} + 1 ))
            [ -n "${firstfail[$name]:-}" ] || firstfail[$name]="$latest"
            echo "FAIL iter=$i gate=$name verdict=$verdict rc=$rc -> $latest"
            # The kernel diagnostics are the whole point of a failure here, so
            # they go to the job log rather than only into the artifact.
            sed 's/^/    /' "$latest/kernel-bugs.txt" 2>/dev/null | head -5
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$name" "$verdict" "$rc" "$secs" "$latest" >> "$TSV"
    done
    [ $(( i % 20 )) -eq 0 ] && echo "  ... $i/$N iterations, $((SECONDS - start))s"
done

total=0
failed=0
{
    echo
    echo "gate        runs  pass  fail  first failure"
    for row in "${MATRIX[@]}"; do
        IFS='|' read -r name _ <<< "$row"
        r=${runs[$name]:-0}
        p=${pass[$name]:-0}
        f=${fail[$name]:-0}
        total=$((total + r))
        failed=$((failed + f))
        printf '%-11s %5s %5s %5s  %s\n' "$name" "$r" "$p" "$f" "${firstfail[$name]:-}"
    done
    echo
    echo "runs=$total pass=$((total - failed)) fail=$failed seconds=$((SECONDS - start))"
    echo "results.tsv is in $OUT"
}

echo "runs=$total failed=$failed"
[ "$failed" = 0 ] && echo "verdict=PASS" || echo "verdict=FAIL"
[ "$failed" = 0 ] && echo "UMARM_FLAKE_OK runs=$total"
[ "$failed" = 0 ]
