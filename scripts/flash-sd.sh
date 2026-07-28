#!/bin/bash
# Flash the latest Yocto image onto an SD card.
#
# Usage:  ./scripts/flash-sd.sh /dev/sdX [image-name]
#         (find your SD card device with `lsblk -d -o NAME,SIZE,TRAN,MODEL`)
# image-name defaults to playground-image (our own image recipe);
# pass e.g. core-image-minimal to flash the stock one instead.
#
# What a .wic image is: a complete, already-partitioned disk image.
# So we write it to the *whole device* (/dev/sdX), not a partition (/dev/sdX1).
#
# Session 11 changed the layout (WKS_FILE in local.conf). It used to be two
# partitions; the A/B update scheme needs five:
#   p1 (FAT32, "boot"): GPU firmware, config.txt, cmdline.txt, the kernel
#       (as Image), device tree blobs/overlays — and now U-Boot plus its
#       compiled boot script and its environment block. Shared by both
#       slots, which is why a kernel change still needs a reflash.
#   p2 (ext4, "rootfs_A") and p3 (ext4, "rootfs_B"): two full copies of the
#       root filesystem. You run from one and update the other.
#   p5 (ext4, "data"): persistent storage, survives updates by living
#       outside both slots. RAUC's data-directory points here.
#   p6 (ext4, "homefs"): /home, grown on first boot.
# (There is no p4: p1-p3 plus an extended-partition container is how MBR
# gets past four entries, and wic numbers the logical ones from 5.)
set -e

IMAGE_DIR="/media/blankmcu/EmbeddedLinux/yocto/build-rpi5/tmp/deploy/images/raspberrypi5"
IMAGE_NAME="${2:-playground-image}"
# The unversioned name is a symlink that always points at the latest build.
IMAGE="$IMAGE_DIR/$IMAGE_NAME-raspberrypi5.rootfs.wic.bz2"

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
# Refuse if any partition of the target is mounted. The desktop auto-mounts
# removable cards on insert, so this fires on almost every reflash.
# Note: unmounting is per-PARTITION (/dev/sdc1), never the whole disk
# (/dev/sdc) — a disk itself is not a mountable filesystem.
MOUNTED_PARTS=$(lsblk -lno NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}')
if [ -n "$MOUNTED_PARTS" ]; then
    echo "ERROR: $DEVICE has mounted partitions. Run:"
    for p in $MOUNTED_PARTS; do
        echo "  udisksctl unmount -b /dev/$p"
    done
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
