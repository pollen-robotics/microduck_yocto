SUMMARY = "USB-C gadget: a serial console and a network link to the robot"
DESCRIPTION = "Turns the board's USB-C OTG port into a composite USB device: \
a serial console (getty on ttyGS0) and an NCM network link with the robot at \
192.168.42.1 handing the host a DHCP lease. A way in that needs neither the \
radio nor the debug test pads -- the same USB-C cable the eMMC is flashed over."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = " \
    file://microduck-usb-gadget \
    file://microduck-usb-gadget.service \
    file://microduck-usb-dhcp.service \
    file://91-microduck-usb0-unmanaged.conf \
"

S = "${UNPACKDIR}"

inherit systemd allarch

SYSTEMD_SERVICE:${PN} = "microduck-usb-gadget.service microduck-usb-dhcp.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	install -d ${D}${sbindir}
	install -m 0755 ${UNPACKDIR}/microduck-usb-gadget ${D}${sbindir}/

	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${UNPACKDIR}/microduck-usb-gadget.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/microduck-usb-dhcp.service ${D}${systemd_system_unitdir}/

	install -d ${D}${nonarch_libdir}/NetworkManager/conf.d
	install -m 0644 ${UNPACKDIR}/91-microduck-usb0-unmanaged.conf \
		${D}${nonarch_libdir}/NetworkManager/conf.d/

	# The getty on the gadget's serial port. systemd's getty generator only
	# covers console= ttys, and systemd.bbclass cannot enable an instance of a
	# template another package ships, so the wants link is made by hand.
	install -d ${D}${sysconfdir}/systemd/system/getty.target.wants
	ln -sf ${systemd_system_unitdir}/serial-getty@.service \
		${D}${sysconfdir}/systemd/system/getty.target.wants/serial-getty@ttyGS0.service
}

FILES:${PN} += " \
    ${nonarch_libdir}/NetworkManager/conf.d/91-microduck-usb0-unmanaged.conf \
    ${sysconfdir}/systemd/system/getty.target.wants/serial-getty@ttyGS0.service \
"

# dnsmasq: the binary only -- the image disables its own dnsmasq.service
# (SYSTEMD_AUTO_ENABLE:pn-dnsmasq = "disable" in the microduck distro), and
# microduck-usb-dhcp.service runs a private instance bound to usb0.
RDEPENDS:${PN} = "dnsmasq iproute2 util-linux-mountpoint"
