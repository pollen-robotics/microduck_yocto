# The hardware watchdog, armed by PID 1 (files/watchdog.conf). A board fact: the
# RK3566's dw_wdt, enabled in rk356x.dtsi and built into the kernel. Named
# `_%` because the upstream file is systemd-conf_1.0.bb.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://watchdog.conf"

do_install:append() {
	install -D -m0644 ${UNPACKDIR}/watchdog.conf ${D}${systemd_unitdir}/system.conf.d/10-microduck-watchdog.conf
}
