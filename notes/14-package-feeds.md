# Session 9 — package feeds: dnf install onto the running Pi

Goal: runtime package management — add software to the deployed device
over the network, no reflash. VERIFIED 2026-07-25: `dnf install less`
on the Pi, served from the PC over the pi-share cable; GNU less 643
took over /usr/bin/less from busybox via update-alternatives.

## The realization that makes it all click

Every build we ever ran already produced a full rpm repository:
tmp/deploy/rpm/ is not a byproduct, it's the PRIMARY product.
`bitbake playground-image` is two acts: (1) build all packages into
that repo, (2) run dnf ON THE BUILD HOST to install them into a folder
that becomes the rootfs. Yocto was a package-feed system all along —
an image is a frozen snapshot of one dnf run.

This session pulled the two acts apart: build the rpm on the PC now,
install it on the running Pi later. The only new thing is the cable.

Corollary: there is no Playground Corporation build farm. dnf never
compiles — it only downloads rpms somebody built earlier. On Ubuntu
that somebody is Canonical; for our OS it's this PC. `bitbake less` =
playing Canonical for one package.

## The pieces

- rpm/dnf = the Red Hat lineage's dpkg/apt. Same two-layer stack:
  rpm (install one archive, no network) + dnf (index download, dep
  resolution, fetch). PACKAGE_CLASSES = "package_rpm" picked the
  lineage back in session 1; package_deb / package_ipk (opkg) are the
  alternatives.
- IMAGE_FEATURES += "package-management" (playground-image.bb): keeps
  dnf+rpm on the target. NOT default — embedded images normally ship
  with no way to install anything. Cost: drags in python3, image grows.
- PACKAGE_FEED_URIS = "http://10.42.0.1:8000/rpm" (local.conf, NOT the
  distro/image — the feed URL is deployment environment, not OS
  identity; session 8's boundary drawn the other way). Baked into
  /etc/yum.repos.d/oe-remote-repo-rpm.repo at rootfs time, gpgcheck=0
  since we don't sign.
- `bitbake less`: bitbake's unit is the RECIPE, not the image. Runs
  fetch->compile->do_package_write_rpm, drops rpms in tmp/deploy/rpm/
  cortexa76/ (machine tune arch, not generic aarch64). One recipe ->
  many packages: less, -doc, -dev, -dbg, -src, -ptest (splitting).
- `bitbake package-index`: recipe with no source; runs createrepo over
  tmp/deploy/rpm -> repodata/ (compressed XML: names, versions, deps,
  checksums — what `apt update` downloads in the other lineage). The
  index is a SNAPSHOT: rpms built after the last package-index run are
  invisible to dnf. Always re-run it last.
- Serving = python3 -m http.server 8000 in tmp/deploy. dnf's requests
  show up as GET lines. First failure mode of the day: "Couldn't
  connect ... after 0 ms" = connection refused = nobody listening —
  the shop was never opened. ss -tln | grep :8000 on the host settles
  it in one line.

## busybox vs the real thing (update-alternatives)

`less` already existed on the target before the install — BusyBox's
applet ("BusyBox v1.36.1 multi-call binary" banner). Busybox is one
binary impersonating ~200 tools via argv[0]; most of the image's
/usr/bin is symlinks into it. Collision handling: busybox registers
its names with update-alternatives at LOW priority; the real package's
%post scriptlet (visible in the dnf transcript!) registers
/usr/bin/less.less at priority 100 and takes over the symlink.
After install: less --version -> "less 643", which less ->
/usr/bin/less -> /usr/bin/less.less. Remove the rpm and the link falls
back to busybox automatically.

## Caveats for real life

- Feed and image are version-locked siblings from the same build
  state; serving a newer feed to an older image invites dependency
  mismatches. Rebuild image + feed together.
- The three-command incantation (bitbake <pkgs>; bitbake image;
  bitbake package-index) is tribal knowledge — the production fix is a
  packagegroup recipe listing feed contents (a package that is only a
  dependency list — same archetype as packagegroup-core-boot), then CI
  runs one bitbake line. Possible bonus exercise later.
- Unsigned feed + http = fine on a lab cable, unacceptable in
  production (PACKAGE_FEED_SIGN exists for that).

## Capstone relevance

The Pi Zero W logger probably won't ship dnf (footprint), but the
feed workflow is how we'll iterate on its packages without reflashing
during development — and devtool deploy-target (session 4) is the
even faster inner loop for code we're actively editing.
