# dropbear_%.bbappend — keep the SSH host key across A/B updates.
#
# THE BUG THIS FIXES (found the hard way in session 12, notes/17)
# ---------------------------------------------------------------
# After installing a bundle into slot B and rebooting, ssh said:
#
#     @@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@
#
# Nothing was wrong. The Pi really did have a different host key, because
# dropbear generates one on demand and stores it in /etc/dropbear — which
# is inside the rootfs, and a RAUC install is a raw block write over the
# whole slot. Slot A's key and slot B's key were generated independently and
# have nothing to do with each other, so the board's SSH identity flips back
# and forth with the slot, and every update to a slot throws that slot's key
# away for good.
#
# The general rule, which is the actual lesson and is not specific to ssh:
#
#     ANY state a device generates for itself at runtime and stores in the
#     rootfs is per-slot, and is destroyed by every update.
#
# Same applies to /etc/machine-id, TLS certs, pairing tokens, licence
# activations — the whole class. The answer is never "make the update
# gentler"; it is to move the state off the slot. We already have the place:
# /data (p5), declared to RAUC as `data-directory=/data/` in system.conf and
# untouched by an install precisely because it is not part of either slot.
#
# WHY A BBAPPEND AND NOT A PATCH
# ------------------------------
# Both dropbear units already read the key path from a config file:
#
#     Environment="DROPBEAR_RSAKEY_DIR=/etc/dropbear"     <- the default
#     EnvironmentFile=-/etc/default/dropbear              <- read second
#
# systemd applies EnvironmentFile after Environment, so a line in
# /etc/default/dropbear overrides the compiled-in default, in the generator
# (dropbearkey.service) and the per-connection server (dropbear@.service)
# alike. Upstream left us the seam; we just have to use it. The only thing
# needing a real unit override is the ConditionPathExists pair, and that is
# what files/persistent-host-key.conf is for — see the long comment in it.
#
# WHAT THIS DOES NOT DO
# ---------------------
# It does not migrate the key that already exists on the card. The first
# boot after this update will find no key on /data and make a fresh one, so
# you get the host-key warning ONE more time. After that it is stable
# forever, across both slots. Proving that is the whole point of the test in
# notes/18: note the fingerprint, switch slots, see the same fingerprint.
#
# A migration step (copy /etc/dropbear/* to /data if present) is possible
# but deliberately skipped: it would be dead code on every device built from
# here on, and it hides the one-time break instead of demonstrating it.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://persistent-host-key.conf"

# Where the key lives, for BOTH units, in one line.
#
# We APPEND to poky's /etc/default/dropbear rather than shipping our own
# copy of the file, and that is a deliberate choice. That file is rewritten
# during image assembly by rootfs-postcommands.bbclass: the `allow-root-login`
# / `allow-empty-password` image features (which debug-tweaks turns on for
# us) sed the DROPBEAR_EXTRA_ARGS line to drop `-w` and add `-B`. Shipping
# our own copy would mean silently taking ownership of a file that two other
# mechanisms also edit. Appending an unrelated variable is invisible to
# those seds — they are anchored on ^DROPBEAR_EXTRA_ARGS= — and leaves the
# upstream content the upstream's business.
#
# Note the plain KEY=value with no quotes and no export: this file is parsed
# by systemd's EnvironmentFile, not sourced by a shell. (It is also sourced
# by the sysvinit script in the non-systemd case, where the same syntax is
# still valid, so nothing breaks for a reader who switches INIT_MANAGER.)
do_install:append() {
    printf '\n# Session 13: keep the host key off the rootfs so it survives\n' \
        >> ${D}${sysconfdir}/default/dropbear
    printf '# an A/B update. See meta-playground dropbear_%%.bbappend.\n' \
        >> ${D}${sysconfdir}/default/dropbear
    printf 'DROPBEAR_RSAKEY_DIR=/data/dropbear\n' \
        >> ${D}${sysconfdir}/default/dropbear

    # The drop-in goes in the VENDOR unit directory (/usr/lib/systemd/system),
    # not the admin one (/etc/systemd/system). Both work and systemd merges
    # them in that order, but /etc belongs to whoever is holding the device —
    # leaving it empty means `systemctl cat` shows at a glance which overrides
    # came from the image and which someone added by hand at 2am. This is an
    # image decision, so it ships with the image.
    install -d ${D}${systemd_system_unitdir}/dropbearkey.service.d
    # ${WORKDIR}, not ${UNPACKDIR}: scarthgap still unpacks SRC_URI files
    # straight into WORKDIR. UNPACKDIR is the newer split (styhead onward)
    # and does not exist here — poky's own dropbear.bb uses WORKDIR too.
    install -m 0644 ${WORKDIR}/persistent-host-key.conf \
        ${D}${systemd_system_unitdir}/dropbearkey.service.d/
}

# Required, and a genuine trap. Most recipes get ${systemd_system_unitdir}
# for free, but dropbear does not: systemd.bbclass adds unit files to FILES
# one at a time by parsing SYSTEMD_SERVICE (and following Also=), so
# FILES:dropbear literally lists dropbear.socket, dropbear@.service and
# dropbearkey.service by name. A directory we invent alongside them matches
# nothing, and the build fails at do_package_qa with "installed but not
# shipped" rather than quietly dropping the file — which is the good outcome,
# but only if you know what the message means.
FILES:${PN} += "${systemd_system_unitdir}/dropbearkey.service.d"
