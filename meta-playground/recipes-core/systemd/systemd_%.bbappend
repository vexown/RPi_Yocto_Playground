# systemd_%.bbappend — build systemd without four subsystems this appliance
# never uses.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS
# ---------------------------------------------------------------------------
# Everything removed here was measured first, on the running board, with
# `systemctl mask` and a reboot. Nothing is removed on the grounds that it
# "looks unnecessary" — session 18 spent an afternoon establishing that
# neither `systemd-analyze blame` nor a unit's CPU time predicts what
# deleting it will save, so the only trustworthy method is to delete it and
# measure. See notes/23 §9.
#
#   unit                        measured        why this board does not need it
#   --------------------------  --------------  --------------------------------
#   systemd-vconsole-setup      -0.487 s        console font and keymap; no
#                                               monitor, no keyboard, and no
#                                               framebuffer since the vc4
#                                               overlay was dropped
#   systemd-logind              -1.344 s        seat/session management; the only
#                                               login path is dropbear, which
#                                               does not use logind
#   systemd-resolved            -0.788 s        caching DNS proxy; one interface,
#                                               no VPN, no split-DNS, and
#                                               nsswitch.conf has no `resolve`
#                                               entry so nothing ever reached it
#                                               through NSS
#   systemd-userdbd             -0.795 s        userdb API for dynamic users;
#                                               every account here comes from
#                                               /etc/passwd via `compat`
#
# Total measured: 3.414 s of a 21.390 s boot, taking it to 17.889 s.
#
# The masks that produced those numbers left the unit FILES on disk, so
# systemd still parsed and loaded them at every boot. Removing the
# PACKAGECONFIG deletes the units along with the binaries, so the rebuilt
# image should come out at or slightly below 17.889 s. If it comes out
# SLOWER, something here is wrong and worth chasing rather than shrugging at.
#
# ---------------------------------------------------------------------------
# WHY nss-resolve IS IN THE LIST WITHOUT ITS OWN MEASUREMENT
# ---------------------------------------------------------------------------
# It is not a boot-time saving — nothing loads it, because nsswitch.conf has
# no `resolve` entry. It is here because the build FAILS without it.
# systemd's meson.build pairs the two:
#
#     foreach tuple : [['nss-mymachines', 'machined'],
#                      ['nss-resolve',    'resolve']]
#             ...
#             if want.enabled() and not have
#                     error('@0@ is requested but @1@ is disabled'...)
#
# poky's default PACKAGECONFIG sets both, so `-Dnss-resolve=true` with
# `-Dresolve=false` hits that error(). Verified by reading meson.build in the
# unpacked source, not guessed.
#
# ---------------------------------------------------------------------------
# THE CONSEQUENCE THAT MATTERS: /etc/resolv.conf
# ---------------------------------------------------------------------------
# This is the one thing to understand before flashing a card.
#
# With resolved present, poky registers /etc/resolv.conf as an
# update-alternatives link to /etc/resolv-conf.systemd, which points into
# /run/systemd/resolve/ where resolved writes the real thing (recipe line
# ~836, ALTERNATIVE:${PN}). Remove `resolved` and that alternative is not
# registered at all — the image ships NO /etc/resolv.conf.
#
# What appears instead comes from tmpfiles. The recipe's do_install adds, for
# exactly this case:
#
#     L! /etc/resolv.conf - - - - ../run/systemd/resolve/resolv.conf
#     f  /run/systemd/resolve/resolv.conf 0644 root root
#
# so first boot creates /etc/resolv.conf as a symlink to an EMPTY file. The
# type is `L`, not `L+`, and plain `L` does not touch a path that already
# exists — which is what makes the provisioning approach work: a real
# /etc/resolv.conf written onto the card survives, and tmpfiles leaves it be.
#
# So: scripts/provision-card.sh writes /etc/resolv.conf from STATIC_DNS,
# alongside the address. Same product-vs-site argument as the address itself
# (notes/23 §2) — a resolver is a fact about the network the board is
# deployed on, not about the product.
#
# And the honest cost, stated rather than discovered later: without resolved,
# **a DHCP-provided DNS server goes nowhere.** networkd learns it and hands
# it to resolved over D-Bus; with no resolved there is nothing to hand it to
# and nothing writes it to a file. An unprovisioned card therefore gets an
# address from DHCP and is reachable by IP, but cannot resolve names — which
# also means systemd-timesyncd cannot resolve its NTP pool hostnames, and on
# an RTC-less board that means no correct clock. If that fallback ever needs
# to work, the fix is a static NTP server ADDRESS in timesyncd.conf rather
# than a hostname.
#
# ---------------------------------------------------------------------------
# NOT REMOVED, AND WHY
# ---------------------------------------------------------------------------
#   timesyncd   The board has no RTC and its product is timestamped data.
#               Every boot starts in May 2025 until timesync corrects it
#               (notes/23 §10). The question there is WHEN it runs, not
#               whether — a scheduling problem, not a deletion one.
#   networkd    Obviously required.
#   journald    Required, but tunable: Audit=no, SystemMaxUse=, Storage=.
#
# Untested candidates for a later pass, all in poky's default PACKAGECONFIG
# and all implausible on this board: backlight (no screen), hibernate (no
# swap), machined + nss-mymachines (no containers), localed (no keyboard),
# quotacheck (dmesg says "Quota mode: none"), hostnamed, timedated. Each is
# likely worth ~0 s of boot because they are D-Bus-activated and never
# triggered — but each also deletes a unit file systemd currently parses, and
# rootfs bytes.
#
# ---------------------------------------------------------------------------
# SAFETY CHECK THAT DOES NOT FIRE
# ---------------------------------------------------------------------------
# systemd_255.21.bb lines ~820: DISTRO_FEATURES[systemd-resolved] requires
# PACKAGECONFIG[nss-resolve, resolved]. playground.conf appends only "rauc"
# to DISTRO_FEATURES, so the feature is absent and the check cannot fire.
# Independently confirmed on the running board: base-files only patches the
# `resolve` entry into nsswitch.conf when that feature is set, and the
# board's nsswitch.conf says `hosts: files myhostname dns` — no resolve.

PACKAGECONFIG:remove = "vconsole logind resolved nss-resolve userdb"
