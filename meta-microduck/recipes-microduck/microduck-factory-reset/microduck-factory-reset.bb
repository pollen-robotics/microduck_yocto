SUMMARY = "Factory reset: a 10 s hold of the face button"
DESCRIPTION = "Holding the face button for 10 seconds arms a factory reset and reboots. \
At the next boot, before anything opens the data partition, the owner's data on it is \
erased -- wifi, Bluetooth bonds, settings, name and PIN, logins, installed policies, \
logs -- and the daemon goes back to the release the image seeded (golden). Board facts \
and the OS's slot state are kept. See the script for the keep list and why."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://microduck-factory-reset \
    file://microduck-factory-reset.service \
    file://microduck-factory-reset-button.service \
    file://90-microduck-factory-reset.rules \
"
S = "${UNPACKDIR}"

inherit allarch systemd

# The wipe is enabled (WantedBy=local-fs.target, gated on the marker). The button
# watcher is not: the udev rule starts it when the face board's button exists.
SYSTEMD_SERVICE:${PN} = "microduck-factory-reset.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	install -D -m 0755 ${UNPACKDIR}/microduck-factory-reset ${D}${sbindir}/microduck-factory-reset
	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${UNPACKDIR}/microduck-factory-reset.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/microduck-factory-reset-button.service ${D}${systemd_system_unitdir}/
	install -D -m 0644 ${UNPACKDIR}/90-microduck-factory-reset.rules \
		${D}${nonarch_base_libdir}/udev/rules.d/90-microduck-factory-reset.rules
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/microduck-factory-reset-button.service \
    ${nonarch_base_libdir}/udev/rules.d/90-microduck-factory-reset.rules \
"

# Wipes /var/lib/robot (microduck-data's mount) and moves the daemon's `current` to
# `golden` (microduck-daemon's release tree). od and dd read the button, mv -T swaps
# the symlink, mount -o bind shows the image's seed under the data mount.
RDEPENDS:${PN} = "microduck-data microduck-daemon coreutils util-linux-mount systemd"
