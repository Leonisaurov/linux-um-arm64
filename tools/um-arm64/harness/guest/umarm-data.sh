#!/bin/sh
# The persistent data disk: everything the user owns, on a disk the guest-image
# update does not touch.
#
# Contract with the launcher: the data disk is ubd1, the block device
# /dev/ubdb. It is a different *file* from the base image (ubd0), so replacing
# the base -- which is what installing a new guest image does -- cannot reach
# anything here. The APK creates the file on first boot and never replaces it;
# only a restore does.
#
# What lives on it:
#
#   /home            the user's files, and the wizard's account
#   /var/lib/docker  every image and container docker pulled
#   /var/lib/umarm   the "the wizard already ran" record
#   /root            the root account's files
#
# ...and nothing else. /etc, /usr and /lib belong to the base image and are
# replaced with it, which is the point: a rootfs fix arrives as a new base while
# these four directories stay. The trade is that `apk add` puts a package in the
# base, so packages are *not* kept across an image update; only these four
# directories are.
#
# First boot on a fresh data disk formats it (ext4), and -- exactly once, when
# it formats -- copies what the base image already had in these four places, so
# the transition from the old single-disk layout loses nothing. Every later boot
# only mounts.
#
# No ubd1 on the command line -- the harness without UMALPINE_DATA, and every
# gate that does not ask for a data disk -- is a no-op, which is what makes this
# safe to call unconditionally from the guest's init.

DATA_DEV=/dev/ubdb
DATA_DIR=/data
PAIRS="home:/home docker:/var/lib/docker umarm:/var/lib/umarm root:/root"

log() { echo "umarm-data: $*"; }

[ -b "$DATA_DEV" ] || {
	log "no $DATA_DEV (no ubd1= on the command line); the base image keeps its own directories"
	exit 0
}

# A filesystem is present when the ext superblock magic is where ext puts it:
# two bytes at offset 0x438 (1080), 0xEF53 little-endian. This is checked here
# rather than with dumpe2fs because Alpine ships mkfs.ext4 in e2fsprogs but
# dumpe2fs in e2fsprogs-extra: with dumpe2fs missing the test would always say
# "no filesystem", every boot would look like the first, and mkfs would run
# over a good disk and erase it. The magic needs nothing but dd and od, and the
# only disk that reaches mkfs is one with no ext superblock at all.
is_ext4() {
	magic=$(dd if="$1" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
	[ "$magic" = "53ef" ]
}

mkdir -p "$DATA_DIR"

if is_ext4 "$DATA_DEV"; then
	FORMATTED=0
	log "$DATA_DEV already carries a filesystem; keeping it"
else
	FORMATTED=1
	log "formatting $DATA_DEV as ext4"
	if ! mkfs.ext4 -q -F -L umarm-data "$DATA_DEV"; then
		log "mkfs.ext4 failed; the guest continues without a data disk"
		exit 0
	fi
fi

if ! mount -t ext4 "$DATA_DEV" "$DATA_DIR" 2>/dev/null; then
	log "cannot mount $DATA_DEV; the guest continues without a data disk"
	exit 0
fi

# The app grows the backing file, this fills the filesystem. Online grow on a
# mounted ext4 is fine, and a no-op when the app did not enlarge anything.
# umarm-growfs.sh is a no-op too when the image has no resize2fs.
[ -x /umarm-growfs.sh ] && /umarm-growfs.sh "$DATA_DEV"

for pair in $PAIRS; do
	name=${pair%%:*}
	dst=${pair#*:}
	mkdir -p "$DATA_DIR/$name" "$dst"
	if [ "$FORMATTED" = 1 ] && [ -d "$dst" ]; then
		# Seed the fresh disk from the base image, before the bind hides it.
		# cp -a and not mv: this is a different device, so a move is a copy
		# anyway, and the base has to stay intact for the rest of the boot.
		cp -a "$dst/." "$DATA_DIR/$name/" 2>/dev/null
	fi
	mount -o bind "$DATA_DIR/$name" "$dst" 2>/dev/null ||
		log "WARNING: cannot bind $DATA_DIR/$name over $dst"
done

# docker's own service does `checkpath -o root:docker` on its data root, and the
# package creates it 0710 root:docker. A freshly formatted disk has it 0755
# root:root, so put it back the way the daemon expects.
if [ -d /var/lib/docker ]; then
	chown root:docker /var/lib/docker 2>/dev/null
	chmod 0710 /var/lib/docker 2>/dev/null
fi

log "/home, /var/lib/docker, /var/lib/umarm and /root are on $DATA_DEV (kept across an image update)"
sync
