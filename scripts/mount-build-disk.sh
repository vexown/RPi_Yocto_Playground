#!/bin/bash
# Mount (creating first, if needed) the ext4 disk image that holds all the
# heavy Yocto build artifacts.
#
# Usage:
#   ./scripts/mount-build-disk.sh            # mount the existing image
#   ./scripts/mount-build-disk.sh create 250 # one-time: create a 250 GB image
#
# WHY an image file at all? The big external drive is exFAT (shared with
# Windows). Yocto needs a real POSIX filesystem (hardlinks, symlinks,
# xattrs, case sensitivity) and exFAT has none of that. Rather than
# repartitioning the drive, we keep one big file on exFAT containing an
# ext4 filesystem, and loop-mount it. Linux treats it exactly like a disk.
set -e

IMAGE="/media/blankmcu/6FA7-FC56/EmbeddedLinux/linux_filesystem.img"
MOUNT_POINT="/media/blankmcu/EmbeddedLinux"

if [ "$1" = "create" ]; then
    SIZE_GB="${2:?Usage: $0 create <size-in-GB>}"
    [ -f "$IMAGE" ] && { echo "ERROR: $IMAGE already exists — refusing to overwrite."; exit 1; }
    echo ">>> Allocating ${SIZE_GB} GB at $IMAGE (exFAT can't do sparse files, so this writes it all)..."
    # fallocate is instant on ext4/xfs but exFAT doesn't support it; dd is the
    # portable way. bs=1M keeps memory use sane, status=progress shows life.
    dd if=/dev/zero of="$IMAGE" bs=1M count=$((SIZE_GB * 1024)) status=progress
    echo ">>> Formatting as ext4..."
    # -F: mkfs asks for confirmation on non-block-devices without it.
    # No partition table needed — we format the file directly, like a
    # superfloppy. Simpler to mount and there's no reason for partitions.
    mkfs.ext4 -F -L EmbeddedLinux "$IMAGE"
    echo ">>> Created. Now run: $0"
    exit 0
fi

[ -f "$IMAGE" ] || {
    echo "ERROR: $IMAGE not found. Create it once with: $0 create 250"
    exit 1
}

if mountpoint -q "$MOUNT_POINT"; then
    echo "Already mounted at $MOUNT_POINT"
    exit 0
fi

sudo mkdir -p "$MOUNT_POINT"
# -o loop: attach the file to a /dev/loopN device and mount that.
sudo mount -o loop "$IMAGE" "$MOUNT_POINT"

# Make the mount usable by the desktop user. Only chown the top level —
# a recursive chown over ~100 GB of build tree would take minutes and is
# only ever needed the first time (everything below gets created as us).
sudo chown "$USER:$USER" "$MOUNT_POINT"

df -h "$MOUNT_POINT"
echo ">>> Mounted at $MOUNT_POINT"
