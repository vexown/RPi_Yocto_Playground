# Session 2 — Image customization + SSH (2026-07-11, evening)

## What changed and how (all via tracked local.conf, no recipes touched)

- `EXTRA_IMAGE_FEATURES += ssh-server-dropbear` → dropbear SSH server
- `IMAGE_INSTALL:append = " os-release"` → /etc/os-release now exists
- `CMDLINE:append = " console=tty1"` → kernel logs on HDMI (last console= wins)
- Rebuild: 3793 tasks, only 81 executed — sstate replayed the rest.
  Manifest went 31 → 36 packages.

## Workflow upgrades

- Router-less networking: NetworkManager `pi-share` connection on enp6s0
  (ipv4.method=shared). PC = 10.42.0.1, DHCP + NAT over WiFi. Pi found
  via `ip neigh show dev enp6s0` (Raspberry Pi MAC prefix d8:3a:dd).
- `ssh root@10.42.0.174` — straight in (debug-tweaks blank password;
  dropbear runs with -B "allow blank" flag, visible in ps output).
- SSH host alias "yocto" added to ~/.ssh/config on the host.

## Live observations from the target

- `ps` shows the whole truth: PID 1 is `init [5]` (sysvinit, runlevel 5).
  ~120 [bracketed] entries are KERNEL THREADS (workers, per-CPU helpers,
  IRQ handlers — note 8 kswapd/kcompactd: the 4 P-cores... no, 4 cores
  but 8 NUMA-ish zones on the 2712; details later). Actual USERSPACE is
  ~10 processes: udevd, udhcpc (our DHCP lease), dropbear (listener +
  one child per SSH session), syslogd, klogd, two gettys (tty1 + serial
  ttyAMA10), start_getty wrapper, login shell.
- `head -20` FAILS on busybox: applets accept `head -n 20` only — the
  size-for-features tradeoff made tangible.
- `ping google.com` from the Pi: ttl=112, ~10.6 ms — through the
  PC's NAT and WiFi. Full internet on a 36-package OS.

## Still open

- Poky login WARNING banner reminds us: build our own distro later (Phase 5).
