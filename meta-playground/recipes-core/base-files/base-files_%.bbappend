# base-files_%.bbappend — undo someone else's fstab, for one machine only.
#
# THE BUG THIS FIXES (found in session 14, before it ever reached hardware):
#
# meta-rauc-community/meta-rauc-raspberrypi ships its own base-files
# bbappend. All it contains is:
#
#     FILESEXTRAPATHS:prepend:rpi := "${THISDIR}/files:"
#     dirs755 += "/data"
#
# ...and a files/fstab next to it that mounts /dev/mmcblk0p5 on /data and
# /dev/mmcblk0p6 on /home. That is correct for the Pi 5, whose RAUC A/B
# .wks really does create those partitions. But the append is scoped ":rpi"
# — the SoC FAMILY, from SOC_FAMILY="rpi" in rpi-base.inc via
# soc-family.inc — and the Pi Zero W is in that family too. So a layer we
# added in session 11 for the Pi 5's OTA silently rewrote the Zero W's
# fstab four months later.
#
# The consequence is not a build error. It builds clean and produces a
# working-LOOKING .wic. On first boot systemd waits for two block devices
# that a two-partition card will never have, hits the 90 s default
# DefaultDeviceTimeoutSec on each, fails local-fs.target and drops to an
# emergency shell — on a headless board with no serial adapter attached.
#
# WHY THIS FILE WINS, AND WHY IT IS NOT A PRIORITY FIGHT:
#
# The instinct is to out-prioritise them. That does not work here: both
# meta-playground and meta-rauc-raspberrypi are BBFILE_PRIORITY 6, and
# raising ours would be a fragile answer anyway — two ":prepend"s racing
# on parse order.
#
# The real mechanism is in base_set_filespath()
# (poky/meta/classes-global/utils.bbclass:277). It builds FILESPATH
# OVERRIDE-MAJOR, not path-major, and it reverses the override list first:
#
#     overrides = (":" + FILESOVERRIDES).split(":")
#     overrides.reverse()
#     for o in overrides:          <-- outer loop: the override
#         for p in path:           <-- inner loop: every layer's files dir
#             filespath.append(os.path.join(p, o))
#
# So EVERY layer's files/<machine>/ is searched before ANY layer's plain
# files/. And ${MACHINE} is always the most specific override available:
# FILESOVERRIDES contains MACHINEOVERRIDES, MACHINEOVERRIDES is seeded
# "?= ${MACHINE}" in bitbake.conf:816 and every layer only ever PREPENDS to
# it with "=.", so the bare machine name stays last in the string — which
# the reverse() turns into first-searched.
#
# Net effect: files/raspberrypi0-wifi/fstab beats files/fstab from anywhere,
# for that machine, permanently. No BBMASK, no priority bump, and the Pi 5
# is untouched — it still gets the rauc layer's fstab, which is the right
# one for its five-partition card.
#
# Note the "%" in the filename: it matches any base-files version, so a
# poky upgrade from 3.0.14 to whatever comes next doesn't silently orphan
# this append. (An orphaned bbappend is normally a hard parse error, which
# is a mercy — but only if you notice which recipe went away.)
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# FILESEXTRAPATHS is unscoped on purpose. Adding a search path costs
# nothing on machines that have no subdirectory in it — the Pi 5 looks in
# files/raspberrypi5/, finds nothing, and moves on. The SCOPING is done by
# the directory name, which is more honest than an override on the
# variable: the fstab that only applies to one machine lives in a
# directory named after that machine.
