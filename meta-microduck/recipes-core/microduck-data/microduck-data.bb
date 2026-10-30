SUMMARY = "Persistent data partition at /var/lib/robot"
DESCRIPTION = "Mounts the data partition where the daemon keeps what a user adds, \
and keeps NetworkManager's wifi profiles there too, so both survive a RAUC slot \
switch. Also holds the systemd journal, so logs survive power cuts and \
rollbacks, and BlueZ's bonds, so a paired gamepad survives an update."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = " \
    file://var-lib-robot.mount \
    file://var-lib-bluetooth.mount \
    file://90-microduck-keyfile.conf \
    file://microduck-data.tmpfiles \
    file://var-volatile-log-journal.mount \
    file://microduck-journal-dir.service \
    file://journal-flush.conf \
"

inherit systemd

# The unit name must be the mount point with / -> -.
# microduck-journal-dir.service is not listed: the journal mount pulls it in.
# Nor is var-lib-bluetooth.mount: bluetooth.service's StateDirectory= pulls it in.
SYSTEMD_SERVICE:${PN} = "var-lib-robot.mount var-volatile-log-journal.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${UNPACKDIR}/var-lib-robot.mount ${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/var-lib-bluetooth.mount ${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/var-volatile-log-journal.mount ${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/microduck-journal-dir.service ${D}${systemd_system_unitdir}/
	install -d ${D}${systemd_system_unitdir}/systemd-journal-flush.service.d
	install -m 0644 ${UNPACKDIR}/journal-flush.conf ${D}${systemd_system_unitdir}/systemd-journal-flush.service.d/microduck.conf

	install -d ${D}${nonarch_libdir}/NetworkManager/conf.d
	install -m 0644 ${UNPACKDIR}/90-microduck-keyfile.conf ${D}${nonarch_libdir}/NetworkManager/conf.d/
	install -d ${D}${nonarch_libdir}/tmpfiles.d
	install -m 0644 ${UNPACKDIR}/microduck-data.tmpfiles ${D}${nonarch_libdir}/tmpfiles.d/microduck-data.conf

	# In the image too, so the wks seeds it into a fresh data partition and
	# utils/seed-wifi.sh finds it before first boot.
	install -d -m 0700 ${D}${localstatedir}/lib/robot/network
	install -d -m 2755 ${D}${localstatedir}/lib/robot/journal
}

# microduck-daemon ships /var/lib/robot itself; this adds two subdirectories.
RDEPENDS:${PN} += "microduck-daemon networkmanager"

FILES:${PN} = " \
    ${systemd_system_unitdir}/var-lib-robot.mount \
    ${systemd_system_unitdir}/var-lib-bluetooth.mount \
    ${systemd_system_unitdir}/var-volatile-log-journal.mount \
    ${systemd_system_unitdir}/microduck-journal-dir.service \
    ${systemd_system_unitdir}/systemd-journal-flush.service.d/microduck.conf \
    ${nonarch_libdir}/NetworkManager/conf.d/90-microduck-keyfile.conf \
    ${nonarch_libdir}/tmpfiles.d/microduck-data.conf \
    ${localstatedir}/lib/robot/network \
    ${localstatedir}/lib/robot/journal \
"
