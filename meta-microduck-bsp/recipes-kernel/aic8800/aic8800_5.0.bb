SUMMARY = "AICSemi AIC8800 SDIO wifi/BT driver and firmware"
DESCRIPTION = "Out-of-tree AICSemi aic8800_* kernel modules for the SDIO-attached \
AIC8800 wifi/BT combo fitted to some Radxa Zero 3W boards, plus its firmware. \
Not present in the kernel tree (radxa's or Armbian's) -- the device tree wires up the SDIO bus, \
power sequence and BT UART, but nothing drives it."
HOMEPAGE = "https://github.com/radxa-pkg/aic8800"
# GPL-2 driver, GPL-3+ Debian packaging: both declared so the SBOM matches the
# fetched tree (docs/agents/zero3-board.md).
LICENSE = "GPL-2.0-only & GPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464 \
                    file://debian/copyright;md5=ccd22839cbff32b2bbe9a6ec05d11739"

inherit module systemd features_check
REQUIRED_DISTRO_FEATURES = "wifi"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "git://github.com/radxa-pkg/aic8800.git;protocol=https;nobranch=1 \
           file://aic8800-bt-attach.service \
"
# Tag 5.0+git20260123.5f7be68d-7.
SRCREV = "6e076049b719ac2ff7ce5c92786a680407b11cdb"

# The vendor Makefile never calls kbuild itself, so pass -C and M= here.
B = "${S}/src/SDIO/driver_fw/driver/aic8800"
MAKE_TARGETS = "-C ${STAGING_KERNEL_DIR} M=${B} modules"
MODULES_INSTALL_TARGET = "-C ${STAGING_KERNEL_DIR} M=${B} modules_install"
MODULES_MODULE_SYMVERS_LOCATION = "."

# debian/patches/series through quilt, so a re-run of do_patch is a no-op. CRLF
# fixed first, source files only (never the firmware). Rejects stay fatal.
apply_debian_patches() {
	cd ${S}
	find src -type f \( -name '*.c' -o -name '*.h' -o -name 'Makefile*' \
		-o -name '*.mk' -o -name 'Kconfig*' \) \
		-exec sed -i 's/\r$//' {} +

	export QUILT_PATCHES=debian/patches
	rc=0
	quilt --quiltrc /dev/null push -a || rc=$?
	# 0 = applied; 2 = nothing to do (already fully applied). Anything else is real.
	if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
		bbfatal "quilt push -a failed with exit $rc"
	fi
}
do_patch[postfuncs] += "apply_debian_patches"

FW_SUBDIR = "${nonarch_base_libdir}/firmware/aic8800_fw"

do_install:append() {
	install -d ${D}${FW_SUBDIR}/SDIO
	# Every chip variant: none obviously maps to the DS2, the driver picks.
	cp -R ${S}/src/SDIO/driver_fw/fw/* ${D}${FW_SUBDIR}/SDIO/
	# A compressed duplicate of the aic8800D80 directory; no use on target.
	rm -f ${D}${FW_SUBDIR}/SDIO/aic8800D80.7z

	install -d ${D}${bindir}
	install -m 0755 ${S}/src/tools/aicrf_test/bt_test ${D}${bindir}/bt_test

	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${UNPACKDIR}/aic8800-bt-attach.service \
		${D}${systemd_system_unitdir}/
}

# Enabled: BLE provisioning is how a robot gets onto a network, and an
# unattached radio looks like no Bluetooth at all.
SYSTEMD_PACKAGES = "${PN}-bt"
SYSTEMD_SERVICE:${PN}-bt = "aic8800-bt-attach.service"
SYSTEMD_AUTO_ENABLE:${PN}-bt = "enable"

# bt_test, AICSemi's diagnostic. By hand: its Makefile hardcodes gcc.
do_compile:append() {
	${CC} ${CFLAGS} ${LDFLAGS} -o ${S}/src/tools/aicrf_test/bt_test \
		${S}/src/tools/aicrf_test/bt_test.c -lpthread
}

PACKAGES =+ "${PN}-firmware ${PN}-bt ${PN}-bt-test"
FILES:${PN}-firmware = "${FW_SUBDIR}"
FILES:${PN}-bt = "${systemd_system_unitdir}/aic8800-bt-attach.service"
FILES:${PN}-bt-test = "${bindir}/bt_test"

# hciattach and hciconfig.
RDEPENDS:${PN}-bt += "bluez5"

RDEPENDS:${PN} += "${PN}-firmware"
KERNEL_MODULE_AUTOLOAD += "aic8800_bsp aic8800_fdrv aic8800_btlpm"
