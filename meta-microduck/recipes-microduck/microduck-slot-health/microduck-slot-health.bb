SUMMARY = "Gate RAUC's good-boot marking on the robot's daemons being healthy"
DESCRIPTION = "A oneshot in boot-complete.target, which rauc-mark-good.service \
requires: the slot is marked good only if the daemons came up. Once it is, the \
slot's trial ends and U-Boot no longer falls back from it. See the scripts."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# OS policy, not daemon code: its own recipe, so changing it does not rebuild the
# daemon. microduck-daemon RDEPENDS on it -- the script asks the daemon's
# robot-boot-check and fails without it, which would leave every slot unmarked.
SRC_URI = " \
    file://microduck-slot-health \
    file://microduck-slot-health.service \
    file://microduck-slot-trial \
    file://rauc-mark-good-end-trial.conf \
"
S = "${UNPACKDIR}"

inherit allarch systemd

SYSTEMD_SERVICE:${PN} = "microduck-slot-health.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	install -d ${D}${systemd_system_unitdir}/rauc-mark-good.service.d ${D}${libexecdir}
	install -m 0644 ${UNPACKDIR}/microduck-slot-health.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/rauc-mark-good-end-trial.conf \
		${D}${systemd_system_unitdir}/rauc-mark-good.service.d/microduck-end-trial.conf
	install -m 0755 ${UNPACKDIR}/microduck-slot-health ${D}${libexecdir}/
	install -m 0755 ${UNPACKDIR}/microduck-slot-trial ${D}${libexecdir}/
}

FILES:${PN} += "${libexecdir}/microduck-slot-health ${libexecdir}/microduck-slot-trial"
# rauc-mark-good is only an RRECOMMENDS of rauc, and the drop-in extends its unit.
# u-boot-fw-utils is fw_printenv/fw_setenv, which microduck-slot-trial calls.
RDEPENDS:${PN} = "rauc rauc-mark-good systemd u-boot-fw-utils"
