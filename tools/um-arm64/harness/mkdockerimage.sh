#!/bin/bash
# Build the Alpine + Docker + OpenRC ext4 image the app and `alpine-um` boot.
#
#   ./mkdockerimage.sh /tmp/alpine-docker.ext4        # 1 GiB
#   SIZE=1536M ./mkdockerimage.sh /tmp/alpine.ext4
#
# What it produces is the image harness/guest/umarm-init-alpine documents:
#
#   * Alpine from the pinned minirootfs, with docker, openrc and the compose
#     plugin installed from the pinned release;
#   * /umarm-init (the Alpine PID 1) installed as the guest's init, plus
#     /umarm-poweroff and /umalpine-net.sh;
#   * a root-owned tree. This is load-bearing, not housekeeping: an Alpine
#     minirootfs extracted by an unprivileged user has /bin and /lib owned by
#     that user and mode 0700, so guest root reaches them only through
#     CAP_DAC_OVERRIDE -- which a process in a user namespace does not have
#     when the on-disk uid has no mapping. `unshare -U /bin/busybox` then fails
#     with EACCES and it looks like a kernel bug. It is not; see PENDIENTES
#     and doc/80-docker-alpine.md;
#   * /etc/network/interfaces with a loopback stanza, without which Alpine's
#     networking service fails and docker (`need net`) cannot start;
#   * the docker group, which the service's start_pre names.
#
# The packages are installed with the tree's *own* apk, run through the tree's
# *own* musl loader. There is no chroot and no boot: apk downloads as an
# ordinary host process and unpacks into --root. That is also why this only
# runs on an aarch64 host -- the loader is the guest's, and the guest is
# aarch64. CI's `build` job is an arm runner, which is where this runs.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$PWD/alpine-docker.ext4}
SIZE=${SIZE:-1G}
SUDO=${SUDO:-sudo}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.21}

# The docker set, and a few things the gates and a shell want. docker pulls
# containerd, runc and iptables; docker-cli-compose is the plugin, not the
# docker-compose python script.
PACKAGES=${PACKAGES:-"docker docker-cli-compose openrc nftables curl python3 strace"}

[ "$(uname -m)" = aarch64 ] || {
	echo "mkdockerimage.sh: needs an aarch64 host (the guest's loader is aarch64)" >&2
	exit 2
}
command -v mke2fs >/dev/null 2>&1 || {
	echo "mkdockerimage.sh: mke2fs not found (install e2fsprogs)" >&2
	exit 2
}

. "$HERE/pins.sh"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/umarm-dockerimg.XXXXXX")
cleanup() { $SUDO rm -rf "$STAGE" 2>/dev/null || rm -rf "$STAGE" 2>/dev/null || true; }
trap cleanup EXIT

fetch "$ALPINE_TARBALL"
echo "$ALPINE_SHA256  $CACHE/$ALPINE_TARBALL" | sha256sum -c - >&2
tar -xzf "$CACHE/$ALPINE_TARBALL" -C "$STAGE" --no-same-owner

printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n' \
	"$ALPINE_BRANCH" "$ALPINE_BRANCH" > "$STAGE/etc/apk/repositories"

LOADER=$STAGE/lib/ld-musl-aarch64.so.1
APK=$STAGE/sbin/apk
[ -x "$APK" ] && [ -e "$LOADER" ] || {
	echo "mkdockerimage.sh: no apk or musl loader in the minirootfs" >&2
	exit 2
}

echo "== installing: $PACKAGES ==" >&2
# Root, so apk can chroot into the tree to run each package's post-install
# script (the docker package's creates the docker group). Where that is not
# possible the group is created below anyway.
$SUDO "$LOADER" --library-path "$STAGE/lib:$STAGE/usr/lib" "$APK" \
	--root "$STAGE" --arch aarch64 --no-cache \
	--keys-dir "$STAGE/etc/apk/keys" \
	add $PACKAGES

echo "== guest-side files ==" >&2
# Every gate init, the Alpine PID 1 (which the loop would otherwise overwrite
# with the Debian guest/umarm-init of the same name), and the power-off helper.
for f in "$HERE"/guest/*; do
	$SUDO install -m 0755 "$f" "$STAGE/$(basename "$f")"
done
$SUDO install -m 0755 "$HERE/guest/umarm-init-alpine" "$STAGE/umarm-init"

# The loopback stanza networking parses; without it, `need net` fails and so
# does docker. See umarm-init-alpine.
$SUDO mkdir -p "$STAGE/etc/network"
$SUDO sh -c "printf 'auto lo\niface lo inet loopback\n' > '$STAGE/etc/network/interfaces'"

# docker's start_pre does `checkpath -o root:docker`, so the group has to
# exist whether or not a post-install script created it.
if ! grep -q '^docker:' "$STAGE/etc/group"; then
	$SUDO sh -c "echo 'docker:x:101:' >> '$STAGE/etc/group'"
fi

# openrc's runlevels. umarm-init-alpine populates them at boot with rc-update,
# but the directories have to exist for that to work -- and a gate that boots
# with init=/rc-docker-init has no umarm-init to do it, so the docker chain is
# linked here as well.
$SUDO mkdir -p "$STAGE"/etc/runlevels/sysinit "$STAGE"/etc/runlevels/boot \
	"$STAGE"/etc/runlevels/default "$STAGE"/etc/runlevels/shutdown
for svc in fsck root sysfs cgroups; do
	$SUDO ln -sfn "/etc/init.d/$svc" "$STAGE/etc/runlevels/sysinit/$svc"
done
for svc in hostname localmount networking; do
	$SUDO ln -sfn "/etc/init.d/$svc" "$STAGE/etc/runlevels/boot/$svc"
done
$SUDO ln -sfn /etc/init.d/docker "$STAGE/etc/runlevels/default/docker"

echo "== ownership and modes ==" >&2
# See the header: this is the userns fix, not tidiness. Directories 0755 so a
# process that is not the owner can traverse them, files as the archive has
# them.
$SUDO chown -R 0:0 "$STAGE"
$SUDO find "$STAGE" -type d -exec chmod 0755 {} +

echo "== filesystem ==" >&2
rm -f "$OUT"
$SUDO mke2fs -q -F -t ext4 -b 4096 -L umarm-docker -d "$STAGE" "$OUT" "$SIZE"
$SUDO chown "$(id -u):$(id -g)" "$OUT"

stats=$(dumpe2fs -h "$OUT" 2>/dev/null | awk -F: '
    /^Block count/ { total = $2 }
    /^Free blocks/ { free = $2 }
    END { gsub(/ /,"",total); gsub(/ /,"",free); printf "blocks=%s used=%s", total, total-free }')
echo "$OUT ($(stat -c %s "$OUT") bytes, $stats)"
