# hello_1.0.bb — our first hand-written recipe.
# Filename convention <name>_<version>.bb sets PN=hello, PV=1.0 for free.
#
# Compare with dropbear_2022.83.bb (notes/05): that one inherits autotools
# and gets do_configure/do_compile/do_install for free. Our program has no
# build system at all — one .c file — so we write do_compile and do_install
# by hand. That makes this the best recipe for seeing the raw mechanics.

SUMMARY = "Hello-world proving out our meta-playground layer"
HOMEPAGE = "https://github.com/vexown/RPi_Yocto_Playground"

# Every recipe MUST declare a license and checksum the license text
# (build fails if the text ever changes — license compliance by force).
# We have no upstream tarball with a LICENSE file, so we point at the
# generic MIT text that poky ships for exactly this purpose.
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# file:// = fetch from the layer itself. BitBake searches next to the
# recipe in files/, ${PN}/, ${PN}-${PV}/ (see FILESPATH). do_unpack copies
# it into ${WORKDIR}.
SRC_URI = "file://hello.c"

# S = source directory, where tasks after do_unpack expect to work.
# Default is ${WORKDIR}/${PN}-${PV} (where a tarball would extract) — but a
# lone file:// lands directly in ${WORKDIR}, so we point S there.
S = "${WORKDIR}"

do_compile() {
    # ${CC} is NOT plain gcc: it's the full cross-compiler invocation
    # (aarch64-poky-linux-gcc + sysroot + tuning flags). Run
    # `bitbake -e hello | grep '^export CC='` to see the real value.
    #
    # ${LDFLAGS} matters more than it looks: Yocto's QA check insists
    # binaries carry the distro's link flags (e.g. GNU_HASH sections).
    # Forget it and the build fails do_package_qa with "No GNU_HASH in the
    # ELF binary" — the classic first-recipe error, now pre-avoided.
    ${CC} ${CFLAGS} ${LDFLAGS} ${S}/hello.c -o hello
}

do_install() {
    # ${D} = fake install root ("destdir"). We install into ${D}${bindir}
    # on the PC; packaging then turns that tree into the .rpm; only the
    # package's contents ever reach the Pi. Never install to real paths.
    # ${bindir} = /usr/bin — always variables, never hardcoded paths.
    install -d ${D}${bindir}
    install -m 0755 ${B}/hello ${D}${bindir}/hello
}
