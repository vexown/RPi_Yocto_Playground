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
mkdir -p "$MNT/boot" "$MNT/root"

# Track only the mounts WE made, so cleanup never unmounts something that
# was already there. The desktop auto-mounts removable media on insert
# (that is what /media/blankmcu/root is), and tearing down a mount we did
# not create would be a rude surprise mid-session.
OURS=""
cleanup() {
    for m in $OURS; do mountpoint -q "$m" && sudo umount "$m" || true; done
    rmdir "$MNT/boot" "$MNT/root" "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# Resolve a partition to a readable directory.
#
# First outing of this script died here: it assumed it owned the mounting,
# and the desktop had already auto-mounted both partitions, so every
# `mount` failed with "already mounted on /media/blankmcu/root". Refusing
# (the way flash-sd.sh does, because IT writes raw blocks and a mounted
# card is genuinely dangerous) is the wrong call for a read-only tool. We
# just use whatever mount already exists.
#
# The caveat, stated rather than hidden: a desktop auto-mount is READ-WRITE.
# Nothing here writes, but the evidence is then only as safe as this
# script's restraint, not as safe as a ro mount flag. Pass STRICT_RO=1 to
# refuse an existing rw mount instead of using it.
resolve_part() {
    local dev="$1" want="$2" existing
    existing="$(findmnt -n -o TARGET --source "$dev" 2>/dev/null | head -1 || true)"
    if [ -n "$existing" ]; then
        if [ "${STRICT_RO:-0}" = "1" ] && ! findmnt -n -o OPTIONS --source "$dev" | head -1 | grep -q '\bro\b'; then
            echo "" ; return 1
        fi
        echo "$existing"; return 0
    fi
    if sudo mount -o ro "$dev" "$want" 2>/dev/null; then
        OURS="$OURS $want"; echo "$want"; return 0
    fi
    echo ""; return 1
}

echo "=============================================================="
echo " 1. What the firmware was told to do"
echo "=============================================================="
BOOT="$(resolve_part "$P1" "$MNT/boot")" || true
if [ -n "$BOOT" ]; then
    echo "    (reading $P1 at $BOOT)"
    echo "--- config.txt (non-comment lines) ---"
    grep -vE '^\s*(#|$)' "$BOOT/config.txt" 2>/dev/null | sed 's/^/    /' || echo "    (unreadable)"
    echo "--- cmdline.txt ---"
    sed 's/^/    /' "$BOOT/cmdline.txt" 2>/dev/null || echo "    (unreadable)"
    echo "--- kernel present? ---"
    ls -l "$BOOT"/kernel*.img 2>/dev/null | awk '{printf "    %s  %s bytes\n", $NF, $5}' \
        || echo "    !!! no kernel*.img on the boot partition"
else
    echo "    !!! could not read $P1 — the FAT partition may be damaged."
fi

echo
echo "=============================================================="
echo " 2. Did userspace ever run?"
echo "=============================================================="
ROOT="$(resolve_part "$P2" "$MNT/root")" || true
[ -n "$ROOT" ] || { echo "    !!! could not read $P2"; exit 1; }
echo "    (reading $P2 at $ROOT)"

# WHICH IMAGE IS THIS? Ask before diagnosing anything.
#
# Added 2026-08-19, after this script confidently reported "VOLATILE_LOG_DIR
# did not take" about a card that was carrying an entirely different image
# -- the Pi 5's playground-image, written to the Zero W's card because
# flash-sd.sh used to default its target. Every check below is written
# against the expectations of rpi0-logger-image, so every one of them
# produced a plausible, confident, wrong answer.
#
# A diagnostic that does not first establish what it is looking at is not
# diagnosing, it is pattern-matching against an assumption. Same lesson as
# the 0700-directory bug in section 4: a test that cannot tell "wrong" from
# "different" will lie with confidence.
echo "--- which image is on this card? ---"
# /etc/os-release is 0644 by design, so no sudo here -- unlike section 4,
# which reads files inside 0700 directories and genuinely needs it.
if [ -r "$ROOT/etc/os-release" ]; then
    sed -n 's/^PRETTY_NAME=//p;s/^VERSION_ID=/version: /p' \
        "$ROOT/etc/os-release" | tr -d '"' | sed 's/^/    /'
else
    echo "    (no readable /etc/os-release)"
fi
# The kernel filename in the boot partition is the giveaway that matters:
# the firmware picks it by SoC, so kernel_2712.img means a Pi 5 image and
# kernel.img means an ARMv6 Pi Zero / Pi 1 image. Mismatched against the
# board you are holding, nothing else in this report is meaningful.
echo "    boot partition carries: $(ls "$BOOT" 2>/dev/null | grep -E '^kernel.*\.img$' | tr '\n' ' ')"
case "$(ls "$BOOT" 2>/dev/null | grep -cE '^kernel\.img$')" in
    0) echo "    !!! no plain kernel.img -- this is NOT an ARMv6 (Pi Zero/Pi 1) image" ;;
esac
echo

# /etc/machine-id is the cleanest single marker. The image ships it EMPTY
# (image.bbclass creates it so a read-only rootfs can boot); systemd writes
# a real 32-hex-digit id into it the first time PID 1 runs far enough. So:
#   absent   -> the file was never even created (wrong rootfs?)
#   empty    -> systemd never got far enough to commit one
#   32 hex   -> PID 1 ran
MID="$ROOT/etc/machine-id"
if [ ! -f "$MID" ]; then
    echo "    /etc/machine-id: ABSENT"
elif [ ! -s "$MID" ]; then
    echo "    /etc/machine-id: EMPTY -> systemd did not get far enough to commit one"
else
    echo "    /etc/machine-id: $(cat "$MID")  -> PID 1 ran"
fi

echo "    /var/log is a: $( [ -L "$ROOT/var/log" ] && echo 'SYMLINK (volatile! VOLATILE_LOG_DIR did not take)' || echo 'real directory' )"

JDIR="$ROOT/var/log/journal"
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
# These checks MUST run under sudo. Both paths are deliberately locked down
# — /etc/wpa_supplicant is 0700 root-owned, /root is 0700 — so an ordinary
# user gets EACCES on the directory and `[ -f ... ]` returns false. The
# first version of this script did exactly that and cheerfully reported
# both files MISSING on a card that had been provisioned correctly minutes
# earlier, sending us hunting for a phantom.
#
# Worth generalising: a test that cannot distinguish "absent" from
# "unreadable" is not a test, it is a coin flip that sometimes lies with
# confidence. Where the distinction matters, check for it.
for f in /etc/wpa_supplicant/wpa_supplicant-wlan0.conf /root/.ssh/authorized_keys; do
    if sudo test -f "$ROOT$f"; then
        echo "    present: $f  ($(sudo stat -c '%A %u:%g' "$ROOT$f"))"
    elif sudo test -e "$ROOT$f"; then
        echo "    EXISTS BUT NOT A REGULAR FILE: $f"
    else
        echo "    MISSING: $f"
    fi
done
# Never print the PSK. Structure only.
W="$ROOT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
if sudo test -f "$W"; then
    echo "    wpa conf: $(sudo grep -cE '^\s*network=\{' "$W" || true) network block(s), \
$(sudo grep -cE '^\s*psk=' "$W" || true) psk line(s), \
country=$(sudo grep -oE '^\s*country=[A-Z]{2}' "$W" | head -1 | cut -d= -f2 || echo '(unset)')"
fi
