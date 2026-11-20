# Host keys on the data partition: per slot, every OS update changed the robot's
# key, which teaches people to clear the warning that catches impersonation.
OPENSSH_HOST_KEY_DIR:microduck = "${localstatedir}/lib/robot/ssh"

FILESEXTRAPATHS:prepend:microduck := "${THISDIR}/files:"
SRC_URI:append:microduck = " file://sshdgenkeys-data.conf"

do_install:append:microduck() {
	install -d ${D}${systemd_system_unitdir}/sshdgenkeys.service.d
	install -m 0644 ${UNPACKDIR}/sshdgenkeys-data.conf \
		${D}${systemd_system_unitdir}/sshdgenkeys.service.d/microduck-data.conf

	# No root ssh, even with a key added later. In place, not a drop-in: sshd keeps
	# the first value, and a drop-in would beat the dev image's allow-root-login.
	for config in sshd_config sshd_config_readonly; do
		sed -i 's/^#PermitRootLogin .*/PermitRootLogin no/' ${D}${sysconfdir}/ssh/$config
		grep -qx 'PermitRootLogin no' ${D}${sysconfdir}/ssh/$config
	done
}
# Packaged in openssh-sshd with sshdgenkeys.service: its FILES take the whole unit dir.
