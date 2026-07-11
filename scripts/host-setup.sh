#!/bin/bash
# One-time host preparation for Yocto builds (Ubuntu 24.04).
# Run directly (it uses sudo internally):  ./scripts/host-setup.sh
# Safe to re-run; everything is idempotent.
set -e

# Host packages required by the Yocto Project (Scarthgap) on Ubuntu, per
# https://docs.yoctoproject.org/5.0/ref-manual/system-requirements.html
sudo apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc g++ make chrpath socat cpio \
    python3 python3-pip python3-pexpect python3-git python3-jinja2 \
    python3-subunit xz-utils debianutils iputils-ping zstd liblz4-tool \
    file locales libacl1

# Ubuntu 23.10+ restricts unprivileged user namespaces via AppArmor, which
# breaks BitBake's network-isolation sandbox ("User namespaces are not usable
# by BitBake"). Allow them, persistently and immediately.
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' \
    | sudo tee /etc/sysctl.d/60-yocto-userns.conf >/dev/null
sudo sysctl -q kernel.apparmor_restrict_unprivileged_userns=0

echo ">>> Host ready for Yocto builds."
