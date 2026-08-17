#!/bin/bash
# Recreates the Yocto build environment for this project from scratch.
# Usage:  source scripts/setup-yocto.sh [rpi5|rpi0]
# (must be *sourced*, not executed, so you land inside the build environment)
#
# Session 14 (Phase 6) made this take a target argument. There are now two
# build directories, because there are two boards:
#
#   rpi5  ->  build-rpi5  ->  MACHINE=raspberrypi5        (ARMv8, learning rig)
#   rpi0  ->  build-rpi0  ->  MACHINE=raspberrypi0-wifi   (ARMv6, the product)
#
# They share DL_DIR, SSTATE_DIR and bblayers.conf; they differ in local.conf.
# Defaults to rpi5 so every command in notes/01..18 still works verbatim.

YOCTO_DISK="/media/blankmcu/EmbeddedLinux"
YOCTO_DIR="$YOCTO_DISK/yocto"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="scarthgap"

TARGET="${1:-rpi5}"
case "$TARGET" in
    rpi5|rpi0) ;;
    *)
        echo "ERROR: unknown target '$TARGET'. Use: rpi5 (Pi 5) or rpi0 (Pi Zero W)."
        return 1 2>/dev/null || exit 1
        ;;
esac
BUILD_DIR="$YOCTO_DIR/build-$TARGET"
LOCAL_CONF="$REPO_DIR/conf-templates/local.conf.$TARGET"

# The build disk is a loop-mounted ext4 image — refuse to run without it.
if ! mountpoint -q "$YOCTO_DISK"; then
    echo "ERROR: $YOCTO_DISK is not mounted."
    echo "Run ./scripts/mount-build-disk.sh first."
    return 1 2>/dev/null || exit 1
fi

# Host sanity checks — run scripts/host-setup.sh once if these fail.
if ! command -v gawk >/dev/null || ! command -v chrpath >/dev/null; then
    echo "ERROR: Yocto host packages missing. Run: $REPO_DIR/scripts/host-setup.sh"
    return 1 2>/dev/null || exit 1
fi
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null)" = "1" ]; then
    echo "ERROR: AppArmor blocks user namespaces (breaks BitBake)."
    echo "Run: $REPO_DIR/scripts/host-setup.sh"
    return 1 2>/dev/null || exit 1
fi

mkdir -p "$YOCTO_DIR"/{downloads,sstate-cache}

if [ ! -d "$YOCTO_DIR/poky" ]; then
    git clone -b "$RELEASE" https://git.yoctoproject.org/poky "$YOCTO_DIR/poky" || return 1
fi
if [ ! -d "$YOCTO_DIR/meta-raspberrypi" ]; then
    git clone -b "$RELEASE" https://github.com/agherzan/meta-raspberrypi.git \
        "$YOCTO_DIR/meta-raspberrypi" || return 1
fi

# --- OTA / RAUC layers (session 11) -----------------------------------------
# meta-rauc: the RAUC update client recipe plus bundle.bbclass (which turns
#   an image into a signed .raucb update bundle).
if [ ! -d "$YOCTO_DIR/meta-rauc" ]; then
    git clone -b "$RELEASE" https://github.com/rauc/meta-rauc.git \
        "$YOCTO_DIR/meta-rauc" || return 1
fi
# meta-rauc-community: BSP-specific glue for a dozen boards. We add exactly
#   one sub-layer from it (meta-rauc-raspberrypi) in bblayers.conf — it
#   carries the dual-rootfs wic layout and the U-Boot boot script that
#   implements slot selection and the retry counter.
if [ ! -d "$YOCTO_DIR/meta-rauc-community" ]; then
    git clone -b "$RELEASE" https://github.com/rauc/meta-rauc-community.git \
        "$YOCTO_DIR/meta-rauc-community" || return 1
fi
# meta-lts-mixins: NOT optional for the Pi 5. Scarthgap froze U-Boot at
#   2024.01, which predates usable Raspberry Pi 5 support; this "mixin"
#   layer backports current U-Boot (2025.04) into the LTS. Hence the
#   unusual branch name — the layer has one branch per backported
#   component, not one per Yocto release.
if [ ! -d "$YOCTO_DIR/meta-lts-mixins" ]; then
    git clone -b "$RELEASE/u-boot" https://git.yoctoproject.org/meta-lts-mixins \
        "$YOCTO_DIR/meta-lts-mixins" || return 1
fi

FIRST_TIME=0
[ -d "$BUILD_DIR/conf" ] || FIRST_TIME=1

# Sets up (or re-enters) the build dir and cd's into it
source "$YOCTO_DIR/poky/oe-init-build-env" "$BUILD_DIR"

# On first init, replace the generated configs with our tracked ones.
# bblayers.conf is shared by both targets — the layer SET is the same, only
# the MACHINE differs, and BitBake happily parses layers it ends up not using.
if [ "$FIRST_TIME" = 1 ]; then
    cp "$LOCAL_CONF" "$BUILD_DIR/conf/local.conf"
    cp "$REPO_DIR/conf-templates/bblayers.conf" "$BUILD_DIR/conf/bblayers.conf"
    echo ">>> Installed tracked bblayers.conf + local.conf.$TARGET from $REPO_DIR/conf-templates"
fi

# Standing gotcha, unchanged since session 3: the copy above happens ONLY on
# first init. After editing a template, copy it in by hand:
#   cp $LOCAL_CONF $BUILD_DIR/conf/local.conf
echo ">>> Ready ($TARGET -> $(grep -m1 '^MACHINE' "$BUILD_DIR/conf/local.conf")).  Try:  bitbake core-image-minimal"
