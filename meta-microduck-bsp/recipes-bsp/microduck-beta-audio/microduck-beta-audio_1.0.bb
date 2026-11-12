SUMMARY = "Audio routing for the microduck beta board"
DESCRIPTION = "Points ALSA's default PCM at the beta board's two cards (RK809 \
codec for playback, face-board PDM mic for capture) and selects the codec's \
speaker path at boot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

SRC_URI = " \
    file://60-microduck-beta.conf \
    file://microduck-audio-path.service \
"

S = "${UNPACKDIR}"

# The card names it routes to come from the beta DTS.
PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "microduck-beta"

inherit systemd

SYSTEMD_SERVICE:${PN} = "microduck-audio-path.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
	# conf.d rather than /etc/asound.conf, which alsa-state owns.
	install -d ${D}${sysconfdir}/alsa/conf.d
	install -m 0644 ${UNPACKDIR}/60-microduck-beta.conf ${D}${sysconfdir}/alsa/conf.d/

	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${UNPACKDIR}/microduck-audio-path.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += "${sysconfdir}/alsa/conf.d/60-microduck-beta.conf"

RDEPENDS:${PN} = "alsa-utils-amixer"
