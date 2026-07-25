# Session 10 — the SDK: cross-compiling with no bitbake in sight

Goal: `bitbake -c populate_sdk playground-image`, install the result,
build an app OUTSIDE Yocto, run it on the Pi. VERIFIED 2026-07-25:
sdk-demo/hello-sdk built with plain `make`, linked against OUR image's
libsystemd, ran on target ("PID 1 is systemd").

## The problem it solves

App developers shouldn't need bitbake, the 250 GB disk, or any Yocto
knowledge. But "just apt-get a cross gcc" compiles against UBUNTU's
glibc/libraries, not the image's — binaries that link today, break
after the next OS update. The SDK is a single self-extracting .sh
(~315 MB for us) containing a cross-toolchain + an exact copy of the
image's libraries and headers. OS builder and app developer decouple
completely: rebuild the SDK when the OS changes, hand over one file.

## What's in the box

- HOST sysroot: relocatable x86 cross tools (gcc, binutils, gdb,
  pkg-config). "Cross-canadian": built here, runs on ANY dev PC,
  targets ARM — three machines, hence the (Canadian-parties joke) name.
  This is why the SDK bake rebuilds gcc specially.
- TARGET sysroot: every lib in the image + headers (this is what -dev
  packages are FOR — the feed's less-dev suddenly makes sense).
- environment-setup-cortexa76-poky-linux: sourceable script that fills
  CC/LD/PKG_CONFIG_*... One `source`, and $CC becomes a whole sentence:
  aarch64-poky-linux-gcc -mcpu=cortex-a76+crypto -mbranch-protection
  -fstack-protector-strong -D_FORTIFY_SOURCE=2 --sysroot=<target sysroot>
  (the hardening flags come from poky's security_flags.inc — inherited
  through playground.conf's `require`; our distro choice visible in a
  colleague's compile line).
- Installer defaults to /opt/playground/0.1 — SDKPATHINSTALL =
  /opt/${DISTRO}/${SDK_VERSION}: distro identity again.
- Also generated: .manifest (host+target package lists) and .spdx
  archives (SBOM — poky's create-spdx, compliance paperwork for free).

## The demo (sdk-demo/ in repo)

- hello-sdk.c calls sd_booted() from libsystemd — deliberately: proves
  the target sysroot is OUR image's library set, where a generic apt
  toolchain would die at `systemd/sd-daemon.h: No such file`.
- Makefile is deliberately BORING: only $(CC)/$(CFLAGS)/$(LDFLAGS) +
  pkg-config, no ARM/sysroot/paths anywhere. The same Makefile builds
  native x86 in a plain shell. That contract is what lets app devs
  ignore Yocto.
- file(1) on the result: "ELF 64-bit ARM aarch64, interpreter
  /lib/ld-linux-aarch64.so.1, for GNU/Linux 5.15.0, with debug_info,
  not stripped" — note bitbake normally strips + splits debug into
  -dbg packages at PACKAGE time; a raw SDK build keeps debug info.
- ./hello-sdk on the PC -> "Exec format error" = the HEALTHIEST error
  in cross-compilation: proof it's not a host binary.
- scp + run on Pi: greeting + libsystemd confirms PID 1.

## Gotchas hit

- LD_LIBRARY_PATH: the env-setup script REFUSES to run if it's set.
  Ours came from ROS Jazzy (sourced in ~/.bashrc). LD_LIBRARY_PATH
  globally overrides library search for every dynamic binary — the
  SDK's own relocatable host tools would load ROS's libs. Fix: `unset
  LD_LIBRARY_PATH` in the SDK shell only (per-shell, ROS elsewhere
  unaffected). Toolchain environments are territorial: SDK shell,
  bitbake shell, ROS shell — never share.
- Never source the SDK env in the bitbake terminal (same territory
  rule, other direction).

## Not built (but should be known)

populate_sdk_ext = "extensible SDK": embeds a mini-bitbake so app devs
can build whole recipes + devtool. Bigger, more complex; classic SDK
is the right default handoff.
