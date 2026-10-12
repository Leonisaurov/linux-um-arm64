#!/bin/bash
# umalpine.sh -- boot a minimal Alpine guest inside this UML, with internet,
# and leave you in a shell.
#
# This phone (Termux on Android, aarch64) has no root, no tap device and no user
# namespaces, so the guest's network comes from umnet + passt: umnet reframes
# between UML's vector `fd` transport and passt, a userspace TCP/IP stack that
# reaches the world through ordinary sockets. See
# tools/um-arm64/doc/90-networking.md.
#
# The script finds the pieces (kernel, stub_exe, Alpine ext4 image, umnet,
# passt) in the usual places on the phone, boots them, and injects a small
# network bring-up through hostfs. The guest then DHCPs, gets DNS and drops into
# /bin/sh.
#
#   ./umalpine.sh                 interactive shell (needs a terminal)
#   ./umalpine.sh -c 'uname -a'   run one command and print its output
#   ./umalpine.sh --docker        boot Alpine with dockerd running, not just
#                                 the network -- needs a docker kernel and a
#                                 docker image; see doc/80-docker-alpine.md
#   ./umalpine.sh -h              this help
#
# Invoked as `alpine-um` this is --docker, because that name is the launcher a
# runtime directory ships: copy this file there under that name and the pieces
# next to it are the docker ones.
#
# Environment overrides:
#   UMALPINE_KERNEL UMALPINE_IMAGE UMALPINE_UMNET UMALPINE_PASST UMALPINE_STUB
#   UMALPINE_MEM (default 512M)   UMALPINE_INIT (default /umarm-init)
#   UMALPINE_NET=0                boot without the network helpers
#   UMALPINE_DOCKER=1             same as --docker
#   UMALPINE_SHARE                host directory shared with the guest as /host
set -uo pipefail

usage() {
	cat >&2 <<'EOF'
usage: umalpine.sh [-h] [-v] [-D] [-c 'COMMAND']

  (no -c)            boot a minimal Alpine guest and leave you in a shell
  -c 'COMMAND'       run one command in the guest, print its output, exit
  -D, --docker       boot the Alpine image that has Docker, mount cgroup2 and
                     start dockerd before the shell (also the default when
                     this script is called as `alpine-um`)
  -v                 verbose: pass umnet --verbose (frame logging)
  -h                 this help

The kernel, stub_exe, alpine.ext4, umnet and passt are searched for in the
usual places on the phone; if one is missing the script names it and prints
where it looked. Override any of them with the environment variables
UMALPINE_KERNEL, UMALPINE_STUB, UMALPINE_IMAGE, UMALPINE_UMNET, UMALPINE_PASST.

Inside the guest the network is up already; try
    wget -O- http://example.com | head
    nslookup example.com 1.1.1.1
EOF
	exit "${1:-0}"
}

HERE=$(cd "$(dirname "$0")" && pwd)
HOME_DIR=${HOME:-$HERE}
TMP=${TMPDIR:-${PREFIX:-/tmp}/tmp}

log() { printf '[umalpine] %s\n' "$*" >&2; }
die() { printf 'umalpine: %s\n' "$*" >&2; exit 2; }

# The kernel CI builds for the docker gate is glibc-linked, and Termux has no
# /lib/ld-linux-aarch64.so.1. `grun --configure` (patchelf) points its
# interpreter and rpath at Termux's glibc, and the result is an ordinary
# executable -- nothing has to wrap it at run time. A statically linked bionic
# kernel has no interpreter and is left untouched, which is why this is a no-op
# there rather than a step someone has to remember.
maybe_configure_kernel() {
	local interp

	command -v patchelf >/dev/null 2>&1 || return 0
	interp=$(patchelf --print-interpreter "$KERNEL" 2>/dev/null) || return 0
	[ -n "$interp" ] || return 0
	[ -e "$interp" ] && return 0
	command -v grun >/dev/null 2>&1 || {
		log "$KERNEL wants $interp, which is not on this host."
		log "Install glibc-runner (pkg install glibc-runner), use a bionic"
		log "kernel, or set UMALPINE_KERNEL."
		return 1
	}
	log "configuring $KERNEL for Termux's glibc (grun --configure)"
	grun --configure "$KERNEL" >&2 || return 1
}

CMD=""
VERBOSE=0
DOCKER=${UMALPINE_DOCKER:-0}
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) usage 0 ;;
	-c) shift; [ $# -gt 0 ] || die "-c needs a command"; CMD=$1 ;;
	-c*) CMD=${1#-c} ;;
	-D|--docker) DOCKER=1 ;;
	-v|--verbose) VERBOSE=1 ;;
	--) shift; break ;;
	-*) die "unknown option: $1 (try -h)" ;;
	*) break ;;
	esac
	shift
done
[ $# -eq 0 ] || die "unexpected argument: $1 (put the guest command after -c)"
[ "$(basename "$0")" = alpine-um ] && DOCKER=1

# --- locate the pieces ------------------------------------------------------
# Every candidate is an explicit path. When something is missing the script
# prints the file it wanted and the list it searched, rather than dying with a
# kernel panic twenty lines further down.
MISSING=0
found_path() {  # found_path <label> <candidate...> -> first existing path
	local label=$1; shift
	local p
	local cands=()
	for p in "$@"; do [ -n "$p" ] && cands+=("$p"); done
	for p in "${cands[@]}"; do
		[ -e "$p" ] && { printf '%s\n' "$p"; return 0; }
	done
	printf 'umalpine: missing %s\n' "$label" >&2
	printf 'umalpine:   looked in: %s\n' "${cands[*]}" >&2
	return 1
}

KERNEL_CANDS=("${UMALPINE_KERNEL:-}")
# Docker mode needs a kernel built with config/docker.config: the default build
# has no namespaces, no cgroup v2 and no veth/bridge/nftables, so dockerd dies
# during network setup and containers cannot start. The docker kernels are
# named after what they are and looked for next to this script first.
if [ "$DOCKER" = 1 ]; then
	KERNEL_CANDS+=(
		"$HERE/linux-um-docker"
		"$HERE/linux"
		"$HERE/kernel-docker"
		"$HOME_DIR/Develop/um-rss/alpine-um/linux-um-docker"
		"$HOME_DIR/Develop/um-rss/16k/linux-um-docker"
	)
fi
KERNEL_CANDS+=(
	"$HOME_DIR/Develop/um-rss/16k/linux-um"
	"$HOME_DIR/Develop/um-rss/4k/linux-um"
	"$HOME_DIR/Develop/um-new/linux-um"
	"$HOME_DIR/Develop/umdebian/linux-um"
	"$HOME_DIR/Develop/tmp/linux"
	"$TMP/art/linux-um-arm64"
	"$HERE/../dist/umdebian/linux-um"
)
KERNEL=$(found_path "UML kernel (linux-um)" "${KERNEL_CANDS[@]}") || MISSING=1
KDIR=$(dirname "${KERNEL:-.}")

STUB_CANDS=(
	"${UMALPINE_STUB:-}"
	"${KERNEL:+$KDIR/stub_exe}"
	"$HOME_DIR/Develop/tmp/stub_exe"
	"$HOME_DIR/Develop/um-rss/16k/stub_exe"
)
STUB=$(found_path "stub_exe" "${STUB_CANDS[@]}") || MISSING=1

IMAGE_CANDS=("${UMALPINE_IMAGE:-}")
# The docker guest is a different image from the plain Alpine one: docker
# installed, and grown from 64 MB to something that holds it (the packages are
# ~242 MB). Look for it next to the script before the plain image, or the
# launcher would boot the image that cannot run docker.
if [ "$DOCKER" = 1 ]; then
	IMAGE_CANDS+=(
		"$HERE/alpine.ext4"
		"$HERE/alpine-docker.ext4"
		"$HOME_DIR/Develop/um-rss/alpine-um/alpine.ext4"
	)
fi
IMAGE_CANDS+=(
	"$HOME_DIR/Develop/um-rss/16k/alpine.ext4"
	"$HOME_DIR/Develop/um-rss/4k/alpine.ext4"
	"$HOME_DIR/Develop/um-new/alpine.ext4"
	"$HOME_DIR/Develop/umdebian/alpine.ext4"
	"$HOME_DIR/Develop/tmp/alpine.ext4"
	"$TMP/umalpine/alpine.ext4"
	"$HERE/../dist/umdebian/alpine.ext4"
)
IMAGE=$(found_path "Alpine ext4 image (alpine.ext4)" "${IMAGE_CANDS[@]}") || MISSING=1

if [ "${UMALPINE_NET:-1}" != 0 ]; then
	UMNET_CANDS=(
		"${UMALPINE_UMNET:-}"
		"${KERNEL:+$KDIR/umnet}"
		"$HOME_DIR/Develop/um-net/umnet"
		"$HOME_DIR/Develop/tmp/umnet-fixed"
		"$TMP/umnet-ci/umnet"
	)
	UMNET=$(found_path umnet "${UMNET_CANDS[@]}") || MISSING=1
	PASST_CANDS=(
		"${UMALPINE_PASST:-}"
		"${KERNEL:+$KDIR/passt}"
		"$HOME_DIR/Develop/um-net/passt"
		"$HOME_DIR/Develop/tmp/passt"
	)
	PASST=$(found_path passt "${PASST_CANDS[@]}") || MISSING=1
else
	UMNET=""; PASST=""
fi

[ "$MISSING" = 0 ] || die "one or more pieces are missing (see the list above)"
[ -r "$KERNEL" ] || die "kernel is not readable: $KERNEL"
[ -r "$IMAGE" ]  || die "image is not readable: $IMAGE"
maybe_configure_kernel || die "could not make $KERNEL runnable on this host"

# --- the host share the guest mounts as /host -------------------------------
SHARE=${UMALPINE_SHARE:-${TMP%/}/umalpine-share}
mkdir -p "$SHARE" || die "cannot create share directory $SHARE"
rm -f "$SHARE/cmd" "$SHARE/umalpine-net.sh" "$SHARE/umalpine-docker.sh" 2>/dev/null

# The network script is injected through hostfs, not baked into the image, so
# the DHCP logic can change without rebuilding the disk. /umarm-init mounts the
# share and runs /host/cmd, which sources this.
cat > "$SHARE/umalpine-net.sh" <<'NET'
#!/bin/sh
# Bring the UML vector NIC (vec0) up, get a DHCP lease and DNS.
IF=vec0
[ -d "/sys/class/net/$IF" ] || IF=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -1)
[ -n "$IF" ] || { echo "umalpine-net: no network interface"; exit 0; }
ip link set lo up 2>/dev/null
ip link set "$IF" up 2>/dev/null
i=0
while [ "$i" -lt 3 ]; do
	udhcpc -i "$IF" -q -n -t 5 -T 3 2>&1 && break
	i=$((i + 1)); sleep 1
done
[ -s /etc/resolv.conf ] || echo "nameserver 1.1.1.1" > /etc/resolv.conf
NET
chmod 0755 "$SHARE/umalpine-net.sh"

# The Docker bring-up, injected the same way as the network so it can change
# without rebuilding the disk. It is three things the minirootfs does not do
# for itself: mount cgroup v2, clear the pidfile and socket a killed dockerd
# leaves behind (this image's /var/run is not a tmpfs, so they survive a
# poweroff and the next daemon refuses to start), and start the daemon.
if [ "$DOCKER" = 1 ]; then
	cat > "$SHARE/umalpine-docker.sh" <<'DOCKER'
#!/bin/sh
# Bring dockerd up. cgroup v2 is what Docker uses on this kernel and nothing
# in the minirootfs mounts it, so the daemon would start with no controllers.
if [ ! -e /sys/fs/cgroup/cgroup.controllers ]; then
	mkdir -p /sys/fs/cgroup
	mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null
fi
rm -f /var/run/docker.pid /var/run/docker.sock
mkdir -p /var/log
if ! command -v dockerd >/dev/null 2>&1; then
	echo "umalpine: no dockerd in this image -- this is the Alpine image, not the docker one" >&2
	echo "umalpine: install it with: apk add e2fsprogs-extra && resize2fs /dev/ubda && apk add docker" >&2
else
	dockerd > /var/log/dockerd.log 2>&1 &
	i=0
	while [ ! -S /var/run/docker.sock ] && [ "$i" -lt 30 ]; do
		sleep 1; i=$((i + 1))
	done
	if [ -S /var/run/docker.sock ] && docker info >/dev/null 2>&1; then
		echo "umalpine: dockerd up ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
	else
		echo "umalpine: dockerd did not come up; /var/log/dockerd.log follows" >&2
		tail -30 /var/log/dockerd.log >&2
	fi
fi
DOCKER
	chmod 0755 "$SHARE/umalpine-docker.sh"
fi

# What /umarm-init runs before the shell or the command. The network is always
# first; the daemon needs it to reach a registry.
GUEST_PROLOGUE='. /host/umalpine-net.sh'
if [ "$DOCKER" = 1 ]; then
	GUEST_PROLOGUE="$GUEST_PROLOGUE
. /host/umalpine-docker.sh"
fi

# --- command line -----------------------------------------------------------
MEM=${UMALPINE_MEM:-512M}
INIT=${UMALPINE_INIT:-/umarm-init}
COMMON=(mem="$MEM" ubd0="$IMAGE" root=/dev/ubda rw init="$INIT"
	umarm.share="$SHARE" panic=-1 con=null seccomp=auto)
[ -n "$STUB" ] && COMMON=(stub_exe="$STUB" "${COMMON[@]}")

NET_CMD=()
if [ -n "$UMNET" ]; then
	NET_CMD=("$UMNET")
	[ "$VERBOSE" = 1 ] && NET_CMD+=(--verbose)
	NET_CMD+=(--passt "$PASST" --)
fi

export HOME="${HOME:-$SHARE}"          # UML builds its umid dir from $HOME
{ [ -d "${TMPDIR:-}" ] && [ -w "${TMPDIR:-}" ]; } || export TMPDIR="$SHARE"

# --- run --------------------------------------------------------------------
if [ -n "$CMD" ]; then
	# One-shot. The command travels through the share rather than the kernel
	# command line, which cannot carry spaces or quoting.
	{ printf '%s\n' "$GUEST_PROLOGUE"; printf '%s\n' "$CMD"; } > "$SHARE/cmd"
	log "booting $KERNEL with $IMAGE (one-shot)"
	out=$(timeout "${UMALPINE_TIMEOUT:-300}" "${NET_CMD[@]}" \
		"$KERNEL" "${COMMON[@]}" con0=null,fd:1 2>&1 | cat)
	rc=$?
	if printf '%s\n' "$out" | grep -q 'UMARM_OUTPUT_BEGIN'; then
		printf '%s\n' "$out" |
			sed -n '/UMARM_OUTPUT_BEGIN/,/UMARM_EXIT=/p' |
			sed -e '/UMARM_OUTPUT_BEGIN/d' -e '/UMARM_EXIT=/d' | tr -d '\r'
		grc=$(printf '%s\n' "$out" |
			sed -n 's/.*UMARM_EXIT=\([0-9]*\).*/\1/p' | tail -1)
		exit "${grc:-0}"
	fi
	printf '%s\n' "$out" >&2
	printf '%s\n' "$out" | grep -q 'Failed to lock' &&
		die "another umalpine/umdebian is already running (the image is locked)"
	[ "$rc" = 0 ] || log "kernel exited with $rc"
	die "the guest never reached the command; the full boot log is above"
fi

# Interactive. The same hostfs injection, ending in an interactive shell. con0
# must be a pollable descriptor: UML registers it with epoll, and a pipe or
# /dev/null makes epoll_ctl fail, after which the console goes silent and a
# terminal that was not there looks like a boot that never finished.
{
	printf '%s\n' "$GUEST_PROLOGUE"
	cat <<'ONE'
printf 'umalpine: Alpine %s aarch64, kernel %s\n' "$(cat /etc/alpine-release 2>/dev/null)" "$(uname -r)"
printf "umalpine: internet check:  wget -O- http://example.com | head   /   nslookup example.com 1.1.1.1\n"
printf "umalpine: docker check:    docker run --rm hello-world\n"
printf "umalpine: 'exit' (or Ctrl-D) leaves the guest.\n"
exec /bin/sh -l
ONE
} > "$SHARE/cmd"

if [ ! -t 0 ]; then
	echo "umalpine: stdin is not a terminal; run this from an interactive shell," >&2
	echo "          or pass a command: $0 -c 'uname -a'" >&2
	exit 2
fi
log "booting $KERNEL with $IMAGE; 'exit' inside the guest powers it off"
log "internet check inside the guest: wget -O- http://example.com | head"
[ "$DOCKER" = 1 ] && log "docker check inside the guest: docker run --rm hello-world"
exec "${NET_CMD[@]}" "$KERNEL" "${COMMON[@]}" con0=fd:0,fd:1
