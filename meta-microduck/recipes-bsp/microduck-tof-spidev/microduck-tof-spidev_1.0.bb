SUMMARY = "Group access to the microduck beta's ToF spidev"
DESCRIPTION = "A udev rule giving the robot group the face board's ToF, a VL53L8CX \
on SPI3, for tofd."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = "file://70-microduck-tof-spidev.rules"

S = "${UNPACKDIR}"

# The rule names an RK3566 SPI controller by address: machine-specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
	install -d ${D}${nonarch_base_libdir}/udev/rules.d
	install -m 0644 ${UNPACKDIR}/70-microduck-tof-spidev.rules ${D}${nonarch_base_libdir}/udev/rules.d/
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/70-microduck-tof-spidev.rules"

# The robot group is the daemon recipe's (GROUPADD_PARAM in microduck-daemon).
RDEPENDS:${PN} = "microduck-daemon"
