# rauc-conf.bbappend — we take ownership of /etc/rauc/.
#
# meta-rauc's rauc-conf.bb is a tiny recipe that installs exactly two files:
#   /etc/rauc/system.conf   — slot layout + bootloader + compatible string
#   /etc/rauc/ca.cert.pem   — the trust anchor for bundle verification
# and warns loudly if you left its commented-out placeholders in place.
#
# meta-rauc-community/meta-rauc-raspberrypi ships its own bbappend supplying
# BSP versions of both files (with the community's DEMO private key's CA).
# We want ours instead — our slot definitions, our CA. Two bbappends both
# prepending to FILESEXTRAPATHS and both adding file://ca.cert.pem to
# SRC_URI would make "which file wins" depend on layer parse order, which
# is exactly the kind of non-reproducibility this repo exists to avoid.
#
# So conf-templates/local.conf BBMASKs the community's rauc-conf.bbappend
# and this file replaces it outright. BBMASK is the standard tool for
# surgically disabling one file from a third-party layer you otherwise want
# — cleaner than forking the layer, and visible in one tracked line.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# ca.cert.pem is picked up automatically: rauc-conf.bb has
# RAUC_KEYRING_FILE ??= "ca.cert.pem" and SRC_URI += file://${RAUC_KEYRING_FILE},
# so dropping our copy in files/ is the whole override. Careful: that
# variable means a WORKDIR-relative filename here, but an absolute host path
# in bundle.bbclass — same name, two meanings. We therefore never set it
# globally in local.conf, only inside playground-bundle.bb.

do_install:prepend() {
    # The image must describe itself with the same compatible string the
    # bundle is stamped with (see playground-bundle.bb) or every install is
    # rejected with "Compatible mismatch". Deriving both from
    # ${DISTRO}-${MACHINE} means they cannot silently drift apart.
    sed -i "s/@@COMPATIBLE@@/${DISTRO}-${MACHINE}/g" ${WORKDIR}/system.conf
}
