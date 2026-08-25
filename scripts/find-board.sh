#!/bin/bash
# Find the Pi Zero W on whatever network it happens to be on.
#
# Usage:  ./scripts/find-board.sh              # scan every subnet this host is on
#         ./scripts/find-board.sh 192.168.43.0/24
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# On the home LAN the board's address is a fact we chose: provision-card.sh
# writes a static 192.168.50.34 and ssh goes straight there. That answer is
# only available because we own the LAN.
#
# On a phone hotspot we own nothing. The phone picks the subnet (Android is
# usually 192.168.x.0/24 with x varying by vendor and by Android version;
# iOS Personal Hotspot is 172.20.10.0/28), runs the DHCP server, and hands
# the board whatever it likes. So the address cannot be provisioned, cannot
# be predicted, and has to be DISCOVERED.
#
# The discovery is done from the LAPTOP, not by the board, and that is the
# key move. Making the board announce itself would mean an mDNS responder
# (avahi + dbus) in the image: a new daemon, a rebuild, and a new thing that
# can be broken on the morning it matters. The laptop is already on the same
# hotspot, already knows its own address, and therefore already knows the
# subnet. A sweep of 254 addresses over WiFi takes a couple of seconds.
#
# ---------------------------------------------------------------------------
# HOW IT IDENTIFIES THE BOARD
# ---------------------------------------------------------------------------
# By MAC address, which is the one property of the board that does NOT
# change when it moves networks. Two ways:
#
#   BOARD_MAC in network.env — exact, if you have recorded it (run
#                              `ip link show wlan0` on the board once)
#   the OUI                  — the first three bytes are assigned to the
#                              manufacturer, and Raspberry Pi has a handful
#
# The MACs come from the host's ARP cache (`ip neigh`), not from nmap. Any
# packet sent to a host on the local wire populates that cache as a side
# effect, so the ping sweep fills it in whether or not nmap is running with
# enough privilege to report MACs itself. That also means this script needs
# no sudo.
#
# Port 22 is used only as a tiebreaker/fallback, never as the primary
# signal: plenty of things answer on 22, and the board answers on 22 only
# once dropbear is up, which is later than it answers ARP.
set -euo pipefail

# Raspberry Pi Foundation / Raspberry Pi Ltd OUI prefixes, lowercase.
# b8:27:eb is the one on a Zero W; the rest are here so this script keeps
# working on the Pi 5 and on whatever comes next.
RPI_OUIS="b8:27:eb dc:a6:32 e4:5f:01 28:cd:c1 2c:cf:67 d8:3a:dd"

# An exact MAC beats the OUI guess. Same file the addresses live in — it is
# a fact about this particular board, so it belongs outside the repo with
# the other deployment facts.
SECRETS_DIR="${SECRETS_DIR:-$HOME/.rpi0-secrets}"
NETWORK_ENV="${NETWORK_ENV:-$SECRETS_DIR/network.env}"
_cli_mac="${BOARD_MAC:-}"
if [ -f "$NETWORK_ENV" ]; then
    # shellcheck source=/dev/null
    . "$NETWORK_ENV"
fi
BOARD_MAC="${_cli_mac:-${BOARD_MAC:-}}"
BOARD_MAC="$(echo "$BOARD_MAC" | tr 'A-Z' 'a-z')"

command -v nmap >/dev/null || {
    echo "ERROR: nmap is not installed.  sudo apt install nmap"
    exit 1
}

# --- Work out what to scan ---------------------------------------------------
if [ $# -gt 0 ]; then
    TARGETS="$*"
else
    # Every globally-scoped IPv4 the host holds, as a CIDR, minus loopback.
    # "scope global" is what excludes 127.0.0.1 and link-local 169.254.x.
    # The address is our own, so nmap scanning its /24 covers the hotspot
    # subnet without us needing to know which one the phone chose.
    TARGETS="$(ip -4 -o addr show scope global \
                | awk '{print $4}' \
                | while read -r cidr; do
                      # Normalise 192.168.43.17/24 -> 192.168.43.0/24 so
                      # nmap scans the network, not just our own host.
                      ip route get "${cidr%%/*}" >/dev/null 2>&1 || continue
                      python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))" "$cidr"
                  done | sort -u)"
fi

[ -n "$TARGETS" ] || { echo "ERROR: no IPv4 network found. Is this host on WiFi?"; exit 1; }

echo ">>> Scanning: $TARGETS"
if [ -n "$BOARD_MAC" ]; then
    echo "    looking for MAC $BOARD_MAC (from $NETWORK_ENV)"
else
    echo "    no BOARD_MAC recorded — matching Raspberry Pi OUIs instead."
    echo "    Record the exact one once and this gets unambiguous:"
    echo "      on the board:  ip link show wlan0"
    echo "      then add to $NETWORK_ENV:  BOARD_MAC=b8:27:eb:..."
fi
echo

# -sn : ping sweep only, no port scan. Fast, and enough to populate ARP.
# -n  : never do reverse DNS. On a hotspot there is no resolver worth
#       waiting for, and this is the difference between 3 s and 30 s.
# shellcheck disable=SC2086
nmap -sn -n $TARGETS >/dev/null 2>&1 || true

# --- Read the ARP cache the sweep just filled --------------------------------
# `ip neigh` prints e.g.
#   192.168.43.5 dev wlp2s0 lladdr b8:27:eb:12:34:56 REACHABLE
# FAILED entries are addresses we probed and nothing answered; skip them.
FOUND=""
while read -r ip _dev iface _lladdr mac state; do
    [ "$_lladdr" = "lladdr" ] || continue
    [ "$state" != "FAILED" ] || continue
    mac="$(echo "$mac" | tr 'A-Z' 'a-z')"

    match=""
    if [ -n "$BOARD_MAC" ]; then
        [ "$mac" = "$BOARD_MAC" ] && match="exact MAC"
    else
        for oui in $RPI_OUIS; do
            case "$mac" in "$oui":*) match="Raspberry Pi OUI $oui" ;; esac
        done
    fi
    [ -n "$match" ] || continue

    FOUND="$FOUND $ip"
    echo "    $ip  $mac  on $iface  ($match)"
done < <(ip -4 neigh show 2>/dev/null)

echo
if [ -z "$FOUND" ]; then
    echo ">>> Nothing matched."
    echo
    echo "    Falling back to 'anything with ssh open' — the board is in here"
    echo "    somewhere if it associated at all:"
    # shellcheck disable=SC2086
    nmap -n -p 22 --open $TARGETS 2>/dev/null \
        | awk '/Nmap scan report/{ip=$NF} /^22\/tcp +open/{print "    " ip}'
    echo
    echo "    Still nothing means the board did not join the network. Check,"
    echo "    in this order:"
    echo "      1. the hotspot is 2.4 GHz — a Zero W has no 5 GHz radio at all"
    echo "      2. the hotspot is WPA2-Personal, not WPA3 — wpa_supplicant here"
    echo "         has SAE compiled in but brcmfmac on this chip is not a bet"
    echo "         worth taking on a work morning"
    echo "      3. the hotspot SSID and PSK really are in the card's"
    echo "         /etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
    echo "      4. the phone's own 'connected devices' list — if the board is"
    echo "         listed there, it associated and this is a scanning problem,"
    echo "         most likely client isolation on the hotspot"
    exit 1
fi

# HostKeyAlias is the part worth explaining, because the naive command
# (ssh root@$ip) prompts "authenticity of host can't be established" at
# every new site, and a prompt you learn to click through protects nothing.
#
# ssh files a host key in known_hosts under the NAME YOU TYPED. Type an
# address and you get an entry bound to that address, so the same board on
# a different network is, correctly, an unrecognised binding. That rule is
# not pedantry — without it, any key ever seen could be presented from any
# address.
#
# HostKeyAlias replaces the lookup key with a fixed string, so this board
# gets ONE known_hosts entry that follows it everywhere. The check is not
# weakened: a changed key still fails loudly, which is what you actually
# want to hear about. CheckHostIP=no stops ssh filing a second,
# address-keyed entry alongside it.
HOSTKEY_ALIAS="${HOSTKEY_ALIAS:-rpi0-logger}"

for ip in $FOUND; do
    echo ">>> ssh -o HostKeyAlias=$HOSTKEY_ALIAS -o CheckHostIP=no root@$ip"
done
echo
echo "    Tired of the flags? Put this in ~/.ssh/config once:"
echo
echo "        Host rpi0"
echo "            User root"
echo "            HostKeyAlias $HOSTKEY_ALIAS"
echo "            CheckHostIP no"
echo
echo "    then:  ssh rpi0 -o HostName=<address from above>"
echo
echo "    If ssh says REMOTE HOST IDENTIFICATION HAS CHANGED, the board's"
echo "    host key really did change — which on this image means the card was"
echo "    reflashed, since dropbear_%.bbappend persists the key across"
echo "    reboots but not across a reflash:"
echo "      ssh-keygen -R $HOSTKEY_ALIAS"
