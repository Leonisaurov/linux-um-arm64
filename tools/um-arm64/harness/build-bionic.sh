#!/bin/bash
# Build UML/arm64 against bionic, for running inside an Android app.
#
# harness/build-android.sh already produces a binary that runs on the phone: a
# statically linked glibc one. That is enough for `adb shell`, and it is not
# enough for an app. An app process is started by zygote with a seccomp filter
# already installed, and glibc's startup issues calls that filter kills --
# rseq(2) and set_robust_list(2) -- so a glibc binary dies before main() with no
# output at all. bionic is the libc that filter was written for.
#
# The kernel notices bionic by itself: arch/arm64/Makefile.um asks the compiler
# whether __ANDROID__ is defined and adjusts from there. So the only thing this
# script does differently from build-android.sh is aim the compiler at Android,
# which it does by shimming --target on after kbuild's own -- clang takes the
# last one. Overriding CC instead would turn off kbuild's compiler probing.
#
# Every path below is derived from where this script actually is, or taken from
# the environment. It used to hardcode one particular home directory, which
# told anyone else reading it very little:
#
#   TREE=${TREE:-/root/mlu-arm64/linux}
#
# Nothing here wants to be root and nothing wants a specific location. Clone
# anywhere, run it from there.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# The harness lives at <repo>/harness in this tree and at
# <linux>/tools/um-arm64/harness when imported into a kernel tree; the kernel
# source is the parent of whichever one this is.
if [ -f "$HERE/../linux/Makefile" ]; then
    TREE=${TREE:-$(cd "$HERE/.." && pwd)/linux}      # <repo>/harness
elif [ -f "$HERE/../../../Makefile" ]; then
    TREE=${TREE:-$(cd "$HERE/../../.." && pwd)}      # <linux>/tools/um-arm64/harness
else
    TREE=${TREE:-$(cd "$HERE/.." && pwd)}
fi
if [ ! -f "$TREE/Makefile" ]; then
    echo "build-bionic.sh: no kernel tree at $TREE (set TREE=)" >&2
    exit 2
fi

ART=${ART:-$TREE/../artifacts}
API=${API:-30}   # oldest bionic declaring all UML uses: statx(30), getrandom(28)
JOBS=${JOBS:-$(nproc)}
O=${O:-${TMPDIR:-/tmp}/umarm-build-bionic}
# Names in $ART, because two callers want different ones: the Android app's
# build-apk.sh wants linux-bionic/stub_exe_bionic, and the shipped launcher wants
# a kernel called linux-um next to a stub called stub_exe.
NAME=${NAME:-linux-bionic}
STUBNAME=${STUBNAME:-stub_exe_bionic}
# 16k by default, which is what arch/um/configs/arm64_defconfig ships and the only
# setting that runs on both 4 KB and 16 KB hosts: a guest page is a host mmap(),
# so a 4 KB guest cannot boot on a 16 KB host at all. 4k exists for
# memory-constrained builds that know their host.
PAGESIZE=${PAGESIZE:-16k}

# The NDK ships one prebuilt toolchain per *host* architecture, and the stock
# download carries linux-x86_64 only. An aarch64 host therefore needs an NDK
# re-packed for it -- which is what building this on the phone requires -- so look
# for the one that matches this machine rather than the one that happens to be
# listed first. A repacked NDK can carry both, and picking x86_64 on an aarch64
# host gives a compiler that cannot run at all.
prebuilt_for_host() {
    local prefer other d

    case "$(uname -m)" in
    aarch64 | arm64) prefer=linux-aarch64 ;;
    x86_64 | amd64)  prefer=linux-x86_64 ;;
    *)               prefer= ;;
    esac
    [ "$prefer" = linux-aarch64 ] && other=linux-x86_64 || other=linux-aarch64

    for d in $prefer $other; do
        [ -x "$1/toolchains/llvm/prebuilt/$d/bin/clang" ] && { echo "$d"; return 0; }
    done
    return 1
}

# Find the NDK rather than insisting on one path. $NDK and the two variables
# Google's own tooling sets are checked first, then the usual install
# locations, newest last so the newest wins.
if [ -z "${NDK:-}" ]; then
    for c in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" \
             "$HOME"/Android/Sdk/ndk/* "$HOME"/Library/Android/sdk/ndk/* \
             /usr/lib/android-ndk /opt/android-ndk* \
             "${TMPDIR:-/tmp}"/ndk/android-ndk-*; do
        [ -n "$c" ] && prebuilt_for_host "$c" >/dev/null && NDK=$c
    done
fi
HOSTPRE=$(prebuilt_for_host "${NDK:-/nonexistent}") || {
    echo "build-bionic.sh: no Android NDK found for this host." >&2
    echo "  Set NDK=/path/to/android-ndk-rXX. Looked at \$NDK, \$ANDROID_NDK_HOME," >&2
    echo "  \$ANDROID_NDK_ROOT, ~/Android/Sdk/ndk/*, /opt/android-ndk*," >&2
    echo "  ${TMPDIR:-/tmp}/ndk/*. The stock NDK carries linux-x86_64 only; an" >&2
    echo "  aarch64 host needs one with toolchains/llvm/prebuilt/linux-aarch64." >&2
    exit 2
}
TOOL=$NDK/toolchains/llvm/prebuilt/$HOSTPRE/bin

# A stock NDK on an aarch64 host is the case that wastes the most time, because
# it fails later as "cannot execute binary file" from a shim nobody is looking at.
# Refuse it here while the reason is still visible.
case "$(uname -m)" in
aarch64 | arm64)
    if [ "$HOSTPRE" = linux-x86_64 ]; then
        echo "build-bionic.sh: $NDK has no linux-aarch64 prebuilt, so its clang" >&2
        echo "  cannot run on this host. Unpack an NDK repacked for linux-aarch64" >&2
        echo "  (the stock zip carries linux-x86_64 only), or build on an x86_64" >&2
        echo "  machine -- which is what CI does." >&2
        exit 2
    fi
    ;;
esac

export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-"Thu Jan  1 00:00:00 UTC 1970"}
export KBUILD_BUILD_USER=um
export KBUILD_BUILD_HOST=arm64

# fixdep and friends run on the build machine, so they must not be built with the
# shim -- name the real compiler for them explicitly. Resolved *before* the shim
# joins PATH, because otherwise `command -v clang` finds the shim itself, whose
# whole job is to append --target=aarch64-linux-android: every host tool would be
# built for Android and the build would fail in a way that names none of this.
#
# Discovered rather than hardcoded to /usr/bin/clang because that path does not
# exist on Termux, where the host compiler is $PREFIX/bin/clang.
HOST_CC=$(command -v clang || true)
HOST_CXX=$(command -v clang++ || true)
[ -n "$HOST_CC" ] || { echo "build-bionic.sh: no host clang in PATH" >&2; exit 2; }
HOST_ARGS=(HOSTCC="$HOST_CC" HOSTCXX="${HOST_CXX:-$HOST_CC}")

SHIM=${SHIM:-$O/.bionic-shim}
mkdir -p "$SHIM"
# Same ccache arrangement as ci-build.sh: kbuild hardcodes the compiler name
# under LLVM=1, so interception happens through PATH. It matters more here than
# there, because the NDK download is the slow part and a re-run should not pay
# for the compile as well.
CC_WRAP=
command -v ccache >/dev/null 2>&1 && CC_WRAP="ccache "
cat > "$SHIM/clang" <<EOF
#!/bin/sh
# Append the Android target so it beats kbuild's --target=aarch64-linux-gnu.
exec ${CC_WRAP}$TOOL/clang "\$@" --target=aarch64-linux-android$API
EOF
# The link steps drive the compiler as the linker driver, so they need the shim
# too; everything else (llvm-ar, llvm-nm, ld.lld) is target-neutral.
cp "$SHIM/clang" "$SHIM/clang++"
chmod +x "$SHIM/clang" "$SHIM/clang++"
for t in ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
    ln -sf "$TOOL/$t" "$SHIM/$t"
done
export PATH="$SHIM:$TOOL:$PATH"

# fixdep and friends run on the build machine, so they must not be built with
# the shim -- name the real compiler for them explicitly.
# fixdep and friends run on the build machine, so they must not be built with
# the shim -- hence HOST_ARGS above, resolved before the shim existed.

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=$ART/build-bionic-$STAMP.log
mkdir -p "$O" "$ART"

{
    echo "### bionic build $STAMP"
    echo "### ndk=$NDK api=$API"
    echo "### head=$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null)"
} > "$LOG"

# Static: Android has no /lib/ld-linux-aarch64.so.1, and an app's
# nativeLibraryDir is the only place it may exec from anyway.
make -C "$TREE" O="$O" ARCH=um SUBARCH=arm64 LLVM=1 "${HOST_ARGS[@]}" -j"$JOBS" \
     defconfig 2>&1 | tee -a "$LOG" >/dev/null
# UML_NET_VECTOR stays ON. It was disabled here because it used to
# "select MAY_HAVE_RUNTIME_DEPS", which is incompatible with STATIC_LINK -- but
# that select is gone (see arch/um/drivers/Kconfig), and leaving the disable
# behind cost the app its only network device: umnet hands the kernel a
# "vec0:transport=fd,fd=N" argument that nothing then claims, so the guest boots
# with no interface at all while passt sits on the other end of the socketpair
# waiting for frames that never come.
"$TREE"/scripts/config --file "$O/.config" -e STATIC_LINK -e UML_NET_VECTOR

# The version string is part of the APK's identity, and this repository is the
# kernel, so it must not be part of the *build*. LOCALVERSION_AUTO, which
# init/Kconfig defaults to y, appends `git describe` of the repository HEAD --
# scripts/setlocalversion reads it straight out of git -- so every commit,
# including one that touches nothing the kernel compiles, gave the kernel a
# different UTS_RELEASE and therefore different bytes. build-apk.sh hashes those
# bytes into the recipe that decides whether the app has an update, so the effect
# was a new release, and an update offered to every installed app, for every push.
# The suffix is a fixed string here instead of a commit.
#
# The glibc kernels keep the automatic one: nothing ships them, and which commit
# a boot gate ran is worth having in its log.
"$TREE"/scripts/config --file "$O/.config" \
    -d LOCALVERSION_AUTO --set-str LOCALVERSION "-umarm"

# Page size. Asserted after olddefconfig rather than assumed before it:
# `scripts/config -e SYMBOL` on a symbol that does not exist prints a warning and
# carries on, and the result would be a kernel that boots everywhere except the
# host class it was built for -- by hanging, which is the failure mode this whole
# setting exists because of.
case "$PAGESIZE" in
16k) PAGESYM=PAGE_SIZE_16KB; NOTSYM=PAGE_SIZE_4KB ;;
4k)  PAGESYM=PAGE_SIZE_4KB;  NOTSYM=PAGE_SIZE_16KB ;;
*)   echo "build-bionic.sh: PAGESIZE must be 16k or 4k, not '$PAGESIZE'" >&2; exit 2 ;;
esac
"$TREE"/scripts/config --file "$O/.config" -d "$NOTSYM" -e "$PAGESYM"

# Extra fragments, e.g. EXTRA_CONFIG="config/usb-wifi.config config/docker.config".
# Merged before olddefconfig so their dependencies get pulled in properly.
for frag in ${EXTRA_CONFIG:-}; do
    [ -f "$frag" ] || { echo "no such config fragment: $frag" >&2; exit 2; }
    "$TREE"/scripts/kconfig/merge_config.sh -m -O "$O" "$O/.config" "$frag" \
        >/dev/null || exit 2
done
make -C "$TREE" O="$O" ARCH=um SUBARCH=arm64 LLVM=1 "${HOST_ARGS[@]}" -j"$JOBS" \
     olddefconfig 2>&1 | tee -a "$LOG" >/dev/null
grep -q "^CONFIG_${PAGESYM}=y" "$O/.config" || {
    echo "build-bionic.sh: $PAGESYM is not set in $O/.config after olddefconfig" >&2
    exit 1
}
make -C "$TREE" O="$O" ARCH=um SUBARCH=arm64 LLVM=1 "${HOST_ARGS[@]}" -j"$JOBS" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}

if [ "$rc" = 0 ] && [ -f "$O/linux" ]; then
    cp -f "$O/linux" "$ART/$NAME"
    cp -f "$O/arch/um/kernel/skas/stub_exe" "$ART/$STUBNAME" 2>/dev/null
    # The numbers a person needs to decide whether this binary is the one they
    # meant, next to the binary rather than in a log nobody keeps.
    {
        echo "name=$NAME"
        echo "page_size=$PAGESIZE"
        echo "page_symbol=$PAGESYM=y"
        echo "ndk=$(sed -n 's/^Pkg.Revision = //p' "$NDK/source.properties" 2>/dev/null || echo unknown)"
        echo "ndk_path=$NDK"
        echo "host_prebuilt=$HOSTPRE"
        echo "api=$API"
        echo "head=$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        echo "file=$(file -b "$ART/$NAME" | cut -c1-90)"
        echo "size=$(stat -c %s "$ART/$NAME" 2>/dev/null)"
        echo "md5=$(md5sum "$ART/$NAME" | cut -d' ' -f1)"
        echo "stub_md5=$(md5sum "$ART/$STUBNAME" 2>/dev/null | cut -d' ' -f1)"
    } > "$ART/$NAME.build.txt"
    echo "$NAME: $(file -b "$ART/$NAME" | cut -c1-90)"
    echo "md5=$(md5sum "$ART/$NAME" | cut -c1-8) stub=$(md5sum "$ART/$STUBNAME" 2>/dev/null | cut -c1-8) page=$PAGESIZE"
fi
echo "bionic build rc=$rc log=$LOG"
exit "$rc"
