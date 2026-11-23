SUMMARY = "Group access to the microduck beta's NFC reader spidev"
DESCRIPTION = "A udev rule giving the nfcd group the beta board's NFC reader, an \
ST25R100 on SPI1, for nfcd."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = "file://70-microduck-nfc-spidev.rules"

S = "${UNPACKDIR}"

# The rule names an RK3566 SPI controller by address: machine-specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_install() {
	install -d ${D}${nonarch_base_libdir}/udev/rules.d
	install -m 0644 ${UNPACKDIR}/70-microduck-nfc-spidev.rules ${D}${nonarch_base_libdir}/udev/rules.d/
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/70-microduck-nfc-spidev.rules"

# The nfcd group is the daemon recipe's (GROUPADD_PARAM in microduck-daemon).
RDEPENDS:${PN} = "microduck-daemon"
