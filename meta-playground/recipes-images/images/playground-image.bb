# playground-image.bb — our own image recipe.
#
# Until now we bolted things onto core-image-minimal from local.conf
# (EXTRA_IMAGE_FEATURES, IMAGE_INSTALL:append). That works but scales
# badly: local.conf is per-build-directory scratch config. An image
# recipe states "this is what my OS is" in one tracked, buildable file.
#
# Compare with poky's core-image-minimal.bb — same shape, ~10 lines.
# All the heavy lifting (rootfs assembly, wic imaging, manifest writing)
# comes from the inherited class.

SUMMARY = "Playground image: minimal boot + ssh + our own packages"
LICENSE = "MIT"

# core-image.bbclass = image.bbclass + the IMAGE_FEATURES vocabulary
# (ssh-server-dropbear, debug-tweaks, ...). Every image recipe inherits it.
inherit core-image

# The one line that defines the OS. packagegroup-core-boot is the same
# "bootable minimum" core-image-minimal uses (and it follows
# VIRTUAL-RUNTIME_init_manager — so the INIT_MANAGER flip in local.conf
# is what swaps busybox-init for systemd in here); then our additions:
#   dropbear         — ssh server (was: ssh-server-dropbear feature in local.conf)
#   os-release       — /etc/os-release identity (was: IMAGE_INSTALL:append)
#   hello            — our first own recipe, from this very layer
#   playground-pulse — session 7: our systemd unit (LED heartbeat at boot)
#   systemd-analyze  — boot-time profiler; capstone recon tool
#   rauc             — session 11: the OTA update client. The distro says
#                      "this OS supports RAUC" (DISTRO_FEATURES); this line
#                      is what actually puts the `rauc` command on the
#                      target. It pulls in u-boot-fw-utils with it, because
#                      flipping the boot slot means writing U-Boot's
#                      environment from Linux (fw_setenv).
IMAGE_INSTALL = "\
    packagegroup-core-boot \
    dropbear \
    os-release \
    hello \
    playground-pulse \
    systemd-analyze \
    rauc \
    "

# Session 9: give the image a package manager. Surprise: there isn't one
# by default! Yocto USES a package manager (dnf, on the build host) to
# ASSEMBLE the rootfs from the .rpms in tmp/deploy/rpm/, then normally
# ships an image with no way to install anything — embedded devices
# usually don't apt-get. This feature keeps dnf+rpm ON the target
# (FEATURE_PACKAGES_package-management -> ROOTFS_PKGMANAGE in
# image.bbclass), which drags in python3 — the image gets visibly
# bigger. That's the trade: field-updatable packages vs footprint.
# Where the target LOOKS for packages is not identity, it's environment
# -> PACKAGE_FEED_URIS lives in local.conf, not here and not the distro.
IMAGE_FEATURES += "package-management"

# No locale packages — same trick core-image-minimal uses to stay small.
IMAGE_LINGUAS = " "

# NOTE what is deliberately NOT here: debug-tweaks (empty root password).
# That is dev-workstation policy, not part of the image's identity, so it
# stays in local.conf's EXTRA_IMAGE_FEATURES — set by whoever builds,
# stripped automatically when someone builds this image "for real".
