#!/bin/bash
# Find the Pi Zero W on whatever network it happens to be on.
#
# Usage:  ./scripts/find-board.sh              # scan the local subnet(s)
#         ./scripts/find-board.sh 192.168.43.0/24
#         ./scripts/find-board.sh --ssh        # find it, then connect
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
# subnet.
#
# ---------------------------------------------------------------------------
# WHAT WENT WRONG THE FIRST TIME THIS WAS USED IN ANGER  (session 26)
# ---------------------------------------------------------------------------
# It "took forever" on a work laptop and had to be abandoned. The bug was in
# target selection, not in the scan.
#
# The old version took EVERY globally-scoped IPv4 the host held and swept the
# enclosing network of each. On a personal PC that is one /24 and it is over
# in two seconds. On a corporate laptop the same loop finds:
#
#     the WiFi address           192.168.43.x/24      254 hosts   (the one we want)
#     a docker bridge            172.17.0.1/16      65534 hosts   (nothing there)
#     a VPN tunnel               10.x.x.x/16        65534 hosts   (ROUTED, not local)
#
# The docker sweep is merely slow. The VPN sweep is the killer: those
# addresses are not on the local wire, so there is no ARP to fail fast
# against — every one of 65534 probes waits for a timeout that never comes.
# That is minutes to tens of minutes, and the old script printed nothing at
# all while it ran, so it was indistinguishable from a hang.
#
# Three fixes, in order of importance:
#
#   1. ONLY SWEEP WHAT IS ON THE LOCAL WIRE. The board is a WiFi client on
#      the same L2 segment as this laptop. A tunnel or a container bridge
#      cannot possibly hold it, so those interfaces are skipped outright.
#   2. CAP THE PREFIX. Anything wider than MAX_HOSTS is clamped to the /24
#      around our own address, loudly. A /24 is what phone hotspots hand out;
#      if the real network is genuinely bigger, pass the CIDR explicitly.
#   3. SAY WHAT IS HAPPENING. Each target is announced before it is scanned
#      and timed after, so a slow sweep looks slow rather than dead.
#
# Plus a shortcut that beats all of them: the last address that worked is
# cached, and tried directly before any scanning happens. On the common case
# — same hotspot as yesterday — that answers in well under a second.
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
# working on the Pi 5 and on whatever comes next. Note 2c:cf:67 is Raspberry
# Pi Ltd and covers the Pico W as well as the Pi 4/5 — an OUI match is a
# family match, not a board match. Record BOARD_MAC and this stops being a
# guess.
RPI_OUIS="b8:27:eb dc:a6:32 e4:5f:01 28:cd:c1 2c:cf:67 d8:3a:dd"

# Interfaces that cannot possibly hold the board, matched as name prefixes.
# Tunnels (tun/tap/wg/tailscale/ppp/ipsec) carry routed traffic, not a local
# broadcast domain. Container and VM bridges (docker/br-/veth/virbr/vmnet)
# are local but hold containers, not Raspberry Pis. Sweeping any of them is
# pure cost.
SKIP_IFACE_PREFIXES="lo docker br- veth virbr vmnet tun tap wg tailscale ppp ipsec utun zt"

# Widest network we will sweep without being told to. 1024 addresses is a
# /22; a phone hotspot is a /24 and a home LAN is a /24. Anything wider is
# either a corporate network (where scanning is both slow and rude) or a
# misread, so we clamp to our own /24 and say so.
MAX_HOSTS="${MAX_HOSTS:-1024}"

# An exact MAC beats the OUI guess. Same file the addresses live in — it is
# a fact about this particular board, so it belongs outside the repo with
# the other deployment facts.
SECRETS_DIR="${SECRETS_DIR:-$HOME/.rpi0-secrets}"
NETWORK_ENV="${NETWORK_ENV:-$SECRETS_DIR/network.env}"
LAST_ADDR_FILE="${LAST_ADDR_FILE:-$SECRETS_DIR/last-address}"
_cli_mac="${BOARD_MAC:-}"
if [ -f "$NETWORK_ENV" ]; then
    # shellcheck source=/dev/null
    . "$NETWORK_ENV"
fi
BOARD_MAC="${_cli_mac:-${BOARD_MAC:-}}"
BOARD_MAC="$(echo "$BOARD_MAC" | tr 'A-Z' 'a-z')"

HOSTKEY_ALIAS="${HOSTKEY_ALIAS:-rpi0-logger}"
SSH_OPTS="-o HostKeyAlias=$HOSTKEY_ALIAS -o CheckHostIP=no"

# --- Arguments ---------------------------------------------------------------
DO_SSH=no
TARGETS=""
for arg in "$@"; do
    case "$arg" in
        --ssh)  DO_SSH=yes ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        -*)     echo "unknown option: $arg" >&2; exit 2 ;;
        *)      TARGETS="$TARGETS $arg" ;;
    esac
done
TARGETS="${TARGETS# }"

# ---------------------------------------------------------------------------
# STEP 0 — the shortcut: is it still where we last found it?
# ---------------------------------------------------------------------------
# Cheaper than any scan and correct most mornings, because you are usually on
# the same hotspot you were on yesterday and DHCP servers hand the same
# address back to the same MAC. One ping and one ARP lookup.
#
# We verify the MAC, not just the ping. Something else could have inherited
# that address; answering to a ping is not evidence of being our board.
try_cached() {
    [ -f "$LAST_ADDR_FILE" ] || return 1
    local ip mac
    ip="$(cat "$LAST_ADDR_FILE" 2>/dev/null)"
    [ -n "$ip" ] || return 1
    echo ">>> Trying last known address $ip first..."
    # -c1 one packet, -W1 wait at most a second, -n no reverse DNS.
    ping -c1 -W1 -n "$ip" >/dev/null 2>&1 || { echo "    no answer."; return 1; }
    mac="$(ip -4 neigh show "$ip" 2>/dev/null | awk '/lladdr/{print tolower($5)}' | head -n1)"
    if [ -n "$BOARD_MAC" ] && [ "$mac" != "$BOARD_MAC" ]; then
        echo "    answered, but MAC $mac is not the board. Scanning properly."
        return 1
    fi
    echo "    still there ($mac)"
    FOUND="$ip"
    return 0
}

# ---------------------------------------------------------------------------
# STEP 1 — work out what to scan
# ---------------------------------------------------------------------------
skip_iface() {
    local ifc="$1" p
    for p in $SKIP_IFACE_PREFIXES; do
        case "$ifc" in "$p"*) return 0 ;; esac
    done
    return 1
}

build_targets() {
    # `ip -4 -o addr show scope global` prints one line per address:
    #   3: wlp2s0    inet 192.168.43.17/24 brd ... scope global ...
    # $2 is the interface, $4 is the address with prefix.
    ip -4 -o addr show scope global | while read -r _idx ifc _fam cidr rest; do
        if skip_iface "$ifc"; then
            echo "SKIP $ifc $cidr virtual-or-tunnel" >&2
            continue
        fi

        # No broadcast flag means no broadcast domain, which means no ARP,
        # which means a sweep here is 254 timeouts. Point-to-point links and
        # most tunnels land in this branch even if the name didn't match.
        case "$rest" in
            *brd*) : ;;
            *)     echo "SKIP $ifc $cidr no-broadcast" >&2; continue ;;
        esac

        python3 - "$cidr" "$ifc" "$MAX_HOSTS" <<'PY'
import ipaddress, sys
cidr, ifc, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])
addr = ipaddress.ip_interface(cidr)
net  = addr.network
if net.num_addresses > cap:
    # Clamp to the /24 containing our own address. That is where a hotspot
    # or a home LAN puts its clients, and it keeps the sweep bounded.
    clamped = ipaddress.ip_network(f"{addr.ip}/24", strict=False)
    print(f"CLAMP {ifc} {net} ({net.num_addresses} addrs) -> {clamped}",
          file=sys.stderr)
    net = clamped
print(f"{net} {ifc}")
PY
    done
}

command -v nmap >/dev/null || {
    echo "ERROR: nmap is not installed.  sudo apt install nmap"
    exit 1
}

FOUND=""

if [ -z "$TARGETS" ]; then
    if try_cached; then
        TARGETS=""            # cache hit — no scanning needed at all
    else
        echo
        TARGET_LINES="$(build_targets)"
        TARGETS="$(echo "$TARGET_LINES" | awk 'NF{print $1}' | sort -u)"
        [ -n "$TARGETS" ] || {
            echo "ERROR: no scannable IPv4 network found."
            echo "       Every interface was a tunnel, a bridge, or too wide."
            echo "       Pass the subnet explicitly:  $0 192.168.43.0/24"
            exit 1
        }
    fi
fi

# --- Scan --------------------------------------------------------------------
if [ -z "$FOUND" ]; then
    if [ -n "$BOARD_MAC" ]; then
        echo ">>> Looking for MAC $BOARD_MAC (from $NETWORK_ENV)"
    else
        echo ">>> No BOARD_MAC recorded — matching Raspberry Pi OUIs instead."
        echo "    Record the exact one once and this gets unambiguous:"
        echo "      on the board:  ip link show wlan0"
        echo "      then add to $NETWORK_ENV:  BOARD_MAC=b8:27:eb:..."
    fi
    echo

    # One nmap per target, announced and timed, so a slow sweep is visibly
    # slow rather than silently hung.
    #
    #   -sn  ping sweep only, no port scan — enough to populate ARP
    #   -n   never do reverse DNS. On a hotspot there is no resolver worth
    #        waiting for, and this alone is the difference between 3 s and 30 s
    #   -T4  aggressive timing; fine on a local wire, and the point here is
    #        latency not stealth
    #   --host-timeout 3s  a hard ceiling per host, so one black hole cannot
    #        stall the whole sweep the way the VPN sweep used to
    for t in $TARGETS; do
        printf '    sweeping %-20s ' "$t"
        start=$SECONDS
        nmap -sn -n -T4 --host-timeout 3s "$t" >/dev/null 2>&1 || true
        echo "($((SECONDS - start))s)"
    done
    echo

    # --- Read the ARP cache the sweep just filled ----------------------------
    # `ip neigh` prints e.g.
    #   192.168.43.5 dev wlp2s0 lladdr b8:27:eb:12:34:56 REACHABLE
    # FAILED entries are addresses we probed and nothing answered; skip them.
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
    FOUND="${FOUND# }"
fi

echo
if [ -z "$FOUND" ]; then
    echo ">>> Nothing matched."
    echo
    echo "    Falling back to 'anything with ssh open' — the board is in here"
    echo "    somewhere if it associated at all:"
    for t in $TARGETS; do
        nmap -n -p 22 --open -T4 --host-timeout 3s "$t" 2>/dev/null \
            | awk '/Nmap scan report/{ip=$NF} /^22\/tcp +open/{print "    " ip}'
    done
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

# Remember the first hit so tomorrow's run skips the scan entirely.
if [ -d "$SECRETS_DIR" ]; then
    echo "$FOUND" | awk '{print $1}' > "$LAST_ADDR_FILE" 2>/dev/null || true
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
for ip in $FOUND; do
    echo ">>> ssh $SSH_OPTS root@$ip"
done

if [ "$DO_SSH" = yes ]; then
    target="$(echo "$FOUND" | awk '{print $1}')"
    echo
    echo ">>> connecting to $target"
    # shellcheck disable=SC2086
    exec ssh $SSH_OPTS "root@$target"
fi

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
echo "    Or skip all of it:  ./scripts/find-board.sh --ssh"
echo
echo "    If ssh says REMOTE HOST IDENTIFICATION HAS CHANGED, the board's"
echo "    host key really did change — which on this image means the card was"
echo "    reflashed, since dropbear_%.bbappend persists the key across"
echo "    reboots but not across a reflash:"
echo "      ssh-keygen -R $HOSTKEY_ALIAS"
