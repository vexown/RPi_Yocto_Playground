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
# "bootable minimum" core-image-minimal uses; then our additions:
#   dropbear     — ssh server (was: ssh-server-dropbear feature in local.conf)
#   os-release   — /etc/os-release identity (was: IMAGE_INSTALL:append)
#   hello        — our first own recipe, from this very layer
IMAGE_INSTALL = "\
    packagegroup-core-boot \
    dropbear \
    os-release \
    hello \
    "

# No locale packages — same trick core-image-minimal uses to stay small.
IMAGE_LINGUAS = " "

# NOTE what is deliberately NOT here: debug-tweaks (empty root password).
# That is dev-workstation policy, not part of the image's identity, so it
# stays in local.conf's EXTRA_IMAGE_FEATURES — set by whoever builds,
# stripped automatically when someone builds this image "for real".
