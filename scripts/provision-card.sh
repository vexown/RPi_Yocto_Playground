#!/bin/bash
# Put the secrets on a freshly flashed card.
#
# Usage:  ./scripts/provision-card.sh /dev/sdX
#
#         Optional, for a static address (see network.env.example):
#           STATIC_ADDR=192.168.50.34/24 STATIC_GW=192.168.50.1 \
#             ./scripts/provision-card.sh /dev/sdX
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
#   /root/.ssh/authorized_keys                      0600 root:root
#       Your public key, so the board is reachable without relying on
#       debug-tweaks' empty root password. Note the path: /root, NOT
#       /home/root. This script said /home/root on its first outing, which
#       would have created a directory dropbear never looks at and failed
#       silently with "Permission denied (publickey)". Yocto images have
#       historically used /home/root for the root account and plenty of
#       documentation still says so, but this image's /etc/passwd says
#       /root and /home/root does not exist. Verify, don't remember:
#           awk -F: '$1=="root"{print $6}' <rootfs>/etc/passwd
#
#   /etc/systemd/network/20-wlan0.network.d/10-static.conf   0644 root:root
#       OPTIONAL — written only when a static address is configured. See
#       scripts/network.env.example for how to configure one.
#
#       A networkd DROP-IN, not a rewrite of 20-wlan0.network. networkd
#       merges /etc/systemd/network/<name>.network.d/*.conf over the base
#       file exactly the way systemd merges unit drop-ins, so the recipe's
#       file stays pristine as the documented product default, what this
#       script chose is one small file you can cat or diff, and undoing it
#       is `rm` of that file rather than "restore the backup you hopefully
#       still have".
#
#       The DIRECTION of the default is the point. The IMAGE ships
#       DHCP=ipv4, which works on any LAN. The static address — worth about
#       4 seconds of time-to-reachable, measured in session 18, see
#       notes/23 — is opt-in and applied here. So a card that is never
#       provisioned, or provisioned for the wrong site, still boots
#       reachable and can be found. The fast path is the one you ask for;
#       the safe path is what you get when something goes wrong. For a
#       headless board that is the right way round, and it is the opposite
#       of what a static address baked into the image would give you.
#
#   /etc/resolv.conf                                0644 root:root
#       OPTIONAL, written from STATIC_DNS alongside the address.
#
#       Needed because the image is built without systemd-resolved (see
#       meta-playground/recipes-core/systemd/systemd_%.bbappend). Without
#       resolved there is no update-alternatives link for /etc/resolv.conf
#       and nothing publishes a DHCP-learned resolver to a file: networkd
#       learns it and hands it to resolved over D-Bus, and with no resolved
#       there is nobody to hand it to. So a resolver has to be provisioned
#       or the board cannot resolve names at all.
#
#       systemd's tmpfiles would otherwise create /etc/resolv.conf at first
#       boot as a symlink to an empty file. The rule is type `L`, not `L+`,
#       and plain `L` never touches a path that already exists — which is
#       what makes writing a real file here work.
#
# Neither the PSK's nor the key's CONTENTS are ever printed by this script. Sizes and
# fingerprints only — the point of the exercise is defeated by a terminal
# scrollback with a PSK in it.
set -euo pipefail

DEVICE="${1:-}"

# Where the real credentials live. Override with:
#   SECRETS_DIR=/path/to/dir ./scripts/provision-card.sh /dev/sdX
SECRETS_DIR="${SECRETS_DIR:-$HOME/.rpi0-secrets}"

WPA_SRC="$SECRETS_DIR/wpa_supplicant-wlan0.conf"
# Which public key to install. Override explicitly with:
#   PUBKEY=~/.ssh/some_key.pub ./scripts/provision-card.sh /dev/sdX
#
# The default used to be a hardcoded $HOME/.ssh/id_ed25519.pub, which does
# not exist on this machine — the first run just failed. Guessing one
# filename out of the many ssh-keygen can produce is a bad default, so
# instead: prefer a key named after this board, then fall back to the
# conventional names in the order ssh itself prefers them (ed25519 before
# ecdsa before rsa).
if [ -z "${PUBKEY:-}" ]; then
    for candidate in pi_zero_key id_ed25519 id_ecdsa id_rsa; do
        if [ -f "$HOME/.ssh/$candidate.pub" ]; then
            PUBKEY="$HOME/.ssh/$candidate.pub"
            break
        fi
    done
fi

# Still nothing? Do not fail with a single guessed path — show what is
# actually available, with fingerprints, so the choice is one copy-paste
# away. An error message that lists the valid answers is worth ten that
# state the problem.
if [ -z "${PUBKEY:-}" ] || [ ! -f "$PUBKEY" ]; then
    echo "ERROR: no usable public key${PUBKEY:+ at $PUBKEY}."
    echo
    echo "Public keys found in $HOME/.ssh:"
    found=0
    for k in "$HOME"/.ssh/*.pub; do
        [ -f "$k" ] || continue
        found=1
        # Only offer keys whose PRIVATE half is here — installing a public
        # key you cannot authenticate with produces a board you have locked
        # yourself out of, which is the worst possible outcome for a
        # headless unit.
        if [ -f "${k%.pub}" ]; then usable="usable"; else usable="NO PRIVATE HALF ON THIS PC"; fi
        printf '    %-40s %-10s %s\n' "$k" "$usable" \
            "$(ssh-keygen -l -f "$k" 2>/dev/null | awk '{print $1, $NF}')"
    done
    [ "$found" = 1 ] || echo "    (none)"
    echo
    echo "Re-run with:  PUBKEY=<path> $0 $DEVICE"
    exit 1
fi

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
# (No -f check on $PUBKEY here: the key-selection block above already
# exits with a listing of the available keys if it cannot settle on one.)

# Warn, but do not refuse, if the private half is missing. It is legitimate
# to provision a card with someone else's public key — the work laptop's,
# say — but doing it by accident means a headless board you cannot log in
# to, so it should never be silent.
if [ ! -f "${PUBKEY%.pub}" ]; then
    echo "    WARNING: no private half at ${PUBKEY%.pub} — you will not be"
    echo "             able to ssh in from THIS machine with this key."
fi

# --- Optional static address -------------------------------------------------
# Where the site's network settings live, if it has any. Same directory as
# the PSK — but NOT for the same reason, and the difference is the whole
# design decision here.
#
# The PSK lives outside the repo because it is a SECRET. An IP address is
# not; there is nothing wrong with 192.168.50.34 appearing in a public
# commit. It lives outside anyway because it is a property of the SITE
# rather than of the product, and baking a site fact into an image you
# rebuild from a public repo makes a worse artifact — a binary that only
# works on one LAN.
#
# Those two axes — secret/not-secret and site/product — look like one axis
# as long as the only thing you provision is a PSK, which is both. The
# address is the case that separates them.
#
# $SECRETS_DIR is therefore slightly misnamed once this file lives in it.
# It is still the right home: it already exists, it is already outside the
# repo, and it is already the thing that survives a reflash. Inventing a
# second location for one more site fact is worse than a mildly inaccurate
# directory name.
NETWORK_ENV="${NETWORK_ENV:-$SECRETS_DIR/network.env}"

# Environment beats file. The caller's values have to be captured BEFORE
# sourcing, because sourcing would otherwise overwrite them: the file is
# the remembered default and the environment is the one-off override, and
# it would be surprising in the other direction.
_cli_addr="${STATIC_ADDR:-}"
_cli_gw="${STATIC_GW:-}"
_cli_dns="${STATIC_DNS:-}"
if [ -f "$NETWORK_ENV" ]; then
    # shellcheck source=/dev/null
    . "$NETWORK_ENV"
fi
STATIC_ADDR="${_cli_addr:-${STATIC_ADDR:-}}"
STATIC_GW="${_cli_gw:-${STATIC_GW:-}}"
STATIC_DNS="${_cli_dns:-${STATIC_DNS:-}}"

# Dotted-quad -> 32-bit integer, or non-zero exit. Used for exactly one
# thing: proving the gateway is on the same wire as the address.
ip_to_int() {
    local IFS=. o
    local a b c d
    read -r a b c d <<<"$1"
    for o in "$a" "$b" "$c" "$d"; do
        case "$o" in
            ''|*[!0-9]*) return 1 ;;
        esac
        # Reject leading zeros rather than accepting them. "010" is not a
        # harmless spelling of 10: shell arithmetic reads it as octal 8,
        # and so does ping(1) and much else. An address that silently means
        # something other than what it looks like is worse than an error.
        case "$o" in
            0|[1-9]*) ;;
            *) return 1 ;;
        esac
        [ "$o" -le 255 ] || return 1
    done
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

if [ -z "$STATIC_ADDR" ]; then
    # Nothing configured: the image's own 20-wlan0.network stands, and that
    # says DHCP. This is the fail-safe branch and it is the DEFAULT branch
    # on purpose — see the header.
    STATIC_MSG="DHCP — no static address configured, the card keeps the image default"
else
    # ---- Validate before touching the card ---------------------------------
    # Everything below runs before the mount, deliberately. The failure this
    # feature can cause is a headless board that boots fine and is
    # unreachable, so a bad value must never make it as far as the card.
    case "$STATIC_ADDR" in
        */*) ;;
        *) echo "ERROR: STATIC_ADDR needs a prefix length: '$STATIC_ADDR'"
           echo "       e.g. STATIC_ADDR=192.168.50.34/24"
           exit 1 ;;
    esac
    _addr="${STATIC_ADDR%%/*}"
    _plen="${STATIC_ADDR##*/}"

    case "$_plen" in
        ''|*[!0-9]*) echo "ERROR: prefix length '$_plen' is not a number."; exit 1 ;;
    esac
    if [ "$_plen" -lt 1 ] || [ "$_plen" -gt 32 ]; then
        echo "ERROR: prefix length /$_plen out of range (1-32). A home LAN is almost always /24."
        exit 1
    fi

    _addr_int="$(ip_to_int "$_addr")" || {
        echo "ERROR: '$_addr' is not a valid IPv4 address."
        echo "       Four decimal octets 0-255, no leading zeros: 192.168.50.34"
        exit 1
    }

    # The netmask as an integer. The & 0xFFFFFFFF matters: bash arithmetic
    # is 64-bit, so the left shift would otherwise leave high bits set.
    _mask=$(( (0xFFFFFFFF << (32 - _plen)) & 0xFFFFFFFF ))
    _net=$(( _addr_int & _mask ))
    _bcast=$(( _net | (~_mask & 0xFFFFFFFF) ))

    # Network and broadcast addresses are not host addresses. Assigning one
    # is a typo every time (usually .0 for .1, or .255 for .254), and the
    # kernel will not stop you.
    if [ "$_plen" -le 30 ]; then
        if [ "$_addr_int" -eq "$_net" ]; then
            echo "ERROR: $_addr is the NETWORK address of /$_plen, not a host address."
            exit 1
        fi
        if [ "$_addr_int" -eq "$_bcast" ]; then
            echo "ERROR: $_addr is the BROADCAST address of /$_plen, not a host address."
            exit 1
        fi
    fi

    # ---- The gateway, and the check this whole block exists for ------------
    if [ -z "$STATIC_GW" ]; then
        echo "ERROR: STATIC_ADDR is set but STATIC_GW is not."
        echo
        echo "  A static address with no gateway gives you a board that can"
        echo "  reach its own LAN and nothing else — no NTP, no updates, and"
        echo "  no clue as to why. That is a legitimate configuration for an"
        echo "  isolated sensor, so it is allowed, but it has to be said out"
        echo "  loud rather than reached by forgetting a line:"
        echo
        echo "      STATIC_GW=192.168.50.1     # normal case"
        echo "      STATIC_GW=none             # deliberately LAN-only"
        exit 1
    fi

    if [ "$STATIC_GW" = "none" ]; then
        STATIC_GW=""
    else
        _gw_int="$(ip_to_int "$STATIC_GW")" || {
            echo "ERROR: STATIC_GW='$STATIC_GW' is not a valid IPv4 address."
            exit 1
        }
        # THE check. A gateway outside the address's prefix is the classic
        # way to produce an unreachable headless board: the kernel accepts
        # the address, installs a default route via a next-hop that ARP can
        # never resolve, and the board boots to silence. Three lines here
        # delete the entire failure class.
        if [ "$(( _gw_int & _mask ))" -ne "$_net" ]; then
            echo "ERROR: gateway $STATIC_GW is not inside $STATIC_ADDR's subnet."
            echo
            echo "  The address puts this board on the /$_plen containing $_addr."
            echo "  A next-hop outside that range can never be reached by ARP, so"
            echo "  the default route would be installed and then blackhole every"
            echo "  packet. The board would boot normally and be unreachable."
            echo
            echo "  Either fix the gateway, or say STATIC_GW=none if this board is"
            echo "  genuinely meant to be LAN-only."
            exit 1
        fi
        if [ "$_gw_int" -eq "$_addr_int" ]; then
            echo "ERROR: gateway $STATIC_GW is the board's own address."
            exit 1
        fi
    fi

    # DNS defaults to the gateway. On a home LAN the router is the resolver
    # far more often than not, and it is what DHCP was handing us before.
    if [ -z "$STATIC_DNS" ]; then
        STATIC_DNS="$STATIC_GW"
    fi

    STATIC_MSG="$STATIC_ADDR via ${STATIC_GW:-(no gateway — LAN-only)}"
fi

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
# Read root's home out of the card's own /etc/passwd rather than hardcoding
# it. This image says /root; other Yocto images say /home/root; guessing
# wrong produces a key in a directory nothing reads and an SSH failure with
# no clue in it.
ROOT_HOME=$(awk -F: '$1=="root"{print $6}' "$MNT/etc/passwd")
[ -n "$ROOT_HOME" ] || { echo "ERROR: no root entry in the card's /etc/passwd"; exit 1; }
echo "    root's home per the card's /etc/passwd: $ROOT_HOME"
#
# The permissions here are load-bearing, and this is exactly what cost time
# on the Pi OS card in session 14: an SSH server silently ignores an
# authorized_keys whose ownership or mode is too loose (OpenSSH calls this
# StrictModes; dropbear checks the same things and is equally quiet about
# it). You get "Permission denied (publickey)" and no explanation anywhere.
sudo install -d -m 0700 -o 0 -g 0 "$MNT$ROOT_HOME/.ssh"
sudo install -m 0600 -o 0 -g 0 "$PUBKEY" "$MNT$ROOT_HOME/.ssh/authorized_keys"
echo "    key: $(ssh-keygen -l -f "$PUBKEY" | awk '{print $1, $2, $4}')"

echo ">>> Network addressing ..."
DROPIN_DIR="$MNT/etc/systemd/network/20-wlan0.network.d"
if [ -z "$STATIC_ADDR" ]; then
    # Idempotence: a re-provision that no longer sets a static address must
    # actually remove the old one. Leaving a stale drop-in behind would give
    # a card configured for the previous site while this script cheerfully
    # reported DHCP.
    if [ -e "$DROPIN_DIR/10-static.conf" ]; then
        echo "    removing stale static drop-in from a previous provisioning"
        sudo rm -f "$DROPIN_DIR/10-static.conf"
        sudo rmdir "$DROPIN_DIR" 2>/dev/null || true
    fi
    echo "    $STATIC_MSG"
    # No static address means no STATIC_DNS either, and this image has no
    # systemd-resolved to turn a DHCP-learned resolver into a file. The card
    # will boot, take an address from DHCP and be reachable BY IP, but it
    # will not resolve names. Say so plainly rather than let it be
    # discovered on a headless board.
    echo "    WARNING: no resolver will be configured. The board will get an"
    echo "             address from DHCP and be reachable by IP, but cannot"
    echo "             resolve names: this image is built without"
    echo "             systemd-resolved, so nothing publishes the DHCP"
    echo "             resolver to /etc/resolv.conf. Set STATIC_DNS to fix."
else
    sudo install -d -m 0755 -o 0 -g 0 "$DROPIN_DIR"
    # Written with tee because the redirection has to happen as root; a
    # plain `sudo echo ... >` would open the file as the calling user.
    {
        echo "# 10-static.conf — written by scripts/provision-card.sh."
        echo "#"
        echo "# Site-specific override of the image's DHCP default. Delete this"
        echo "# file (and reboot) to fall back to DHCP."
        echo "#"
        echo "# Why static: the DHCP path costs ~4 s of time-to-reachable on this"
        echo "# board, and not because the router is slow. The FIRST DHCP exchange"
        echo "# fails on every single boot (5/5 measured), so networkd sits out"
        echo "# RFC 2131's 4 +/- 1 s retransmission backoff before a retry that then"
        echo "# completes in ~25 ms. A static address is not a network conversation"
        echo "# at all — it is a netlink call — so there is no packet to lose and"
        echo "# no timer to roll dice against. See notes/22 and notes/23."
        echo ""
        echo "[Network]"
        echo "DHCP=no"
        echo "Address=$STATIC_ADDR"
        [ -n "$STATIC_GW" ]  && echo "Gateway=$STATIC_GW"
        [ -n "$STATIC_DNS" ] && echo "DNS=$STATIC_DNS"
    } | sudo tee "$DROPIN_DIR/10-static.conf" >/dev/null
    sudo chmod 0644 "$DROPIN_DIR/10-static.conf"
    sudo chown 0:0 "$DROPIN_DIR/10-static.conf"
    echo "    static: $STATIC_MSG"
    echo "    dns:    ${STATIC_DNS:-(none)}"
    if [ -z "$STATIC_DNS" ]; then
        echo
        echo "    WARNING: no resolver. This image has no systemd-resolved, so"
        echo "             nothing else will write /etc/resolv.conf and the board"
        echo "             will not resolve names — including the NTP pool, which"
        echo "             on this RTC-less board means no correct clock."
    fi
    # The resolver. Same argument as the address: a fact about the network
    # the board is deployed on, not about the product.
    printf '# Written by scripts/provision-card.sh.\n' \
        | sudo tee "$MNT/etc/resolv.conf" >/dev/null
    printf 'nameserver %s\n' "$STATIC_DNS" \
        | sudo tee -a "$MNT/etc/resolv.conf" >/dev/null
    sudo chmod 0644 "$MNT/etc/resolv.conf"
    sudo chown 0:0 "$MNT/etc/resolv.conf"
    echo "    resolver written to /etc/resolv.conf"
    echo
    echo "    Reminder: this address is claimed by the BOARD, and the LAN has no"
    echo "    authority that arbitrates that claim. Reserve it on the router"
    echo "    (ASUS: LAN -> DHCP Server -> Manually Assigned IP) so the DHCP"
    echo "    server never hands the same address to something else once the"
    echo "    board's old lease ages out."
fi

echo ">>> Syncing ..."
sync

echo
echo ">>> Done. Card provisioned:"
REPORT_PATHS=("$MNT/etc/wpa_supplicant" "$MNT$ROOT_HOME/.ssh")
[ -n "$STATIC_ADDR" ] && REPORT_PATHS+=("$DROPIN_DIR")
[ -n "$STATIC_DNS" ]  && REPORT_PATHS+=("$MNT/etc/resolv.conf")
sudo find "${REPORT_PATHS[@]}" -type f -printf '    %M %u:%g %p\n' \
    | sed "s#$MNT##"
echo
echo "    Safe to eject and boot. The board should appear on the LAN as"
echo "    hostname 'raspberrypi0-wifi' once wpa_supplicant associates."
