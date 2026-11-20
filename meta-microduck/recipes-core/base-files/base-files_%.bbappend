FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Grow / to fill its slot at boot: `rauc install` writes the ext4 at image size,
# and daemon updates then failed updaterd's disk preflight.
do_install:append:microduck() {
	sed -i 's|^\(/dev/root[[:space:]]\+/[[:space:]]\+auto[[:space:]]\+\)defaults[[:space:]]|\1defaults,x-systemd.growfs |' ${D}${sysconfdir}/fstab
	grep -q '^/dev/root[[:space:]].*x-systemd\.growfs' ${D}${sysconfdir}/fstab || bbfatal "fstab root line changed upstream; x-systemd.growfs not applied"
}
