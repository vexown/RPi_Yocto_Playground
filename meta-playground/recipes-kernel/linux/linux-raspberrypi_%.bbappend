# linux-raspberrypi_%.bbappend — our additions to meta-raspberrypi's
# kernel recipe, WITHOUT touching their layer. A .bbappend is applied on
# top of the .bb of the same name; every layer can stack one (order =
# layer priority). The "%" is a wildcard matching any version, so this
# survives the BSP bumping 6.6 -> 6.12. (Trade-off: pinning to a version
# fails loudly on upgrades instead — some teams prefer that.)
#
# NOTE the directory matters: recipes-kernel/linux/ must MIRROR where the
# original recipe lives in meta-raspberrypi, because our layer.conf BBFILES
# glob is what finds this file.

# By default the recipe only searches ITS OWN layer for file:// sources.
# FILESEXTRAPATHS prepends our files/ dir to that search path.
# ":=" = expand immediately (THISDIR must resolve NOW, while this file is
# being parsed, not later when THISDIR means something else).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# A .cfg in a kernel recipe's SRC_URI is a CONFIG FRAGMENT: merged onto
# the kernel config at do_configure. Same mechanism meta-raspberrypi
# itself uses (see default-cpu-governor.cfg in their linux-raspberrypi.inc).
# Fragments beat editing defconfig: each is a small named statement of
# intent, they compose, and a kernel version bump rarely conflicts.
#
# ikconfig.cfg: expose the running kernel's config at /proc/config.gz
# (CONFIG_IKCONFIG + CONFIG_IKCONFIG_PROC) — captured from menuconfig
# via `bitbake -c diffconfig virtual/kernel`.
SRC_URI += "file://ikconfig.cfg"
