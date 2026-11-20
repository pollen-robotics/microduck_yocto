SUMMARY = "Group access to the microduck face board's LEDs"
DESCRIPTION = "A udev rule giving the robot group write access to the face LEDs' \
brightness and trigger, for robotctl led and for the daemons that will own them."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

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
