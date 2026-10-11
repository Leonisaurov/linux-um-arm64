#!/bin/bash
# Build ARCH=um SUBARCH=arm64 on a native aarch64 host (CI runner or Termux).
#
# This is the CI counterpart of build.sh. build.sh assumed the documented
# build domain (x86_64, /root/mlu-arm64, a ccache shim under /usr/bin); none of
# that exists on a GitHub ubuntu-24.04-arm runner or on a phone. Everything
# here is derived from where this script actually is, or taken from the
# environment, so the same file works in both places.
#
# There is no cross-compilation to arrange: on an aarch64 host the compiler's
# default target already is the target, and upstream maps SUBARCH=arm64 to
# --target=aarch64-linux-gnu for ARCH=um anyway.
#
#   O=/tmp/umarm-build ART=/tmp/artifacts ./ci-build.sh [make-target]
#
# Outputs, next to each other under $ART:
#   linux-um-arm64   the UML kernel binary (aarch64 userspace process)
#   stub_exe         the freestanding stub, for hosts that refuse a memfd exec
#   kernel.config    the exact .config the binary was built from
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# <kernel>/tools/um-arm64/harness -> <kernel>
TREE=${TREE:-$(cd "$HERE/../../.." && pwd)}
O=${O:-${TMPDIR:-/tmp}/umarm-build}
ART=${ART:-$TREE/../artifacts}
JOBS=${JOBS:-$(nproc)}
TARGET=${1:-linux}

if [ ! -f "$TREE/Makefile" ] || [ ! -d "$TREE/arch/um" ]; then
    echo "ci-build.sh: no kernel tree at $TREE (set TREE=)" >&2
    exit 2
fi

mkdir -p "$O" "$ART"

# ccache is optional and must never turn a good build into a failed one.
# kbuild hardcodes CC=clang under LLVM=1, so intercept through PATH rather than
# by overriding CC (which would also disable kbuild's compiler capability
# probing). The shim lives under $O so it is per-build and never in $PATH twice.
if command -v ccache >/dev/null 2>&1; then
    SHIM=$O/.ccache-shim
    mkdir -p "$SHIM"
    REAL_CC=$(command -v clang)
    REAL_CXX=$(command -v clang++ || command -v clang)
    printf '#!/bin/sh\nexec ccache %s "$@"\n' "$REAL_CC"  > "$SHIM/clang"
    printf '#!/bin/sh\nexec ccache %s "$@"\n' "$REAL_CXX" > "$SHIM/clang++"
    chmod +x "$SHIM/clang" "$SHIM/clang++"
    export CCACHE_DIR=${CCACHE_DIR:-$O/.ccache}
    export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-5G}
    export CCACHE_COMPILERCHECK=content
    export PATH="$SHIM:$PATH"
    echo "ccache: $(ccache --version | head -1)"
fi

export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-"Thu Jan  1 00:00:00 UTC 1970"}
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-um}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-arm64}

MAKE=(make -C "$TREE" O="$O" ARCH=um SUBARCH=arm64 LLVM=1 -j"$JOBS")

echo "### host    $(uname -srm)"
echo "### clang   $(clang --version | head -1)"
echo "### ld.lld  $(ld.lld --version 2>/dev/null | head -1)"
echo "### tree    $TREE"
echo "### O       $O"
echo "### target  $TARGET"

# defconfig first so $O/.config exists and is the tree's arm64_defconfig.
if [ ! -f "$O/.config" ]; then
    echo "### defconfig"
    "${MAKE[@]}" defconfig || exit 1
fi

# EXTRA_CONFIG: space-separated config fragments, relative to the tree, merged
# into the defconfig before olddefconfig. The docker gate needs a kernel built
# with tools/um-arm64/config/docker.config, and a different config is a different
# build; merge_config.sh plus olddefconfig is the tree's own way of doing it.
if [ -n "${EXTRA_CONFIG:-}" ]; then
    for frag in $EXTRA_CONFIG; do
        [ -f "$TREE/$frag" ] || { echo "ci-build.sh: no config fragment $TREE/$frag" >&2; exit 2; }
    done
    echo "### merge $EXTRA_CONFIG"
    ( cd "$TREE" && scripts/kconfig/merge_config.sh -m -O "$O" "$O/.config" $EXTRA_CONFIG ) || exit 1
    "${MAKE[@]}" olddefconfig || exit 1
fi

# Name the artifact after the config so a run cannot be misread as the other
# kernel: the default and the docker build produce the same file name.
KERNEL_NAME=${KERNEL_NAME:-linux-um-arm64}

echo "### build"
"${MAKE[@]}" "$TARGET" || exit 1

[ -x "$O/linux" ] || { echo "ci-build.sh: no $O/linux after build" >&2; exit 1; }

install -m 0755 "$O/linux" "$ART/$KERNEL_NAME"
cp -f "$O/.config" "$ART/kernel.config"

# The stub is only produced as a side effect of linking the kernel. It is not
# needed when the host permits exec of a memfd, but Android's untrusted_app
# domain does not, and then stub_exe=<path> is the only way to boot.
STUB=$O/arch/um/kernel/skas/stub_exe
if [ -f "$STUB" ]; then
    install -m 0755 "$STUB" "$ART/stub_exe"
    echo "### stub    $ART/stub_exe ($(stat -c %s "$STUB") bytes)"
else
    echo "### stub    MISSING at $STUB" >&2
    exit 1
fi

# Host-side LD_PRELOAD shim for the noaslr gates: built against the host ABI
# because it is loaded into the UML process, not into the guest.
clang --target=aarch64-linux-gnu -shared -fPIC \
      -o "$ART/noaslr_preload.so" "$HERE/probe/noaslr_preload.c" || exit 1
echo "### preload $ART/noaslr_preload.so ($(stat -c %s "$ART/noaslr_preload.so") bytes)"

{
    echo "head=$(git -C "$TREE" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "clang=$(clang --version | head -1)"
    echo "extra_config=${EXTRA_CONFIG:-none}"
    echo "size_linux=$(stat -c %s "$ART/$KERNEL_NAME")"
    echo "sha256_linux=$(sha256sum "$ART/$KERNEL_NAME" | cut -d' ' -f1)"
    echo "size_stub=$(stat -c %s "$ART/stub_exe")"
    echo "sha256_stub=$(sha256sum "$ART/stub_exe" | cut -d' ' -f1)"
    echo "sha256_preload=$(sha256sum "$ART/noaslr_preload.so" | cut -d' ' -f1)"
    echo "built_utc=$(date -u +%Y%m%dT%H%M%SZ)"
} > "$ART/build.txt"

echo "### done"
cat "$ART/build.txt"
