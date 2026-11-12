SUMMARY = "Kernel modules a robot never uses, made unloadable"
DESCRIPTION = "A modprobe.d file that refuses bridging, ebtables, traffic control \
and rarely used protocol modules, which an unprivileged process could otherwise \
load through a user namespace. The file says which and why."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://microduck-unused-modules.conf"
S = "${UNPACKDIR}"

inherit allarch

do_install() {
	install -d ${D}${sysconfdir}/modprobe.d
	install -m 0644 ${UNPACKDIR}/microduck-unused-modules.conf ${D}${sysconfdir}/modprobe.d/
}

FILES:${PN} = "${sysconfdir}/modprobe.d/microduck-unused-modules.conf"
