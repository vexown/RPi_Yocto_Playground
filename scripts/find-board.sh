#!/bin/bash
# Find the Pi Zero W on whatever network it happens to be on.
#
# Usage:  ./scripts/find-board.sh              # scan the local subnet(s)
#         ./scripts/find-board.sh 192.168.43.0/24
#         ./scripts/find-board.sh --ssh        # find it, then connect
#         ./scripts/find-board.sh --timeout 120  # keep trying this long (s)
#                                                  default 60; 0 = one sweep
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
# THE ALTERNATIVE WE DID NOT BUILD (considered 2026-10-04)
# ---------------------------------------------------------------------------
# The usual way to solve this is UDP discovery: the device listens on a port,
# the client sends ONE broadcast datagram, and every device that recognises
# the payload replies with its identity. mDNS/DNS-SD, SSDP and WS-Discovery
# are standardised versions; most industrial kit ships something bespoke.
#
# It is better than this script on nearly every axis. One packet instead of
# 254. A /16 costs the same as a /24, where sweeping a /16 is unusable. The
# reply carries a name, model, serial and firmware version instead of just
# "something with this MAC exists", so two identical boards are trivially
# distinguishable. The client is a UDP socket, so it is not Linux-only the
# way `ip neigh` is. And it does not look like a port scan on a corporate
# network.
#
# Two reasons we are still doing it this way.
#
#   1. ARP IS ANSWERED BY THE KERNEL. If the board boots, associates, and
#      then every userspace service falls over, it STILL answers ARP. A
#      discovery daemon does not. This is a debugging tool, so the sick-board
#      case is the case it exists for -- and "it is on the network but ssh is
#      not answering" versus "it never joined" are completely different
#      diagnoses. A beacon would be broken in precisely the situation where
#      the answer matters most.
#   2. Nothing at all has to run on the board, which is the whole design
#      brief for this image.
#
# Note that (2) argues against avahi far more than against a beacon, and the
# paragraph above slightly overstates its case. avahi really is unacceptable
# here -- it drags in dbus, a bus daemon and an ordering dependency on the
# network, on a 100 MB rootfs with ~29 MB free. But a bespoke responder is
# perhaps 80 lines, one socket, no dependencies, and under systemd socket
# activation it would not run at all until a packet arrived: no boot cost, no
# idle footprint. The footprint objection does not really survive that; only
# reason (1) does.
#
# So this is parked, not rejected -- and if it is ever built it should be an
# ADDITION. Beacon for the fast, informative path; this sweep as the fallback
# for a board that is too sick to answer it. Neither helps against client
# isolation on a hotspot, which blocks broadcast UDP exactly as it blocks ARP.
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
# WHY IT SWEEPS MORE THAN ONCE  (session 28, 2026-11-06)
# ---------------------------------------------------------------------------
# The first real hotspot test found the board on the SECOND run, not the
# first. The obvious story -- "the board had not got its address yet" -- was
# checked against the board's own journal and is false: it had held its DHCP
# lease for 56 s when the first sweep went out and saw nothing.
#
# A repeat probe with the board long up and the laptop long joined then missed
# 1 sweep in 6 (2 in 9 counting the first run), on one phone, one evening.
# So on a phone hotspot ONE EMPTY SWEEP IS NOT EVIDENCE OF ABSENCE. Why
# a sweep misses is still open: WiFi power saving on the board (brcmfmac
# enables it by default) and the phone's own AP behaviour are both
# candidates. Running the same probe with the board on a home router
# separates them.
#
# Whatever the cause, "run it again" was the fix, and a tool whose fix is
# "run it again" should do that itself. So it keeps sweeping, a few seconds
# apart, until it finds the board or TIMEOUT runs out. The same loop covers
# the most common case of all: you have just powered the board, and it needs
# ~20 s to get an address.
#
# ---------------------------------------------------------------------------
# HOW IT IDENTIFIES THE BOARD
# ---------------------------------------------------------------------------
# By MAC address, which is the one property of the board that does NOT
# change when it moves networks. Two ways:
#
#   BOARD_MAC in network.env — exact, if you have recorded it (run
#                              `ip link show wlan0` on the board once)
#   the IEEE prefix          — the leading bytes of a MAC are assigned to
#                              the manufacturer. Raspberry Pi holds ten
#                              blocks, and they are NOT all three bytes
#                              long — see RPI_OUIS below.
#
# Two sources, each used for what it is good at:
#
#   nmap      says WHO ANSWERED IN THIS SWEEP (its -oG output lists hosts
#             that are Up). That is the "is it there now" question.
#   ip neigh  says WHAT MAC an address has. Any packet sent to a host on the
#             local wire fills the kernel's ARP cache as a side effect, so it
#             works whether or not nmap has the privilege to report MACs
#             itself -- which is why this script needs no sudo.
#
# The earlier version asked ip neigh alone, and took every entry that was not
# FAILED. That includes STALE entries, which can be minutes old: a board that
# answered an ssh session ten minutes ago and has since left would still have
# been "found". With a retry loop that would be worse than a miss, because it
# stops the loop on a lie. So ip neigh is now only consulted for addresses
# nmap has just seen answer.
#
# Port 22 is used only as a tiebreaker/fallback, never as the primary
# signal: plenty of things answer on 22, and the board answers on 22 only
# once dropbear is up, which is later than it answers ARP.
set -euo pipefail

# First 24 bits (3 bytes) of a MAC address are assigned by the IEEE to an organization.
# This allows us to identify Raspberry Pi boards by their MAC address prefix, even if we don't know the full MAC address.
# This part of the MAC is called OUI (Organizationally Unique Identifier).
#
# Raspberry Pi Foundation / Raspberry Pi Ltd MAC prefixes, lowercase.
#
# SOURCE: the IEEE Registration Authority public registry listing, searched
# for "Raspberry Pi" on 2026-10-04:
#   https://regauth.standards.ieee.org/standards-ra-web/pub/view.html#registries
#
# NOT ALL PREFIXES ARE THREE BYTES. IEEE sells address blocks in three sizes and Raspberry Pi
# holds at least one of each:
#
#   MA-L   24-bit prefix,  6 hex digits   b8:27:eb         the classic "OUI",
#                                                          2^24 addresses
#   MA-M   28-bit prefix,  7 hex digits   f0:40:af:9       the low nibble is
#                                                          split between up to
#                                                          16 companies
#   MA-S   36-bit prefix,  9 hex digits   8c:1f:64:34:a    only 4096 addresses
#
# So the match below is a plain string prefix with NO trailing colon. An
# appended ":" would hard-code the 24-bit assumption and silently never match
# the MA-M or MA-S entries. For the same reason, do not "tidy" the
# odd-length entries into six digits: f0:40:af on its own would claim the
# fifteen other companies sharing that block.
#
# b8:27:eb is the one on a Zero W; the rest are here so this script keeps
# working on the Pi 5 and on whatever comes next. Note 2c:cf:67 is Raspberry
# Pi Ltd and covers the Pico W as well as the Pi 4/5 — a prefix match is a
# family match, not a board match. Record BOARD_MAC and this stops being a
# guess.
RPI_OUIS="b8:27:eb dc:a6:32 e4:5f:01 28:cd:c1 2c:cf:67 d8:3a:dd"  # MA-L
RPI_OUIS="$RPI_OUIS 88:a2:9e 98:fe:54"                            # MA-L
RPI_OUIS="$RPI_OUIS f0:40:af:9"                                   # MA-M
RPI_OUIS="$RPI_OUIS 8c:1f:64:34:a"                                # MA-S

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

# How long to keep sweeping before giving up, and the pause between sweeps.
# 60 s is about four sweeps of a /24 on a hotspot (one takes 3-15 s), and it
# covers a board that was powered on just before running this.
TIMEOUT="${TIMEOUT:-60}"
RETRY_GAP="${RETRY_GAP:-3}"

# --- Arguments ---------------------------------------------------------------
# A while/shift loop rather than `for arg`, because --timeout takes a value.
DO_SSH=no
TARGETS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ssh)  DO_SSH=yes ;;
        --timeout)
            [ $# -ge 2 ] || { echo "--timeout needs a number of seconds" >&2; exit 2; }
            TIMEOUT="$2"; shift ;;
        --timeout=*)
            TIMEOUT="${1#--timeout=}" ;;
        -h|--help)
            sed -n '2,9p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        -*)     echo "unknown option: $1" >&2; exit 2 ;;
        *)      TARGETS="$TARGETS $1" ;;
    esac
    shift
done
TARGETS="${TARGETS# }"
case "$TIMEOUT" in
    ''|*[!0-9]*) echo "--timeout needs a whole number of seconds" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# STEP 0 — the shortcut: is it still where we last found it?
# ---------------------------------------------------------------------------
# Cheaper than any scan and correct most mornings, because you are usually on
# the same hotspot you were on yesterday and DHCP servers hand the same
# address back to the same MAC. One ping and one ARP lookup.
#
# We verify the MAC, not just the ping. Something else could have inherited
# that address; answering to a ping is not evidence of being our board.
#
# Called once up front (loudly), and again before every later sweep (with
# "quiet", one line): if the board was just powered on and is coming back at
# yesterday's address, this is how the loop notices within a second.

# The MAC the kernel has for an address, lowercase, or nothing.
#   10.23.184.62 dev wlan0 lladdr b8:27:eb:cd:bd:ea REACHABLE
neigh_mac() {
    ip -4 neigh show "$1" 2>/dev/null | awk '/lladdr/{print tolower($5); exit}'
}

try_cached() {
    [ -f "$LAST_ADDR_FILE" ] || return 1
    local ip mac quiet="${1:-}"
    ip="$(cat "$LAST_ADDR_FILE" 2>/dev/null)"
    [ -n "$ip" ] || return 1
    [ -n "$quiet" ] || echo ">>> Trying last known address $ip first..."
    # -c1 one packet, -W1 wait at most a second, -n no reverse DNS.
    if ! ping -c1 -W1 -n "$ip" >/dev/null 2>&1; then
        if [ -n "$quiet" ]; then
            echo "    last known address $ip: no answer"
        else
            echo "    no answer."
        fi
        return 1
    fi
    mac="$(neigh_mac "$ip")"
    if [ -n "$BOARD_MAC" ] && [ "$mac" != "$BOARD_MAC" ]; then
        echo "    $ip answered, but MAC $mac is not the board."
        return 1
    fi
    echo "    $ip still there ($mac)"
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

# ---------------------------------------------------------------------------
# STEP 2 — one sweep: who answered just now, and is one of them the board?
# ---------------------------------------------------------------------------
# One nmap per target, announced and timed, so a slow sweep is visibly slow
# rather than silently hung.
#
#   -sn  ping sweep only, no port scan
#   -n   never do reverse DNS. On a hotspot there is no resolver worth
#        waiting for, and this alone is the difference between 3 s and 30 s
#   -T4  aggressive timing; fine on a local wire, and the point here is
#        latency not stealth
#   --host-timeout 3s  a hard ceiling per host, so one black hole cannot
#        stall the whole sweep the way the VPN sweep used to
#   -oG -  "grepable" output on stdout, one line per host that answered:
#            Host: 10.23.184.62 ()	Status: Up
#          This is the list of hosts that answered IN THIS SWEEP.
sweep_once() {
    local t start up n ip mac match oui
    for t in $TARGETS; do
        printf '    sweeping %-20s ' "$t"
        start=$SECONDS
        up="$(nmap -sn -n -T4 --host-timeout 3s -oG - "$t" 2>/dev/null \
                | awk '/Status: Up/{print $2}')" || true
        n="$(echo "$up" | awk 'NF' | wc -l)"
        echo "($((SECONDS - start))s, $n up)"

        for ip in $up; do
            mac="$(neigh_mac "$ip")"
            if [ -z "$mac" ]; then
                # nmap run as root talks ARP through a raw socket and leaves
                # the kernel's cache empty. One ping fills it.
                ping -c1 -W1 -n "$ip" >/dev/null 2>&1 || true
                mac="$(neigh_mac "$ip")"
            fi
            # Our own address lands here: a host has no ARP entry for itself.
            [ -n "$mac" ] || continue

            match=""
            if [ -n "$BOARD_MAC" ]; then
                [ "$mac" = "$BOARD_MAC" ] && match="exact MAC"
            else
                for oui in $RPI_OUIS; do
                    # Prefix match with no ":" appended, because the prefixes
                    # are 24, 28 or 36 bits wide. See RPI_OUIS at the top.
                    case "$mac" in "$oui"*) match="Raspberry Pi prefix $oui" ;; esac
                done
            fi
            [ -n "$match" ] || continue

            FOUND="$FOUND $ip"
            echo "    $ip  $mac  ($match)"
        done
    done
    FOUND="${FOUND# }"
}

FOUND=""
EXPLICIT=no
[ -z "$TARGETS" ] || EXPLICIT=yes
ROUND=0

# Explicit targets mean "scan THIS", so the cache is not consulted at all.
if [ "$EXPLICIT" = no ] && try_cached; then
    :                         # cache hit — no scanning needed at all
else
    if [ "$EXPLICIT" = no ]; then
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

    if [ -n "$BOARD_MAC" ]; then
        echo ">>> Looking for MAC $BOARD_MAC (from $NETWORK_ENV)"
    else
        echo ">>> No BOARD_MAC recorded — matching Raspberry Pi OUIs instead."
        echo "    Record the exact one once and this gets unambiguous:"
        echo "      on the board:  ip link show wlan0"
        echo "      then add to $NETWORK_ENV:  BOARD_MAC=b8:27:eb:..."
    fi
    echo "    (sweeping until found, for up to ${TIMEOUT}s — Ctrl-C to stop)"

    # ---------------------------------------------------------------------------
    # STEP 3 — sweep until found or out of time
    # ---------------------------------------------------------------------------
    # SECONDS is bash's own counter since the script started. The deadline is
    # checked after each sweep, so the last sweep may run a little past it
    # rather than being cut off half-way.
    DEADLINE=$((SECONDS + TIMEOUT))
    while :; do
        ROUND=$((ROUND + 1))
        echo
        echo ">>> sweep $ROUND  (${SECONDS}s elapsed)"
        sweep_once
        [ -z "$FOUND" ] || break
        [ "$SECONDS" -lt "$DEADLINE" ] || break
        sleep "$RETRY_GAP"
        if [ "$EXPLICIT" = no ] && try_cached quiet; then
            break
        fi
    done
fi

echo
if [ -z "$FOUND" ]; then
    echo ">>> Nothing matched after $ROUND sweep(s) in ${SECONDS}s."
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
    echo "         listed there, it associated and this is a scanning problem."
    echo "         Missed by EVERY sweep of a run points at client isolation on"
    echo "         the hotspot. A single miss would not: one sweep missed a board"
    echo "         that was online 2 times in 9 on a phone hotspot (2026-11-06),"
    echo "         which is why this script retries."
    echo
    echo "    Board powered on only just now? It needs ~20 s to get an"
    echo "    address. Give it longer:  $0 --timeout 120"
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
