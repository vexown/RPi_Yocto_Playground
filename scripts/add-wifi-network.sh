#!/bin/bash
# Add a WiFi network to the provisioning secrets, as a derived key.
#
# Usage:  ./scripts/add-wifi-network.sh <SSID> [priority]
#
#         ./scripts/add-wifi-network.sh "StatekMatka_V2" 10   # the bench
#         ./scripts/add-wifi-network.sh "MyPhoneHotspot" 5    # a site
#
# Prompts for the passphrase with echo off and never prints it, nor the key
# derived from it. Writes to $SECRETS_DIR/wpa_supplicant-wlan0.conf, which
# provision-card.sh then copies onto the card.
#
# ---------------------------------------------------------------------------
# WHY A SCRIPT AND NOT A TEXT EDITOR
# ---------------------------------------------------------------------------
# Three things have to be right and all three are easy to get wrong by hand:
#
#   1. The key is stored DERIVED, not plaintext. wpa_supplicant accepts
#      either — psk="password" or psk=<64 hex digits> — and this repo's
#      secrets file was carrying the plaintext form until it was checked.
#
#      To be clear about what that does and does not buy: the hex form is
#      password-equivalent, so anyone holding it can join the network. It is
#      not "encrypted". What it buys is (a) the human-memorable password,
#      which is very likely reused somewhere that matters more, never sits
#      on an SD card that lives in a drawer, and (b) the Pi Zero W skips
#      PBKDF2 — 4096 rounds of HMAC-SHA1 — on every single boot, on a
#      1 GHz ARM11.
#
#   2. wpa_passphrase's own output carries the plaintext back, as a
#      commented line:  #psk="the password you just typed".  Appending its
#      output verbatim — the obvious thing to do — puts the passphrase on
#      the card anyway, in a file you will then believe is safe. Every
#      comment is stripped below for exactly that reason.
#
#   3. The passphrase must not reach the shell's history or the process
#      table. Passing it as an argument to wpa_passphrase does both. It is
#      read from a terminal here instead.
set -euo pipefail

SSID="${1:-}"
PRIORITY="${2:-}"

if [ -z "$SSID" ]; then
    echo "Usage: $0 <SSID> [priority]"
    echo
    echo "Priority is a TIEBREAKER among networks that are in range right now,"
    echo "not a general preference. Give the bench network the higher number so"
    echo "the board does not hop onto a tethered phone while sitting at home."
    exit 1
fi

SECRETS_DIR="${SECRETS_DIR:-$HOME/.rpi0-secrets}"
CONF="$SECRETS_DIR/wpa_supplicant-wlan0.conf"

# Same guard as provision-card.sh: the one mistake that cannot be undone is
# writing a credential inside a public working tree.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(cd "$SECRETS_DIR" 2>/dev/null && pwd || echo "$SECRETS_DIR")" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "ERROR: SECRETS_DIR is inside the repository. Refusing."
        exit 1 ;;
esac

command -v wpa_passphrase >/dev/null || {
    echo "ERROR: wpa_passphrase not found.  sudo apt install wpasupplicant"
    exit 1
}

umask 077
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# A fresh file needs the global settings the per-network blocks sit under.
# country= is not optional decoration: without a regulatory domain the
# driver falls back to the most restrictive channel set, which can leave
# an access point on a perfectly legal channel simply invisible.
if [ ! -f "$CONF" ]; then
    echo ">>> Creating $CONF"
    {
        echo "# Written by scripts/add-wifi-network.sh. Not in the repository."
        echo "ctrl_interface=/var/run/wpa_supplicant"
        echo "update_config=0"
        echo "country=PL"
    } > "$CONF"
fi

if grep -qF "ssid=\"$SSID\"" "$CONF"; then
    echo "ERROR: $CONF already has a block for ssid=\"$SSID\"."
    echo "       Remove it by hand first if you mean to change its key."
    exit 1
fi

# -s: no echo. -r: a backslash in a password is a backslash.
printf 'Passphrase for "%s" (not echoed): ' "$SSID" >&2
read -rs PASSPHRASE
echo >&2

# WPA-PSK's own limits, checked here so the failure is a message now rather
# than a board that silently never associates.
_len=${#PASSPHRASE}
if [ "$_len" -lt 8 ] || [ "$_len" -gt 63 ]; then
    echo "ERROR: a WPA passphrase is 8-63 characters; got $_len."
    exit 1
fi

# The derivation. Passphrase goes in on stdin, never on the command line.
# Comments are stripped: see point 2 in the header — one of them is the
# plaintext passphrase.
# stderr is discarded because wpa_passphrase announces "reading passphrase
# from stdin" there, which lands directly under our own prompt and reads
# like a second prompt. Nothing is lost: the only failure mode is "no key
# came out", and that is checked explicitly below.
BLOCK="$(printf '%s\n' "$PASSPHRASE" \
         | wpa_passphrase "$SSID" 2>/dev/null \
         | grep -vE '^[[:space:]]*#')"
unset PASSPHRASE

case "$BLOCK" in
    *psk=*) ;;
    *) echo "ERROR: wpa_passphrase produced no key. Is the SSID valid UTF-8?"; exit 1 ;;
esac

{
    echo ""
    if [ -n "$PRIORITY" ]; then
        printf '%s\n' "$BLOCK" | sed "s/^}\$/\tpriority=$PRIORITY\n}/"
    else
        printf '%s\n' "$BLOCK"
    fi
} >> "$CONF"

chmod 600 "$CONF"

echo ">>> Added ssid=\"$SSID\"${PRIORITY:+ (priority=$PRIORITY)} to $CONF"
echo
echo "    Networks now configured, in file order:"
grep -oE 'ssid="[^"]*"|priority=[0-9]+' "$CONF" | sed 's/^/      /'
echo
echo "    Every key stored derived: $(grep -cE '^[[:space:]]*psk=[0-9a-f]{64}$' "$CONF") of $(grep -cE '^[[:space:]]*psk=' "$CONF")"
echo "    Now re-provision the card:  ./scripts/provision-card.sh /dev/sdX"
