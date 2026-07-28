# playground-bundle.bb — the thing we actually ship to a deployed device.
#
# Everything else in this repo builds an IMAGE: a full disk, written to a
# blank SD card by a human holding the card. That doesn't scale past one
# device and can't happen at all once the Pi Zero W is glued into a box on
# a shelf. A BUNDLE is the answer: one signed file you hand to a running
# device, which it writes into its spare rootfs slot.
#
# Build it with:  bitbake playground-bundle
# Result:         tmp/deploy/images/raspberrypi5/playground-bundle-*.raucb
#
# What's inside a .raucb: a squashfs container holding
#   * manifest.raucm  — compatible string, version, which slot each image
#                       targets, and the images' hashes
#   * rootfs.ext4     — the payload (our whole root filesystem, ~100+ MB)
#   * a detached CMS signature over the whole thing
# `rauc info bundle.raucb` on either host or target prints all of it.

SUMMARY = "RAUC update bundle for the playground image"
LICENSE = "MIT"

# bundle.bbclass (from meta-rauc) does all the work: it depends on the
# named image recipes, collects their filesystem artifacts out of
# DEPLOY_DIR_IMAGE, writes the manifest, and shells out to rauc-native to
# sign and pack. Same pattern as core-image: inherit, then declare data.
inherit bundle

# --- Identity ---------------------------------------------------------------
# MUST match /etc/rauc/system.conf's "compatible" on the target, which our
# rauc-conf.bbappend derives from the same two variables. Mismatch =>
# `rauc install` aborts before writing a single byte. That check is the
# reason you cannot brick a Pi Zero W by handing it the Pi 5's firmware.
RAUC_BUNDLE_COMPATIBLE = "${DISTRO}-${MACHINE}"

# Free-form; shows up in `rauc status` and `rauc info`. Deliberately NOT
# equal to DISTRO_VERSION (0.1) so that after installing we can see at a
# glance that the running slot holds something newer than what we flashed.
RAUC_BUNDLE_VERSION = "0.2-ota-demo"
RAUC_BUNDLE_DESCRIPTION = "Playground A/B update bundle"

# "verity" is the modern bundle format: the payload carries a dm-verity
# hash tree, so the target can verify blocks as it reads them and can even
# stream an update straight from HTTP without staging the whole file on
# disk first. (The older "plain" format hashes the entire bundle up front,
# which needs somewhere to put it — awkward on a small device.) This is
# why meta-rauc-raspberrypi's kernel fragment turns on CONFIG_DM_VERITY.
RAUC_BUNDLE_FORMAT = "verity"

# --- Payload ----------------------------------------------------------------
# One slot class, "rootfs", matching [slot.rootfs.0] / [slot.rootfs.1] in
# system.conf. RAUC picks whichever of the two is INACTIVE at install time.
#
# The kernel rides along for free, which is easy to get wrong: look at the
# boot script (meta-rauc-raspberrypi/recipes-bsp/rpi-u-boot-scr/boot.cmd.in)
# and you'll see it set BOOT_DEV to "mmc 0:2" or "mmc 0:3" — the ROOTFS
# partition of the chosen slot — and then `load ${BOOT_DEV} ... boot/Image`.
# So U-Boot reads the kernel out of the slot's own /boot, and a bundle that
# replaces the rootfs replaces its kernel too. (Verified on the card: the
# copy of Image sitting in the FAT partition is deployed by IMAGE_BOOT_FILES
# but never actually booted from.)
#
# What genuinely stays shared, outside both slots, is everything the Pi's
# firmware touches before U-Boot exists: config.txt, cmdline.txt, the device
# tree and our overlays, the GPU firmware blobs — and U-Boot itself. Change
# any of those and you still need physical access to the card. Updating a
# bootloader over the air is the genuinely dangerous case (a half-written
# bootloader is an unbootable board), which is why it usually gets its own
# redundancy scheme or is simply declared out of scope.
RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "playground-image"
RAUC_SLOT_rootfs[fstype] = "ext4"

# --- Signing ----------------------------------------------------------------
# RAUC_KEY_FILE and RAUC_CERT_FILE are absolute host paths set in
# conf-templates/local.conf, pointing at the untracked key directory that
# scripts/rauc-gen-keys.sh creates. Here bundle.bbclass passes them
# straight to `rauc bundle --key= --cert=`.
#
# RAUC_KEYRING_FILE is set only in this recipe, never globally: in
# bundle.bbclass it is an absolute path used to verify the bundle we just
# signed, but in rauc-conf.bb the same variable name means a WORKDIR-
# relative filename. Setting it in local.conf would break the image build.
RAUC_KEYRING_FILE = "/media/blankmcu/EmbeddedLinux/yocto/rauc-keys/ca.cert.pem"
