#!/bin/bash
# Flash the latest Yocto image onto an SD card.
#
# Usage:  ./scripts/flash-sd.sh /dev/sdX
#         (find your SD card device with `lsblk -d -o NAME,SIZE,TRAN,MODEL`)
#
# What a .wic image is: a complete, already-partitioned disk image.
# For the Pi 5 it contains two partitions:
#   p1 (FAT32, "bootfiles"): GPU firmware, config.txt, cmdline.txt,
#       the kernel (as Image), and device tree blobs/overlays.
#       The Pi's boot ROM + firmware read this directly — no U-Boot involved.
#   p2 (ext4): the root filesystem built by core-image-minimal.
# So we write it to the *whole device* (/dev/sdX), not a partition (/dev/sdX1).
set -e

IMAGE_DIR="/media/blankmcu/EmbeddedLinux/yocto/build-rpi5/tmp/deploy/images/raspberrypi5"
# The unversioned name is a symlink that always points at the latest build.
IMAGE="$IMAGE_DIR/core-image-minimal-raspberrypi5.rootfs.wic.bz2"

DEVICE="$1"

if [ -z "$DEVICE" ]; then
    echo "Usage: $0 /dev/sdX"
    echo
    echo "Removable devices currently attached:"
    lsblk -d -o NAME,SIZE,TRAN,MODEL,RM | awk 'NR==1 || $NF==1'
    exit 1
fi

[ -f "$IMAGE" ] || { echo "ERROR: no image at $IMAGE — build one first."; exit 1; }
[ -b "$DEVICE" ] || { echo "ERROR: $DEVICE is not a block device."; exit 1; }

# --- Safety rails ------------------------------------------------------------
# Never write to the system disks. Adjust if your machine changes.
case "$DEVICE" in
    /dev/nvme*) echo "ERROR: $DEVICE is an NVMe disk — refusing."; exit 1 ;;
    /dev/sda)   echo "ERROR: /dev/sda is the internal SATA SSD — refusing."; exit 1 ;;
esac
# Refuse if any partition of the target is mounted (e.g. auto-mounted by the
# desktop). Unmount first so we don't write under a live filesystem.
if lsblk -no MOUNTPOINT "$DEVICE" | grep -q .; then
    echo "ERROR: $DEVICE has mounted partitions:"
    lsblk "$DEVICE"
    echo "Unmount them first (e.g. udisksctl unmount -b ${DEVICE}1)."
    exit 1
fi

echo "About to ERASE $DEVICE and write:"
echo "  $(readlink -f "$IMAGE")"
lsblk -d -o NAME,SIZE,MODEL "$DEVICE"
read -r -p "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

# bzcat decompresses on the fly; dd writes raw bytes to the card.
# conv=fsync + sync make sure everything hit the card before we say done.
bzcat "$IMAGE" | sudo dd of="$DEVICE" bs=4M status=progress conv=fsync
sync

echo ">>> Done. Eject the card and boot the Pi."
