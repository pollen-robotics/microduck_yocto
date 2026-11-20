# Our system.conf and CA certificate win over meta-rauc's examples.
FILESEXTRAPATHS:prepend:microduck := "${THISDIR}/files:"

# @MACHINE@ rather than a literal, because 'compatible' has to match
# RAUC_BUNDLE_COMPATIBLE in recipes-core/bundles/microduck-bundle.bb or RAUC
# refuses to install, and the custom PCB will be a second machine conf.
do_install:prepend:microduck() {
	sed -i -e 's!@MACHINE@!${MACHINE}!g' ${UNPACKDIR}/system.conf
}

# The keyring (system.conf's path=) trusts the production CA only, so the shipping
# image installs nothing but production-signed bundles: those `promote-os`
# re-signs. ${PN}-dev-ca, installed by microduck-image-dev alone, appends the
# development CA, which signs every CI build. docs/agents/rauc.md, "Two CAs".
RAUC_KEYRING_FILE:microduck = "ca-prod.cert.pem"
SRC_URI:append:microduck = " file://ca-dev.cert.pem"
do_install:append:microduck() {
	mv ${D}${nonarch_libdir}/rauc/ca-prod.cert.pem ${D}${nonarch_libdir}/rauc/keyring.pem
	install -m 0644 ${UNPACKDIR}/ca-dev.cert.pem ${D}${nonarch_libdir}/rauc/
}

# system.conf names machine-specific devices, so this package is per-machine.
PACKAGE_ARCH:microduck = "${MACHINE_ARCH}"

PACKAGES:prepend:microduck = "${PN}-dev-ca "
FILES:${PN}-dev-ca = "${nonarch_libdir}/rauc/ca-dev.cert.pem"
RDEPENDS:${PN}-dev-ca = "${PN}"
# At do_rootfs, where $D is the image root. RAUC reads every certificate in the
# keyring file.
pkg_postinst:${PN}-dev-ca() {
	cat $D${nonarch_libdir}/rauc/ca-dev.cert.pem >> $D${nonarch_libdir}/rauc/keyring.pem
}
