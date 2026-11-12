SUMMARY = "ssh on the head USB link only, and on wifi on request until reboot"
DESCRIPTION = "Limits sshd.socket to the USB gadget's link (192.168.42.1 on \
usb0). Creating /run/microduck-ssh-wifi as root (configd on an authenticated \
BLE request, or sudo over USB) opens it on every interface until the next \
reboot. Only for machines with microduck-usb-gadget: see microduck-image.bb."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://10-usb-only.conf \
    file://30-wifi-until-reboot.conf \
    file://microduck-ssh-wifi.path \
    file://microduck-ssh-wifi.service \
"
S = "${UNPACKDIR}"

inherit allarch systemd

# Only the path unit is enabled; it starts the service, which has no [Install].
SYSTEMD_SERVICE:${PN} = "microduck-ssh-wifi.path"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	install -d ${D}${systemd_system_unitdir}/sshd.socket.d \
		${D}${systemd_system_unitdir}/sys-subsystem-net-devices-usb0.device.wants \
		${D}${datadir}/${BPN}
	install -m 0644 ${UNPACKDIR}/10-usb-only.conf ${D}${systemd_system_unitdir}/sshd.socket.d/
	ln -s ../sshd.socket ${D}${systemd_system_unitdir}/sys-subsystem-net-devices-usb0.device.wants/sshd.socket
	install -m 0644 ${UNPACKDIR}/microduck-ssh-wifi.path ${UNPACKDIR}/microduck-ssh-wifi.service \
		${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/30-wifi-until-reboot.conf ${D}${datadir}/${BPN}/
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/sshd.socket.d \
    ${systemd_system_unitdir}/sys-subsystem-net-devices-usb0.device.wants \
    ${systemd_system_unitdir}/microduck-ssh-wifi.service \
    ${datadir}/${BPN} \
"

RDEPENDS:${PN} = "openssh-sshd"
