SUMMARY = "Raise the CPU voltage before a reboot, so the next boot does not hang"
DESCRIPTION = "A systemd-shutdown hook that puts every cpufreq policy on the \
performance governor as the last step of a reboot. The beta board's RK860 keeps \
its voltage across a warm reset, and a reboot from idle (850 mV) hangs the next \
boot before Linux."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = "file://microduck-cpu-voltage"

inherit allarch features_check
REQUIRED_DISTRO_FEATURES = "systemd"

S = "${UNPACKDIR}"

# systemd's own path for these, not ${systemd_unitdir}/system: shutdown hooks
# live in system-shutdown/, next to it.
do_install() {
	install -d ${D}${systemd_unitdir}/system-shutdown
	install -m 0755 ${UNPACKDIR}/microduck-cpu-voltage ${D}${systemd_unitdir}/system-shutdown/
}

FILES:${PN} = "${systemd_unitdir}/system-shutdown/microduck-cpu-voltage"
