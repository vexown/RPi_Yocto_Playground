# Session 2b — Reading real recipes: the dropbear "-B" trace

Question we answered: "why is dropbear running with -B on my Pi?"
The chain, fully traced through the metadata:

1. **core-image-minimal.bb** (poky/meta/recipes-core/images/) — the whole
   image is ~10 lines: `IMAGE_INSTALL = "packagegroup-core-boot ..."` plus
   `inherit core-image`. All image mechanics live in the inherited class.
2. Our local.conf adds `ssh-server-dropbear` + `debug-tweaks` to
   IMAGE_FEATURES → core-image.bbclass translates the ssh feature into
   "install the dropbear package".
3. **dropbear_2022.83.bb** builds dropbear and installs its sysvinit
   script; that init script sources `/etc/default/dropbear` for extra args.
4. **rootfs-postcommands.bbclass** — because IMAGE_FEATURES contains
   debug-tweaks, the rootfs-assembly step runs `ssh_allow_empty_password`,
   which writes `DROPBEAR_EXTRA_ARGS=-B` into /etc/default/dropbear
   *inside the image* (and would patch sshd_config if OpenSSH were used).
   → the -B seen in `ps` on the target. Verify: `cat /etc/default/dropbear`.

Lesson: behavior = recipe + classes + image features + postprocessing.
grep across poky/meta is how you find which layer of that stack did it.

## Recipe anatomy (dropbear_2022.83.bb as the specimen)

- **Naming**: `<name>_<version>.bb` → PN=dropbear, PV=2022.83.
- **Metadata**: SUMMARY/HOMEPAGE/SECTION; LICENSE + LIC_FILES_CHKSUM
  (checksum of the LICENSE file — build FAILS if upstream changes their
  license text; that's license compliance built into the build).
- **DEPENDS** = build-time deps (zlib headers to compile against).
  **RDEPENDS/RPROVIDES/RCONFLICTS** = runtime package relations
  (dropbear RPROVIDES "ssh sshd", RCONFLICTS with openssh — two packages
  can't both claim the ssh role).
- **SRC_URI**: upstream tarball + local patches + aux files (init script,
  systemd units). `SRC_URI[sha256sum]` pins the tarball. The CVE-*.patch
  files are backported security fixes — this is what "maintained LTS
  release" means concretely.
- **inherit autotools update-rc.d systemd update-alternatives** — classes
  are reusable build logic. `autotools` alone provides configure/compile/
  install task implementations (that's why there's no do_compile here).
- **PACKAGECONFIG**: per-recipe on/off switches with the four-part value
  `--enable-flag,--disable-flag,build-deps,runtime-deps`. Overridable
  from local.conf, e.g. PACKAGECONFIG:append:pn-dropbear = " enable-x11-forwarding".
- **do_install** (+ `:append` on do_configure): shell run in a sandbox.
  ${D} = fake destination root; ${WORKDIR} = unpacked sources; ${B} =
  build dir. Never absolute host paths — variables like ${sysconfdir}
  keep it relocatable.
- **CONFFILES** marks /etc/default/dropbear as user-editable config
  (package upgrades won't clobber it).

## Inspection commands (host, inside build env)

- `bitbake-layers show-recipes "*ssh*"` — which layers offer what recipe.
- `bitbake -e dropbear | grep "^SRC_URI="` — final expanded value of any
  variable after all layers/appends/overrides. THE debugging tool.
- `oe-pkgdata-util list-pkg-files dropbear` — files a built package ships.
- `oe-pkgdata-util find-path /usr/sbin/dropbear` — reverse: file → package.
