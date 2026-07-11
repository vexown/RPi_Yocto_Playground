# Session 1b — What's actually inside core-image-minimal?

The authoritative answer lives next to every image Yocto builds, in the
**manifest** file (one line per package: name, architecture, version):

```
build-rpi5/tmp/deploy/images/raspberrypi5/core-image-minimal-raspberrypi5.rootfs.manifest
```

Ours has 31 packages. Grouped by job:

## The C library — the foundation
- **libc6** — glibc, the GNU C library. Every dynamically linked program
  talks to the kernel through it. Biggest single item in the rootfs.
- **ldconfig** — maintains the shared-library cache so the dynamic linker
  finds .so files fast.

## Userspace — almost all of it is one program
- **busybox** — THE embedded Linux workhorse. A single ~1 MB binary that
  implements ~300 Unix utilities (sh, ls, cp, mount, vi, ps, grep, dmesg,
  ifconfig, ...) as "applets". Every command is a symlink to the busybox
  binary; it checks argv[0] to know which applet to run. Full GNU
  coreutils + bash + util-linux would be ~10× the size — busybox trades
  obscure options for tiny footprint. `ls -l /bin` on the target makes
  this visible: nearly everything points at /bin/busybox.
- **busybox-syslog** — busybox's little syslog daemon (log collector).
- **busybox-udhcpc** — busybox's DHCP client (gets an IP on eth0).

## Init — the first process, PID 1
- **sysvinit** — the classic "System V" init. The kernel starts exactly one
  userspace process; this is it. It reads **/etc/inittab** (package
  sysvinit-inittab) which says what to run at each runlevel, then executes
  the scripts in /etc/rcN.d/ (package **initscripts**) to mount
  filesystems, set the hostname, start daemons, and finally spawns getty
  for a login prompt.
- **sysvinit-pidof**, **init-system-helpers-service**, **update-rc.d** —
  helpers for managing those rc scripts.
- **ttyrun** — makes sure a getty only runs on consoles that exist.
- Desktop Linux replaced sysvinit with **systemd** years ago; small
  embedded systems often still use sysvinit or busybox-init because
  they're tiny and auditable. Yocto lets you switch to systemd with two
  lines in a distro config — later exercise.

## Hardware & kernel plumbing
- **eudev** — standalone fork of udev: watches the kernel announce devices
  and creates /dev nodes dynamically (the book's ch. 5 "A better way of
  managing device nodes").
- **kmod / libkmod2 / modutils-initscripts** — load kernel modules
  (modprobe, insmod) and auto-load them listed in /etc/modules at boot.
- **kbd / keymaps** — console keyboard layout support.

## System skeleton & networking
- **base-files** — the empty directory tree (/etc, /var, /home...) and
  stock files like /etc/profile, /etc/fstab.
- **base-passwd** — canonical /etc/passwd and /etc/group (root, daemon...).
- **netbase** — /etc/protocols, /etc/services (names for TCP/UDP ports).
- **init-ifupdown** — /etc/network/interfaces handling (ifup/ifdown).

## Libraries pulled in by the above
- **libcrypto3, openssl-conf, openssl-ossl-module-legacy** — OpenSSL's
  crypto library (kmod links against it for module signature support).
- **liblzma5, libz1** — compression libs (kernel modules are compressed).
- **libblkid1** — identifies filesystems on block devices (used at mount).
- **update-alternatives-opkg** — manages "alternatives" symlinks, e.g.
  letting a full GNU tool override a busybox applet if both are installed.

## The one that isn't software at all
- **packagegroup-core-boot** — an empty *meta-package*: just a list of
  dependencies that says "this is what 'a bootable console system' means".
  core-image-minimal installs this one group, and everything above came
  in as its dependencies. Recipe to read:
  poky/meta/recipes-core/packagegroups/packagegroup-core-boot.bb

## Notable ABSENCES (this is the point of "minimal")
- No ssh server, no package manager on the target, no compiler, no
  Python, no systemd, no man pages, not even a real /bin/bash — "sh" is
  busybox's ash shell.

## Other ways to inspect an image (for later)
- `oe-pkgdata-util list-pkg-files <pkg>` — which files a package ships.
- `bitbake -g core-image-minimal` — dumps dependency graphs to .dot files.
- `INHERIT += "buildhistory"` in local.conf — records manifests, sizes and
  diffs for every build in a git repo; great for "what grew my image?".
