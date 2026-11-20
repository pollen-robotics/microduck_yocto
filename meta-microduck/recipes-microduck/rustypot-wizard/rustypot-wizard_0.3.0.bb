SUMMARY = "TUI configurator for Dynamixel and Feetech servos"
DESCRIPTION = "rustypot_wizard, Pollen's servo setup tool: scan a bus, read and \
write registers, change IDs and baud rates. On the robot it talks to the motor \
bus at /dev/ttyS2, which the microduck account reaches through dialout; stop \
robotd first, since it holds the port."
HOMEPAGE = "https://github.com/pollen-robotics/rustypot_wizard"
# Cargo.toml says Apache-2.0; the repository carries no LICENSE file, so the
# checksum is oe-core's copy of the text.
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# The release's own prebuilt aarch64 binary (cargo-dist), not a build from
# source: it links only libc (GLIBC_2.34, wrynose has newer) and libgcc_s, and
# the binary every other user of the tool runs is the one worth having here.
# Pinned by version and checksum; v0.3.0 is the tag at 7174ddc9.
SRC_URI = "https://github.com/pollen-robotics/rustypot_wizard/releases/download/v${PV}/rustypot_wizard-aarch64-unknown-linux-gnu.tar.xz;downloadfilename=${BPN}-${PV}-aarch64.tar.xz"
SRC_URI[sha256sum] = "dd4d87ae74a520cf5c8148c3c0cb56fb16d9ee9082cf001c4c9cbc3b6e8968ea"

S = "${UNPACKDIR}/rustypot_wizard-aarch64-unknown-linux-gnu"

COMPATIBLE_HOST = "aarch64.*-linux"

# Prebuilt: no configure/compile. Our do_install replaces the class's, which
# copies ${S} as-is and this archive is not laid out like a rootfs.
inherit bin_package

do_install() {
	install -d ${D}${bindir}
	install -m 0755 ${S}/rustypot_wizard ${D}${bindir}/rustypot_wizard
}
