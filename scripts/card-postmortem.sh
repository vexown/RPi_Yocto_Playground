#!/bin/bash
# Read a Pi's SD card on the PC and find out what happened on its last boot.
#
# Usage:  ./scripts/card-postmortem.sh /dev/sdX
#
# WHY THIS EXISTS
#
# The Zero W is headless and there is no 3.3 V UART adapter for it, so a
# board that does not appear on the network tells you nothing by itself.
# The green ACT LED is not a diagnostic: solid-on is consistent with "the
# firmware loaded bootcode.bin and stopped" AND with "Linux booted fine and
# nothing is touching the SD card". Guessing from it wastes reflashes.
#
# local.conf.rpi0 sets VOLATILE_LOG_DIR = "no", which makes /var/log a real
# directory on the rootfs. systemd then ships /var/log/journal, and
# journald's default Storage=auto persists whenever that directory exists.
# So the card is a flight recorder: power the board down, pull the card,
# and read the boot you could not watch.
#
# Everything here is READ-ONLY. Both partitions are mounted `ro` so a
# post-mortem can never be the thing that corrupts the evidence.
set -euo pipefail

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    echo "Usage: $0 /dev/sdX"
    echo
    lsblk -d -o NAME,SIZE,TRAN,MODEL,RM | awk 'NR==1 || $NF==1'
    exit 1
fi
case "$DEVICE" in
    /dev/nvme*) echo "ERROR: $DEVICE is an NVMe disk — refusing."; exit 1 ;;
    /dev/sda)   echo "ERROR: /dev/sda is the internal SATA SSD — refusing."; exit 1 ;;
esac
[ -b "$DEVICE" ] || { echo "ERROR: $DEVICE is not a block device."; exit 1; }

case "$DEVICE" in
    *[0-9]) P1="${DEVICE}p1"; P2="${DEVICE}p2" ;;
    *)      P1="${DEVICE}1";  P2="${DEVICE}2"  ;;
esac

MNT="$(mktemp -d /tmp/rpi0-pm.XXXXXX)"
cleanup() {
    mountpoint -q "$MNT/boot" && sudo umount "$MNT/boot" || true
    mountpoint -q "$MNT/root" && sudo umount "$MNT/root" || true
    rmdir "$MNT/boot" "$MNT/root" "$MNT" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$MNT/boot" "$MNT/root"

echo "=============================================================="
echo " 1. What the firmware was told to do"
echo "=============================================================="
if sudo mount -o ro "$P1" "$MNT/boot" 2>/dev/null; then
    echo "--- config.txt (non-comment lines) ---"
    grep -vE '^\s*(#|$)' "$MNT/boot/config.txt" 2>/dev/null | sed 's/^/    /' || echo "    (unreadable)"
    echo "--- cmdline.txt ---"
    sed 's/^/    /' "$MNT/boot/cmdline.txt" 2>/dev/null || echo "    (unreadable)"
    echo "--- kernel present? ---"
    ls -l "$MNT/boot"/kernel*.img 2>/dev/null | awk '{printf "    %s  %s bytes\n", $NF, $5}' \
        || echo "    !!! no kernel*.img on the boot partition"
else
    echo "    !!! could not mount $P1 — the FAT partition may be damaged."
fi

echo
echo "=============================================================="
echo " 2. Did userspace ever run?"
echo "=============================================================="
sudo mount -o ro "$P2" "$MNT/root" || { echo "    !!! could not mount $P2"; exit 1; }

# /etc/machine-id is the cleanest single marker. The image ships it EMPTY
# (image.bbclass creates it so a read-only rootfs can boot); systemd writes
# a real 32-hex-digit id into it the first time PID 1 runs far enough. So:
#   absent   -> the file was never even created (wrong rootfs?)
#   empty    -> systemd never got far enough to commit one
#   32 hex   -> PID 1 ran
MID="$MNT/root/etc/machine-id"
if [ ! -f "$MID" ]; then
    echo "    /etc/machine-id: ABSENT"
elif [ ! -s "$MID" ]; then
    echo "    /etc/machine-id: EMPTY -> systemd did not get far enough to commit one"
else
    echo "    /etc/machine-id: $(cat "$MID")  -> PID 1 ran"
fi

echo "    /var/log is a: $( [ -L "$MNT/root/var/log" ] && echo 'SYMLINK (volatile! VOLATILE_LOG_DIR did not take)' || echo 'real directory' )"

JDIR="$MNT/root/var/log/journal"
if [ ! -d "$JDIR" ]; then
    echo "    /var/log/journal: ABSENT -> journald had nowhere persistent to write"
else
    COUNT=$(find "$JDIR" -name '*.journal*' 2>/dev/null | wc -l)
    echo "    /var/log/journal: $COUNT journal file(s)"
fi

echo
echo "=============================================================="
echo " 3. The last boot, as the board saw it"
echo "=============================================================="
# journalctl reads the journal's documented on-disk format, which is
# architecture-independent — an x86_64 host reads an ARM board's journal
# fine. An unclean shutdown (i.e. every power-cut) leaves the file marked
# dirty; --file reads it anyway, sometimes with a warning.
if [ -d "$JDIR" ] && [ "$(find "$JDIR" -name '*.journal*' | wc -l)" -gt 0 ]; then
    echo "--- boot summary ---"
    sudo journalctl -D "$JDIR" --list-boots 2>&1 | tail -5 | sed 's/^/    /'
    echo
    echo "--- warnings and errors, last boot ---"
    sudo journalctl -D "$JDIR" -b -1 -p warning --no-pager 2>&1 | tail -60 | sed 's/^/    /' \
        || sudo journalctl -D "$JDIR" -p warning --no-pager 2>&1 | tail -60 | sed 's/^/    /'
    echo
    echo "--- anything mentioning wlan / brcm / wpa ---"
    sudo journalctl -D "$JDIR" --no-pager 2>/dev/null \
        | grep -iE 'wlan|brcmfmac|wpa_supplicant|firmware' | tail -30 | sed 's/^/    /' \
        || echo "    (nothing)"
else
    echo "    No journal to read."
    echo
    echo "    That is itself the finding: the board did not reach the point"
    echo "    where journald opens persistent storage. Next suspects are"
    echo "    firmware-level — config.txt overlays, the kernel image, or the"
    echo "    card itself. Section 1 above is what the firmware was handed."
fi

echo
echo "=============================================================="
echo " 4. Was the card provisioned?"
echo "=============================================================="
for f in /etc/wpa_supplicant/wpa_supplicant-wlan0.conf /root/.ssh/authorized_keys; do
    if [ -f "$MNT/root$f" ]; then
        echo "    present: $f  ($(stat -c '%A %u:%g' "$MNT/root$f"))"
    else
        echo "    MISSING: $f"
    fi
done
# Never print the PSK. Structure only.
W="$MNT/root/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
if [ -f "$W" ]; then
    echo "    wpa conf: $(grep -cE '^\s*network=\{' "$W" || true) network block(s), \
$(grep -cE '^\s*psk=' "$W" || true) psk line(s), \
country=$(grep -oE '^\s*country=[A-Z]{2}' "$W" | head -1 | cut -d= -f2 || echo '(unset)')"
fi
