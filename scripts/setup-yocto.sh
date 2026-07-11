#!/bin/bash
# Recreates the Yocto build environment for this project from scratch.
# Usage:  source scripts/setup-yocto.sh
# (must be *sourced*, not executed, so you land inside the build environment)

YOCTO_DISK="/media/blankmcu/EmbeddedLinux"
YOCTO_DIR="$YOCTO_DISK/yocto"
BUILD_DIR="$YOCTO_DIR/build-rpi5"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="scarthgap"

# The build disk is a loop-mounted ext4 image — refuse to run without it.
if ! mountpoint -q "$YOCTO_DISK"; then
    echo "ERROR: $YOCTO_DISK is not mounted."
    echo "Run mount_linux_filesystem.sh from the exFAT drive first."
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

FIRST_TIME=0
[ -d "$BUILD_DIR/conf" ] || FIRST_TIME=1

# Sets up (or re-enters) the build dir and cd's into it
source "$YOCTO_DIR/poky/oe-init-build-env" "$BUILD_DIR"

# On first init, replace the generated configs with our tracked ones
if [ "$FIRST_TIME" = 1 ]; then
    cp "$REPO_DIR/conf-templates/local.conf" "$BUILD_DIR/conf/local.conf"
    cp "$REPO_DIR/conf-templates/bblayers.conf" "$BUILD_DIR/conf/bblayers.conf"
    echo ">>> Installed tracked local.conf and bblayers.conf from $REPO_DIR/conf-templates"
fi

echo ">>> Ready. Try:  bitbake core-image-minimal"
