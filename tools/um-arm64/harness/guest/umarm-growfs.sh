#!/bin/sh
# Grow an ext4 filesystem to fill its block device.
#
# UML has no partition table: /dev/ubdX *is* the filesystem, and the block
# device's size is the size of the backing file. The Android app grows the file
# (a sparse setLength) and this grows the filesystem to match; there is nothing
# else to do, because there is no partition to move.
#
# `resize2fs <dev>` with no size means "to the size of the device", which for a
# filesystem that already fills it is a no-op that still exits 0. That is what
# makes calling it on every boot safe and what makes it correct exactly once,
# the boot after the app made the file longer.
#
# Growing a *mounted* ext4 is supported online; both disks are mounted here and
# neither is ever shrunk from this side. resize2fs comes from e2fsprogs, which
# is in the image for mkfs.ext4 anyway; without it this degrades to a log line
# instead of failing a boot that would otherwise be fine.

log() { echo "umarm-grow: $*"; }

grow_dev() {
	dev=$1
	[ -b "$dev" ] || return 0
	if ! command -v resize2fs >/dev/null 2>&1; then
		log "resize2fs is not in this image; $dev is left at its current size"
		return 0
	fi
	out=$(resize2fs "$dev" 2>&1)
	rc=$?
	case "$out" in
	*"nothing to do"*)
		log "$dev already fills its device" ;;
	*)
		log "$dev: $out" ;;
	esac
	[ "$rc" = 0 ] || log "WARNING: resize2fs $dev exited $rc"
	return 0
}

for dev in "$@"; do
	grow_dev "$dev"
done
