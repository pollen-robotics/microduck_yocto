SUMMARY = "Kernel modules a robot never uses, made unloadable"
DESCRIPTION = "A modprobe.d file that refuses bridging, ebtables, traffic control \
and rarely used protocol modules, which an unprivileged process could otherwise \
load through a user namespace. The file says which and why."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = "file://microduck-unused-modules.conf"
S = "${UNPACKDIR}"

inherit allarch

do_install() {
	install -d ${D}${sysconfdir}/modprobe.d
	install -m 0644 ${UNPACKDIR}/microduck-unused-modules.conf ${D}${sysconfdir}/modprobe.d/
}

FILES:${PN} = "${sysconfdir}/modprobe.d/microduck-unused-modules.conf"
