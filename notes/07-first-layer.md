# Session 3b — meta-playground: own layer, own recipe, own image

Phase 3, first three items, all in one sitting. The artifacts themselves
are heavily commented (that's where the detail lives); this note is the
map and the "why".

## What was created

```
meta-playground/                      <- in the REPO, not the build disk
├── conf/layer.conf                   <- the layer's "passport" (annotated)
├── recipes-apps/hello/
│   ├── hello_1.0.bb                  <- first hand-written recipe
│   └── files/hello.c                 <- source lives IN the layer
└── recipes-images/images/
    └── playground-image.bb           <- our own image recipe
```

- Scaffolded with `bitbake-layers create-layer meta-playground` (generated
  example recipe deleted; layer.conf kept, annotated).
- Registered in TWO places: live build conf via
  `bitbake-layers add-layer <path>` AND conf-templates/bblayers.conf so a
  fresh checkout reproduces it. Layer priority 6 — between poky's meta (5)
  and meta-raspberrypi (9).

## hello_1.0.bb — lessons baked in

- No build system upstream → hand-written do_compile/do_install; the raw
  mechanics dropbear's `inherit autotools` was hiding.
- ${CC} is the full cross-invocation, not gcc. Proof:
  `file .../image/usr/bin/hello` → "ELF 64-bit ... ARM aarch64" built on x86.
- ${LDFLAGS} in the link is mandatory — omitting it = the classic
  "No GNU_HASH in the ELF binary" do_package_qa failure.
- LIC_FILES_CHKSUM can point at ${COMMON_LICENSE_DIR}/MIT when there's no
  upstream license file.
- Work-tree binary is unstripped "with debug_info"; packaging splits that
  into hello-dbg and strips the shipping binary automatically.
- First build: 843 tasks (toolchain dep tree), 824 from sstate.

## playground-image.bb — image as a recipe

- `inherit core-image` + one IMAGE_INSTALL list = the whole OS definition.
  Moved dropbear + os-release out of local.conf bolt-ons into the recipe.
- **debug-tweaks deliberately stays in local.conf**: empty root password is
  dev-workstation policy, not image identity. EXTRA_IMAGE_FEATURES in
  local.conf still applies to every image built there.
- Result: 28 MB wic.bz2, 37-package manifest including `hello cortexa76 1.0`.
  3810 tasks, only 18 executed (rootfs assembly) — sstate did the rest.
- flash-sd.sh now takes an image name, defaults to playground-image.

## To run it

```bash
./scripts/flash-sd.sh /dev/sdX     # then boot the Pi and:
ssh yocto                          # (IP may change — ip neigh show dev enp6s0)
hello                              # aarch64 says hello
```

**BOOTED 2026-07-12** — `hello` on the Pi 5 printed
`Running on: Linux 6.6.63-v8-16k (aarch64)`: cross-compile proven on
target, full repo→layer→recipe→image→hardware chain closed.

(Flash war story: first attempt died with `dd: fsync failed ... I/O error`
— writes stream into RAM cache at fake ~100 MB/s, the error only surfaces
when fsync forces them onto the card. Reseating the USB reader fixed it.
If it recurs: `sudo dmesg | tail -40` to tell card vs. reader apart;
`f3probe` for counterfeit cards, `badblocks -wsv` for worn ones. Never
boot from a flash run that errored — assume corrupt.)

## The temp/ dir — debugging ground truth (hands-on, 2026-07-12)

Every task leaves a pair in `tmp/work/<arch>/<pn>/<pv>/temp/`:
- `run.do_<task>` — the ACTUAL generated shell script, all variables
  expanded. (Expansion is textual and happens even inside comments —
  our "# ${CC} is..." comment turned into the full compiler line. Proof
  these functions are templates, not parsed shell.)
- `log.do_<task>` — what it printed. Near-empty on success; on failure
  the compiler error is here, and bitbake's console ERROR gives the path.
- `log.task_order` — the sequence tasks really ran in.

What the expanded ${CC}/${CFLAGS}/${LDFLAGS} revealed, flag by flag:
- `-mcpu=cortex-a76+crypto` — from MACHINE via meta-raspberrypi tune files
  (the Pi Zero W build will say arm1176jzf-s; recipe unchanged).
- `--sysroot=.../recipe-sysroot` — per-recipe PRIVATE sysroot containing
  only declared DEPENDS. Missing DEPENDS = "header not found" even if the
  lib was built — deliberate isolation against undeclared deps.
- `-fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wl,-z,relro,-z,now` —
  distro-wide security hardening, free for every recipe.
- `-Wl,--hash-style=gnu` — the literal flag the "No GNU_HASH" QA check
  looks for; carried by ${LDFLAGS}.
- `-fdebug-prefix-map=<workdir>=/usr/src/debug/...` — reproducible builds:
  build-machine paths scrubbed from debug info.

Rebuild-by-hand cheat sheet: `bitbake -c cleansstate hello` (workdir +
sstate, forces real rebuild) then `bitbake hello`. `-c clean` alone is
pointless for this (sstate restores instantly); `-c cleanall` also drops
downloads (rarely wanted).

Remaining Phase 3 item: devtool workflow (modify a recipe's source,
capture the change as a patch).
