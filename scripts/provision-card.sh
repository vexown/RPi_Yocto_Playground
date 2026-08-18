#!/bin/bash
# Put the secrets on a freshly flashed card.
#
# Usage:  ./scripts/provision-card.sh /dev/sdX
#
# Run this AFTER ./scripts/flash-sd.sh and BEFORE putting the card in the Pi.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
# ---------------------------------------------------------------------------
# The image is reproducible from this repository. The credentials are not,
# and must never be: this repo is public. A WiFi PSK committed once is
# leaked permanently — the commit that "removes" it does not remove it from
# history, and GitHub keeps unreachable objects addressable by SHA. The
# only real remedy afterwards is changing the network's password.
#
# So the split is:
#
#   in the repo   the image, the recipes, this script, and an EXAMPLE of
#                 the credential file's format
#   outside it    the credential files themselves, in $SECRETS_DIR
#
# That keeps the WORKFLOW reproducible (this script is tracked, and it
# documents exactly what a provisioned card contains) while the SECRETS
# are not. Reflashing then stays a two-command operation instead of a
# half-remembered sequence of sudo mounts at 1am.
#
# ---------------------------------------------------------------------------
# WHAT IT INSTALLS
# ---------------------------------------------------------------------------
#   /etc/wpa_supplicant/wpa_supplicant-wlan0.conf   0600 root:root
#       Read by wpa_supplicant@wlan0.service, which
#       meta-playground/recipes-connectivity/rpi0-network enables via a
#       systemd preset. Without this file that unit fails at boot and the
#       board never joins the network. Format: see
#       .../rpi0-network/files/wpa_supplicant-wlan0.conf.example
#
#   /home/root/.ssh/authorized_keys                 0600 root:root
#       Your public key, so the board is reachable without relying on
#       debug-tweaks' empty root password.
#
# Neither file's CONTENTS are ever printed by this script. Sizes and
# fingerprints only — the point of the exercise is defeated by a terminal
# scrollback with a PSK in it.
set -euo pipefail

DEVICE="${1:-}"

# Where the real credentials live. Override with:
#   SECRETS_DIR=/path/to/dir ./scripts/provision-card.sh /dev/sdX
SECRETS_DIR="${SECRETS_DIR:-$HOME/.rpi0-secrets}"

WPA_SRC="$SECRETS_DIR/wpa_supplicant-wlan0.conf"
# Default to this machine's own key. Point PUBKEY at another file to
# install a different one (e.g. the work laptop's).
PUBKEY="${PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

MNT="$(mktemp -d /tmp/rpi0-card.XXXXXX)"
# Clean up the mountpoint no matter how we exit. Note the "|| true": if the
# umount fails we still want to try removing the (empty) directory, and we
# do not want the trap itself to abort under `set -e`.
cleanup() {
    if mountpoint -q "$MNT"; then sudo umount "$MNT" || true; fi
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# --- Argument and safety checks ---------------------------------------------
if [ -z "$DEVICE" ]; then
    echo "Usage: $0 /dev/sdX"
    echo
    echo "Removable devices currently attached:"
    lsblk -d -o NAME,SIZE,TRAN,MODEL,RM | awk 'NR==1 || $NF==1'
    exit 1
fi

# Same rails as flash-sd.sh. This one only mounts rather than writing raw
# blocks, but "mount the internal SSD's second partition and drop an
# authorized_keys in root's home" is not an improvement.
case "$DEVICE" in
    /dev/nvme*) echo "ERROR: $DEVICE is an NVMe disk — refusing."; exit 1 ;;
    /dev/sda)   echo "ERROR: /dev/sda is the internal SATA SSD — refusing."; exit 1 ;;
esac
[ -b "$DEVICE" ] || { echo "ERROR: $DEVICE is not a block device."; exit 1; }

# The rootfs is the second partition on the stock two-partition Zero W
# layout (p1 = FAT boot). Handle both naming schemes: /dev/sdc2 for SCSI/USB
# readers, /dev/mmcblk0p2 for a built-in card slot.
case "$DEVICE" in
    *[0-9]) ROOTPART="${DEVICE}p2" ;;   # mmcblk0 -> mmcblk0p2
    *)      ROOTPART="${DEVICE}2"  ;;   # sdc     -> sdc2
esac
[ -b "$ROOTPART" ] || { echo "ERROR: no root partition at $ROOTPART. Flash the card first."; exit 1; }

# --- Locate the secrets ------------------------------------------------------
# Refuse point-blank to read them out of the working tree. This is the
# guard against the most likely mistake: dropping the real conf next to the
# .example "just for a second" and committing it with everything else.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(cd "$SECRETS_DIR" 2>/dev/null && pwd || echo "$SECRETS_DIR")" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "ERROR: SECRETS_DIR is inside the repository ($SECRETS_DIR)."
        echo "       This repo is public. Keep credentials outside it."
        exit 1 ;;
esac

if [ ! -f "$WPA_SRC" ]; then
    echo "ERROR: no WiFi config at $WPA_SRC"
    echo
    echo "Create it once:"
    echo "  mkdir -p $SECRETS_DIR && chmod 700 $SECRETS_DIR"
    echo "  cp meta-playground/recipes-connectivity/rpi0-network/files/wpa_supplicant-wlan0.conf.example \\"
    echo "     $WPA_SRC"
    echo "  chmod 600 $WPA_SRC"
    echo "  \$EDITOR $WPA_SRC     # real SSID; psk from: wpa_passphrase 'SSID' 'password'"
    exit 1
fi
[ -f "$PUBKEY" ] || { echo "ERROR: no public key at $PUBKEY (set PUBKEY=... to choose another)"; exit 1; }

# --- Mount and install -------------------------------------------------------
echo ">>> Mounting $ROOTPART ..."
sudo mount "$ROOTPART" "$MNT"

# Sanity: is this actually one of our rootfs images and not, say, a stray
# data partition? /etc/os-release is written by the os-release recipe that
# the image recipe installs.
if [ ! -f "$MNT/etc/os-release" ]; then
    echo "ERROR: $ROOTPART has no /etc/os-release — this does not look like the rootfs."
    exit 1
fi
echo "    $(grep -E '^PRETTY_NAME=' "$MNT/etc/os-release" || echo 'PRETTY_NAME=?')"

echo ">>> Installing WiFi configuration ..."
# 0700 on the directory, 0600 on the file, root-owned. Ownership has to be
# set NUMERICALLY: we are writing into another system's filesystem, and the
# names "root"/"root" happen to resolve to 0:0 on this host too, but that
# is a coincidence we should not rely on when provisioning a foreign rootfs.
sudo install -d -m 0700 -o 0 -g 0 "$MNT/etc/wpa_supplicant"
sudo install -m 0600 -o 0 -g 0 "$WPA_SRC" "$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
# Report without leaking: the SSID line is safe to echo, the psk line is not.
echo "    ssid: $(sudo grep -oE 'ssid="[^"]*"' "$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" | head -1 || echo '(none found — check the file!)')"
echo "    psk lines present: $(sudo grep -cE '^[[:space:]]*psk=' "$MNT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" || true)"

echo ">>> Installing SSH public key ..."
# Root's home in a Yocto rootfs is /home/root, not /root.
#
# The permissions here are load-bearing, and this is exactly what cost time
# on the Pi OS card in session 14: an SSH server silently ignores an
# authorized_keys whose ownership or mode is too loose (OpenSSH calls this
# StrictModes; dropbear checks the same things and is equally quiet about
# it). You get "Permission denied (publickey)" and no explanation anywhere.
sudo install -d -m 0700 -o 0 -g 0 "$MNT/home/root/.ssh"
sudo install -m 0600 -o 0 -g 0 "$PUBKEY" "$MNT/home/root/.ssh/authorized_keys"
echo "    key: $(ssh-keygen -l -f "$PUBKEY" | awk '{print $1, $2, $4}')"

echo ">>> Syncing ..."
sync

echo
echo ">>> Done. Card provisioned:"
sudo find "$MNT/etc/wpa_supplicant" "$MNT/home/root/.ssh" -type f -printf '    %M %u:%g %p\n' \
    | sed "s#$MNT##"
echo
echo "    Safe to eject and boot. The board should appear on the LAN as"
echo "    hostname 'raspberrypi0-wifi' once wpa_supplicant associates."
