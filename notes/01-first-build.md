# Session 1 — Host setup and first build (2026-07-11)

## What we set up

- Host: Ubuntu 24.04, 24 cores, 31 GB RAM.
- Build disk: `/media/blankmcu/EmbeddedLinux` — a 250 GB ext4 image
  loop-mounted from the exFAT SSD partition. Yocto needs a real POSIX
  filesystem (hardlinks/xattrs), so building on exFAT directly would fail.
- Ubuntu 24.04 gotcha: AppArmor blocks unprivileged user namespaces by
  default, which BitBake needs for its network-isolation sandbox.
  Fixed permanently via `/etc/sysctl.d/60-yocto-userns.conf`.
- Cloned `poky` and `meta-raspberrypi`, branch `scarthgap` (Yocto 5.0 LTS,
  supported until 2028, first LTS with Raspberry Pi 5 support).

## Key concepts (book ch. 6)

- **Poky** = the reference distribution: BitBake + OpenEmbedded-Core +
  metadata. Not a distro you install — a kit that builds one.
- **BitBake** = task scheduler. Reads recipes, builds a dependency graph of
  *tasks* (fetch, unpack, patch, configure, compile, install, package),
  runs them massively parallel.
- **Recipe (`.bb`)** = instructions to build one piece of software.
- **Layer (`meta-*`)** = a collection of recipes/configs with a theme
  (BSP layer, distro layer, software layer). `bblayers.conf` lists them.
- **MACHINE** = the hardware target (`raspberrypi5`). Set in `local.conf`.
- **Image recipe** (`core-image-minimal`) = a recipe whose output is a
  bootable rootfs/SD-card image instead of a package.
- **sstate-cache** = memoization of task outputs. First build: hours.
  Subsequent builds: only what changed.

## Commands learned

```bash
source scripts/setup-yocto.sh        # enter build env (wraps oe-init-build-env)
bitbake core-image-minimal           # build the image
```

## Output

Flashable image lands in:
`build-rpi5/tmp/deploy/images/raspberrypi5/core-image-minimal-raspberrypi5.rootfs.wic.bz2`

## Build result (first run)

- 3729 tasks, all succeeded, ~62 GB used on the build disk.
- Image: 28 MB compressed .wic — an entire bootable Linux in less space
  than a single browser tab. That's what "minimal" means: 31 packages
  (see the .manifest file next to the image), busybox provides almost
  all userspace, sysvinit as init, no ssh server, no package manager.
- The .manifest file lists every package in the rootfs — first place to
  look when asking "why is my image big / what's even in here?".
- The .bmap file maps which blocks are actually used, so `bmaptool` can
  flash faster than dd by skipping empty space (we use dd for now).

## Gotchas hit

- Ubuntu 24.04 AppArmor userns restriction (see host-setup.sh).
- `BB_DISKMON_DIRS` action `ABORT` (book-era syntax) renamed to `HALT`
  in Yocto 4.0 — the book targets Dunfell 3.1, we run Scarthgap 5.0;
  expect small syntax drift like this and read the WARNING lines.
- Flashing: image goes to the whole device (/dev/sdX), never a
  partition — the .wic already contains the partition table.
