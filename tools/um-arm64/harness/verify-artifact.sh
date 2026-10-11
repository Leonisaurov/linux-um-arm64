#!/bin/bash
# Prove a downloaded um-arm64-android artifact on *this* device.
#
# CI cannot do this -- it has no phone. What it can do is record what it built,
# which is why every artifact carries linux-um.build.txt next to the binary, so
# the chain commit -> build.txt -> downloaded file -> booted kernel can be walked
# at the end that matters. That chain is the whole point: a kernel that boots and
# says the right commit is not the same claim as a kernel that boots.
#
#   ./verify-artifact.sh <artifact dir> <debian image> [passt] [umnet]
#
# <artifact dir> is what `gh run download -n um-arm64-android` gives you: RUN.md,
# and 16k/ and 4k/ each with linux-um, stub_exe, deb and linux-um.build.txt.
#
# Checks, in order, and each one names itself when it fails:
#
#   1. the kernel's md5 is the one build.txt recorded, and the stub is there;
#   2. it boots, and the guest reports the page size that build.txt claims;
#   3. the guest's uname contains the commit build.txt recorded -- provenance,
#      from the binary, on the device;
#   4. gcc in the guest builds a libm+pthreads program that computes correctly;
#   5. if passt/umnet are given, the guest gets an address and reaches the network.
#
# A page size below the host's is skipped with a reason rather than failed: a
# guest page is a host mmap(), so a 4 KB guest cannot boot on a 16 KB host, and
# that is a property of the pairing rather than a defect.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ART=${1:?usage: verify-artifact.sh <artifact dir> <debian image> [passt] [umnet]}
IMAGE=${2:?usage: verify-artifact.sh <artifact dir> <debian image> [passt] [umnet]}
PASST=${3:-}
UMNET=${4:-}
WORK=${WORK:-${TMPDIR:-/tmp}/umarm-verify}
MEM=${MEM:-512M}
TIMEOUT=${TIMEOUT:-240}

for f in "$ART/RUN.md" "$IMAGE"; do
    [ -f "$f" ] || { echo "verify-artifact.sh: no $f" >&2; exit 2; }
done

# getconf is not on every host this runs on -- Termux has no getconf, and Termux
# is where this script is most useful. python3 does, and can answer the same
# question.
host_page() {
    getconf PAGESIZE 2>/dev/null ||
        python3 -c 'import os; print(os.sysconf("SC_PAGE_SIZE"))' 2>/dev/null
}

HOST_PAGE=$(host_page)
case "$HOST_PAGE" in
'' | *[!0-9]*)
    echo "verify-artifact.sh: cannot determine the host page size" >&2
    exit 2
    ;;
esac

FAILED=0
CHECKS=0

ok()   { CHECKS=$((CHECKS + 1)); echo "ok   $*"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo "FAIL $*"; }
skip() { echo "skip $*"; }

# The guest's own program: libm identities that only agree if FP state survives,
# and four threads over a shared counter, which is where TLS and clone flags are
# exercised. Same shape as the CI gate, because it is the same question.
PROG='cat > /tmp/t.c <<"EOC"
#include <math.h>
#include <stdio.h>
#include <pthread.h>
static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static long c;
static void *w(void *a) { for (int i = 0; i < 10000; i++) { pthread_mutex_lock(&m); c++; pthread_mutex_unlock(&m); } return a; }
int main(void) {
	pthread_t t[4];
	double s = 0.0, s2 = 0.0;
	for (int i = 0; i < 4; i++) pthread_create(&t[i], 0, w, 0);
	for (int i = 0; i < 4; i++) pthread_join(t[i], 0);
	for (int i = 1; i <= 100000; i++) { s += sqrt((double)i); s2 += pow((double)i, 0.5); }
	printf("sqrt2*sqrt2=%.15f sqrt=%.3f pow=%.3f hilos=%ld\n", sqrt(2.0)*sqrt(2.0), s, s2, c);
	return (c == 40000 && fabs(sqrt(2.0)*sqrt(2.0) - 2.0) < 1e-12 && fabs(s - s2) < 1e-6) ? 0 : 1;
}
EOC
gcc -O2 -Wall -o /tmp/t /tmp/t.c -lm -lpthread && /tmp/t'

printf 'host page size %s, image %s\n' "$HOST_PAGE" "$(basename "$IMAGE")"

for dir in "$ART"/*/; do
    name=$(basename "$dir")
    btxt=$dir/linux-um.build.txt
    [ -f "$btxt" ] || continue

    echo
    echo "=== $name ==="

    want_md5=$(sed -n 's/^md5=//p' "$btxt")
    want_head=$(sed -n 's/^head=//p' "$btxt")
    want_page=$(sed -n 's/^page_size=//p' "$btxt")
    case "$want_page" in
    16k) guest_page=16384 ;;
    4k)  guest_page=4096 ;;
    *)   bad "$name: build.txt has page_size='$want_page'"; continue ;;
    esac

    if [ "$guest_page" -lt "$HOST_PAGE" ]; then
        skip "$name: a $guest_page guest page cannot boot on a $HOST_PAGE host"
        continue
    fi

    got_md5=$(md5sum "$dir/linux-um" | cut -d' ' -f1)
    if [ "$got_md5" = "$want_md5" ]; then
        ok "$name: md5 matches build.txt ($want_md5)"
    else
        bad "$name: md5 $got_md5, build.txt says $want_md5"
        continue
    fi
    [ -s "$dir/stub_exe" ] || { bad "$name: no stub_exe"; continue; }

    rm -rf "$WORK"
    mkdir -p "$WORK/share"
    cp "$dir/linux-um" "$WORK/linux-um"
    cp "$dir/stub_exe" "$WORK/stub_exe"
    cp "$dir/deb" "$WORK/deb"
    chmod 755 "$WORK/linux-um" "$WORK/stub_exe" "$WORK/deb"
    ln -sf "$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")" "$WORK/debian.ext4" 2>/dev/null ||
        cp "$IMAGE" "$WORK/debian.ext4"
    if [ -n "$PASST" ] && [ -n "$UMNET" ]; then
        ln -sf "$(cd "$(dirname "$PASST")" && pwd)/$(basename "$PASST")" "$WORK/passt" 2>/dev/null || cp "$PASST" "$WORK/passt"
        ln -sf "$(cd "$(dirname "$UMNET")" && pwd)/$(basename "$UMNET")" "$WORK/umnet" 2>/dev/null || cp "$UMNET" "$WORK/umnet"
    fi

    run_guest() { (cd "$WORK" && UMDEB_MEM=$MEM timeout "$TIMEOUT" ./deb "$1" 2>&1); }

    out=$(run_guest 'uname -r; getconf PAGESIZE')
    rc=$?
    if [ "$rc" != 0 ]; then
        bad "$name: the guest did not run (rc=$rc)"
        printf '%s\n' "$out" | tail -5 | sed 's/^/     /'
        continue
    fi
    got_page=$(printf '%s\n' "$out" | tail -1 | tr -d '\r')
    if [ "$got_page" = "$guest_page" ]; then
        ok "$name: the guest reports a $got_page byte page"
    else
        bad "$name: the guest reports $got_page, build.txt claims $guest_page"
    fi

    rel=$(printf '%s\n' "$out" | head -1 | tr -d '\r')
    case "$rel" in
    *"$want_head"*) ok "$name: uname says $rel, which contains $want_head" ;;
    *)              bad "$name: uname '$rel' does not contain head=$want_head" ;;
    esac

    out=$(run_guest "$PROG")
    rc=$?
    if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'hilos=40000'; then
        ok "$name: gcc built and the program computed ($(printf '%s' "$out" | tail -1 | tr -d '\r'))"
    else
        bad "$name: the FP/pthread program failed (rc=$rc)"
        printf '%s\n' "$out" | tail -6 | sed 's/^/     /'
    fi

    if [ -n "$PASST" ] && [ -n "$UMNET" ]; then
        out=$(run_guest 'ip -br addr show vec0; timeout 8 bash -c "exec 3<>/dev/tcp/1.1.1.1/80 && echo tcp-ok"')
        rc=$?
        if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'tcp-ok'; then
            ok "$name: networking works ($(printf '%s' "$out" | head -1 | tr -d '\r'))"
        else
            bad "$name: no network (rc=$rc)"
            printf '%s\n' "$out" | tail -5 | sed 's/^/     /'
        fi
    fi
done

echo
echo "checks=$CHECKS failed=$FAILED host_page=$HOST_PAGE"
if [ "$FAILED" != 0 ]; then
    echo "verdict=FAIL"
    exit 1
fi

echo "verdict=PASS"
echo "UMARTIFACT_OK checks=$CHECKS"
