SUMMARY = "OS updates from a published channel, with a local page (prototype)"
DESCRIPTION = "Checks os/<machine>/<channel>.env in the public microduck-os bucket, \
downloads and verifies the bundle, installs it with rauc and reboots; reports the \
outcome on the next boot. An HTTP API and page on 127.0.0.1:8090 (every interface \
on the dev image). See the script."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://microduck-osupdate \
    file://index.html \
    file://microduck-osupdate.socket \
    file://microduck-osupdate@.service \
    file://microduck-osupdate-report.service \
"
S = "${UNPACKDIR}"

inherit allarch systemd

# The socket, not the per-connection template it spawns.
SYSTEMD_SERVICE:${PN} = "microduck-osupdate.socket microduck-osupdate-report.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	install -D -m 0755 ${UNPACKDIR}/microduck-osupdate ${D}${bindir}/microduck-osupdate
	install -D -m 0644 ${UNPACKDIR}/index.html ${D}${datadir}/microduck-osupdate/index.html
	install -d ${D}${systemd_system_unitdir}
	for u in microduck-osupdate.socket microduck-osupdate@.service microduck-osupdate-report.service; do
		install -m 0644 ${UNPACKDIR}/$u ${D}${systemd_system_unitdir}/
	done
}

FILES:${PN} += "${systemd_system_unitdir}/microduck-osupdate@.service"
# rauc to install, curl to fetch (with resume), flock/sha256sum from util-linux and
# coreutils or busybox, systemd-run for the detached apply.
# u-boot-fw-utils: fw_printenv, which apply reads BOOT_<slot>_LEFT with.
RDEPENDS:${PN} = "rauc curl systemd util-linux-flock u-boot-fw-utils"
