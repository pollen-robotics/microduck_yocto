SUMMARY = "Group access to the microduck face board's LEDs"
DESCRIPTION = "A udev rule giving the robot group write access to the face LEDs' \
brightness and trigger, for robotctl led and for the daemons that will own them."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = "file://70-microduck-face-leds.rules"

S = "${UNPACKDIR}"

inherit allarch

do_install() {
	install -d ${D}${nonarch_base_libdir}/udev/rules.d
	install -m 0644 ${UNPACKDIR}/70-microduck-face-leds.rules ${D}${nonarch_base_libdir}/udev/rules.d/
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/70-microduck-face-leds.rules"

# The robot group is the daemon recipe's (GROUPADD_PARAM in microduck-daemon).
RDEPENDS:${PN} = "microduck-daemon"
