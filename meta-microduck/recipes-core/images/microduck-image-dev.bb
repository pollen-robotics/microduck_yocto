SUMMARY = "microduck robot OS -- dev image"
DESCRIPTION = "microduck-image plus what a developer needs and a robot must not \
ship. A strict superset: it adds, never substitutes, so anything verified on a \
dev board holds for the shipping image too."

require recipes-core/images/microduck-image.bb

# The one dev difference that cannot be added later: with no package manager,
# a login must be in the image. oelint flags these in any image; only here.
# nooelint: oelint.var.badimagefeature
IMAGE_FEATURES += "allow-empty-password allow-root-login empty-root-password"

# ssh on every interface: microduck-ssh-access's own wifi reset, made permanent.
ROOTFS_POSTPROCESS_COMMAND += "sshd_any_interface"
sshd_any_interface() {
	reset=${IMAGE_ROOTFS}${datadir}/microduck-ssh-access/30-wifi-until-reboot.conf
	[ -e "$reset" ] || return 0
	install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sshd.socket.d
	install -m 0644 "$reset" ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sshd.socket.d/20-dev-any-interface.conf
}

# The dev bundle's build id is plain DATETIME, meta-rauc's RAUC_BUNDLE_BUILD default.
MICRODUCK_BUILD_ID = "${DATETIME}"

# The OS update page on the LAN. It takes apply and switch unauthenticated, so
# the shipping image keeps it on loopback. Empty ListenStream= clears that first.
ROOTFS_POSTPROCESS_COMMAND += "osupdate_page_on_lan"
osupdate_page_on_lan() {
	[ -e ${IMAGE_ROOTFS}${systemd_system_unitdir}/microduck-osupdate.socket ] || return 0
	d=${IMAGE_ROOTFS}${sysconfdir}/systemd/system/microduck-osupdate.socket.d
	install -d $d
	printf '[Socket]\nListenStream=\nListenStream=8090\n' > $d/20-dev-lan.conf
}

# devkey + rauc-conf-dev-ca: trust dev-signed daemon releases and OS bundles
# (every CI bundle is dev-signed). Never in the shipping image.
# coreutils, util-linux: busybox lacks `timeout`, `findmnt`, `head -4`.
# evtest: tells a pad that never bonded from one that sends nothing.
# The tracers: dev-only plugins; the hooks are in both (gstreamer1.0_%.bbappend).
IMAGE_INSTALL:append = " \
    microduck-daemon-devkey \
    rauc-conf-dev-ca \
    microduck-daemon-bash-completion \
    ${MICRODUCK_RADIO_DEV_PACKAGES} \
    coreutils \
    util-linux \
    less \
    strace \
    e2fsprogs \
    tcpdump \
    evtest \
    gstreamer1.0-tracers \
    gstreamer1.0-plugins-rs-tracers \
"
