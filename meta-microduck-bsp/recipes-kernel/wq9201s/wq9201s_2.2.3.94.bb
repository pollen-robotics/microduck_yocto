SUMMARY = "WuQi WQ9201S SDIO wifi driver (wq_wlan) and its Bluetooth attach"
DESCRIPTION = "Out-of-tree wq_wlan kernel module for the WuQi WQ9201S wifi/BT \
combo inside the beta board's WL6201S module, plus the unit that attaches its \
Bluetooth controller on UART1. Firmware is wq9201s-firmware."
# Seeed's debian/copyright: src/* is GPL-2 (or later), copyright WuQi Micro. The
# whole file is checksummed, so a change to their terms fails the build here.
LICENSE = "GPL-2.0-or-later"
LIC_FILES_CHKSUM = "file://debian/copyright;md5=3727876b7206ead678f0a134cddb542b"

inherit module systemd features_check
REQUIRED_DISTRO_FEATURES = "wifi"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The same sources as Seeed's factory image. The bt-attach script and unit are
# ours, reworked from Seeed's bt/. Each patch says why.
require seeed-deb-source.inc
SRC_URI = " \
    ${SEEED_DEB_SOURCE} \
    file://0001-wq_wlan-report-the-disconnection-on-a-failed-roam.patch \
    file://wq9201s-bt-attach \
    file://wq9201s-bt.service \
"
S = "${UNPACKDIR}/${BP}/wq9201s-wifi-bt-dkms"

# As aic8800: kbuild directly, not the Makefile's KERNELDIR/O= wrapper.
B = "${S}/src/wifi/rwnx_drv"
MAKE_TARGETS = "-C ${STAGING_KERNEL_DIR} M=${B} modules"
MODULES_INSTALL_TARGET = "-C ${STAGING_KERNEL_DIR} M=${B} modules_install"
MODULES_MODULE_SYMVERS_LOCATION = "."

# -Werror under GCC 15 fails on code that GCC 12 (theirs) accepted.
drop_werror() {
	sed -i '/^ccflags-y += -Werror$/d' ${S}/src/wifi/rwnx_drv/Makefile
	if grep -q -- '-Werror' ${S}/src/wifi/rwnx_drv/Makefile; then
		bbfatal "-Werror still in the wq_wlan Makefile"
	fi
}
do_patch[postfuncs] += "drop_werror"

do_install:append() {
	install -d ${D}${libexecdir}
	install -m 0755 ${UNPACKDIR}/wq9201s-bt-attach ${D}${libexecdir}/
	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${UNPACKDIR}/wq9201s-bt.service ${D}${systemd_system_unitdir}/
}

# Loaded at boot rather than left to the SDIO modalias: what matters is that it is
# up before the Bluetooth attach waits for wlan0.
KERNEL_MODULE_AUTOLOAD += "wq_wlan"

PACKAGES =+ "${PN}-bt"
FILES:${PN}-bt = "${libexecdir}/wq9201s-bt-attach ${systemd_system_unitdir}/wq9201s-bt.service"
SYSTEMD_PACKAGES = "${PN}-bt"
SYSTEMD_SERVICE:${PN}-bt = "wq9201s-bt.service"
SYSTEMD_AUTO_ENABLE:${PN}-bt = "enable"
RDEPENDS:${PN}-bt = "bluez5 procps util-linux-rfkill"

RDEPENDS:${PN} += "wq9201s-firmware"
