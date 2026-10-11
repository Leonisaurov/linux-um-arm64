#!/bin/sh
# The guest sources both root-filesystem builders pin, in one place.
#
# mkrootfs.sh turns these into an ext4 image and mkinitramfs.sh into an
# initramfs, and they have to agree: a gate that boots an Alpine image and a gate
# that boots an Alpine initramfs are testing the same guest, and two copies of a
# version string drift the moment one of them is updated. Sourced, not executed.
#
# Pinned by URL and sha256 so a gate cannot silently change its guest underneath
# itself. The version is in both the URL and the checksum, which is deliberate:
# the checksum is what actually holds, and the URL is what a human reads.

ALPINE_VERSION=${ALPINE_VERSION:-3.21.4}
ALPINE_BASE=${ALPINE_BASE:-https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64}
ALPINE_TARBALL=alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz
ALPINE_SHA256=${ALPINE_SHA256:-4ccfb9feda48b4f40fd9aceaf32b61e575d407387589deaabbd77cd9ed51e165}

DEBIAN_SUITE=${DEBIAN_SUITE:-bookworm}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
# iproute2 and nftables are for the docker prerequisites gate: a veth pair into a
# bridge, and nftables, which is what Debian's iptables-nft actually speaks.
DEBIAN_INCLUDE=${DEBIAN_INCLUDE:-build-essential,file,procps,psmisc,ca-certificates,iproute2,nftables,util-linux,kmod,gzip,xz-utils}

# Where the fetched tarballs are kept between runs.
CACHE=${CACHE:-${TMPDIR:-/tmp}/umarm-rootfs-cache}

# fetch <file>: download into $CACHE unless it is already there. The caller is
# responsible for checking the checksum; this only moves bytes.
fetch() {
    local f=$1

    [ -f "$CACHE/$f" ] && return 0
    mkdir -p "$CACHE"
    echo "downloading $ALPINE_BASE/$f" >&2
    curl -fsSL --retry 3 --retry-all-errors -o "$CACHE/$f.part" "$ALPINE_BASE/$f"
    mv "$CACHE/$f.part" "$CACHE/$f"
}
