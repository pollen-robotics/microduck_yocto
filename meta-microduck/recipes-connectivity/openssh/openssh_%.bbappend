# SSH host keys on the data partition, so a robot keeps one SSH identity.
#
# oe-core writes the HostKey lines from OPENSSH_HOST_KEY_DIR, and sshdgenkeys
# (sshd_check_keys) generates any key missing there. Left at /etc/ssh, each slot
# generated its own: after every OS update a robot presented a new host key, and
# `ssh` answered with "REMOTE HOST IDENTIFICATION HAS CHANGED" -- which teaches
# people to clear exactly the warning that catches a machine impersonating the
# robot. Measured on a beta board, 2026-11-10: slots A and B had different keys.
#
# A robot moving to an image with this generates its key once more, on the data
# partition, then keeps it: the keys of the slot it came from live in that slot's
# rootfs, which is not mounted, so there is nothing to carry over.
OPENSSH_HOST_KEY_DIR = "${localstatedir}/lib/robot/ssh"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://sshdgenkeys-data.conf"

do_install:append() {
	install -d ${D}${systemd_system_unitdir}/sshdgenkeys.service.d
	install -m 0644 ${UNPACKDIR}/sshdgenkeys-data.conf \
		${D}${systemd_system_unitdir}/sshdgenkeys.service.d/microduck-data.conf

	# No ssh as root, even with a key: the way in is microduck@ then sudo.
	# oe-core's default, prohibit-password, already refuses root here (no
	# password, no authorized_keys); this keeps a key added later from opening it.
	# Edited in place rather than in sshd_config.d: sshd keeps the first value it
	# reads, and the Include comes first, so a drop-in would beat the dev image's
	# allow-root-login, which rewrites this same line to yes at rootfs time.
	for config in sshd_config sshd_config_readonly; do
		sed -i 's/^#PermitRootLogin .*/PermitRootLogin no/' ${D}${sysconfdir}/ssh/$config
		grep -qx 'PermitRootLogin no' ${D}${sysconfdir}/ssh/$config
	done
}
# Packaged in openssh-sshd with sshdgenkeys.service: its FILES take the whole unit dir.
