SUMMARY = "Temperature-driven fan control for microduck boards with a fan"
DESCRIPTION = "Switches soc-thermal, where the device tree puts the fan's \
trips, to the step_wise governor, so the fan stays off when the SoC is cool and \
steps up with temperature instead of running at the full duty pwm-fan starts at."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

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
