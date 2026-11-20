SUMMARY = "Temperature-driven fan control for microduck boards with a fan"
DESCRIPTION = "Switches soc-thermal, where the device tree puts the fan's \
trips, to the step_wise governor, so the fan stays off when the SoC is cool and \
steps up with temperature instead of running at the full duty pwm-fan starts at."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = "file://70-microduck-fan.rules"

# The trips and fan levels live in the DTS, which is the per-board part; this
# rule only names a zone, so the package is the same everywhere.
inherit allarch

S = "${UNPACKDIR}"

do_install() {
	install -d ${D}${nonarch_base_libdir}/udev/rules.d
	install -m 0644 ${UNPACKDIR}/70-microduck-fan.rules ${D}${nonarch_base_libdir}/udev/rules.d/
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/70-microduck-fan.rules"
