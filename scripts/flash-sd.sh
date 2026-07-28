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

# --- Phase 1: write ----------------------------------------------------------
# bzcat decompresses on the fly; dd writes raw bytes to the card.
#
# Note what is deliberately NOT here any more: conv=fsync. It used to be on
# this line, and it made the script look frozen. Here's the mechanism, because
# it bites people on every OS:
#
#   A write to a block device normally lands in the kernel's PAGE CACHE and
#   returns immediately — "written" means "queued", not "on the flash". So
#   dd's status=progress races to 100% at RAM speed, then conv=fsync blocks
#   until the card has actually caught up, printing NOTHING for minutes.
#   Progress hits 100%, then silence: it looks like a hang, so people pull
#   the card or kill the terminal exactly when they must not.
#
# The image doubled in size in session 11 (two rootfs slots), which turned a
# barely-noticeable pause into a multi-minute one. So we now let dd finish
# fast and honestly, and show the flush as its own phase below.
echo ">>> Phase 1/3: writing image to $DEVICE ..."
bzcat "$IMAGE" | sudo dd of="$DEVICE" bs=4M status=progress

# --- Phase 2: flush ----------------------------------------------------------
# sync(2) returns only once every dirty page is on stable storage. Rather
# than call it and stare at a dead terminal, run it in the background and
# report how much is left.
#
# /proc/meminfo's Dirty = pages modified but not yet written out;
# Writeback = pages currently in flight to the device. Their sum is the
# backlog. It is a SYSTEM-WIDE number, so on a busy machine other processes
# contribute — but during a flash it's essentially all ours, and watching it
# fall to zero is the clearest possible "the card is really done" signal.
echo ">>> Phase 2/3: flushing kernel cache to the card ..."
echo "    (dd is finished; the card is not. Do NOT remove it yet.)"
sync &
SYNC_PID=$!
while kill -0 "$SYNC_PID" 2>/dev/null; do
    BACKLOG_KB=$(awk '/^Dirty:|^Writeback:/ { total += $2 } END { print total+0 }' /proc/meminfo)
    printf "\r    %6d MB left to write ... " "$((BACKLOG_KB / 1024))"
    sleep 1
done
wait "$SYNC_PID"
printf "\r    flush complete.                    \n"

# --- Phase 3: verify ---------------------------------------------------------
# "It probably wrote fine" is not good enough for a card you're about to put
# in a device that's hard to reach. Read the card back and compare it against
# the image, byte for byte.
#
# Skip with:  VERIFY=0 ./scripts/flash-sd.sh /dev/sdX
#
# Subtlety in reading cmp's output: the card is BIGGER than the image, so the
# decompressed stream always ends first and cmp reports "EOF on -" with exit
# status 1. That is the expected, successful outcome — not a mismatch. A real
# corruption prints a line containing "differ", which is what we test for.
if [ "${VERIFY:-1}" = "1" ]; then
    echo ">>> Phase 3/3: verifying (reading the card back) ..."
    CMP_OUT=$(bzcat "$IMAGE" | sudo cmp - "$DEVICE" 2>&1 || true)
    if printf '%s' "$CMP_OUT" | grep -q "differ"; then
        echo "ERROR: verification FAILED — the card does not match the image:"
        echo "  $CMP_OUT"
        echo "The card is not trustworthy. Re-run the flash."
        exit 1
    fi
    echo "    verified: card matches the image."
else
    echo ">>> Phase 3/3: verification skipped (VERIFY=0)."
fi

echo
echo ">>> Done. Safe to eject the card and boot the Pi."
