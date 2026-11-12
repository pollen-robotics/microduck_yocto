SUMMARY = "Group access to the microduck beta's ToF spidev"
DESCRIPTION = "A udev rule giving the robot group the face board's ToF, a VL53L8CX \
on SPI3, for tofd."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = "file://70-microduck-tof-spidev.rules"

S = "${UNPACKDIR}"

inherit allarch

do_install() {
	install -d ${D}${nonarch_base_libdir}/udev/rules.d
	install -m 0644 ${UNPACKDIR}/70-microduck-tof-spidev.rules ${D}${nonarch_base_libdir}/udev/rules.d/
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/70-microduck-tof-spidev.rules"

# The robot group is the daemon recipe's (GROUPADD_PARAM in microduck-daemon).
RDEPENDS:${PN} = "microduck-daemon"
