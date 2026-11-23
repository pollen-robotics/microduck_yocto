SUMMARY = "microduck robot OS"
LICENSE = "Apache-2.0"

# The shipping image. Anything a robot must not carry, password-less root above
# all, goes in microduck-image-dev.bb, which only ever adds to this one.
require recipes-core/images/core-image-base.bb

inherit rockchip-image extrausers

# Overrides rockchip-image.bbclass's ?= single-rootfs layout.
WKS_FILE = "microduck-ab.wks.in"

# The operator account the daemon's tooling logs in as (duckctl ssh, dev-push.sh).
# A shared password is acceptable only because ssh is on the head's USB-C link
# alone. Fixed salt for reproducibility: `openssl passwd -6 -salt microduckbeta microduck`.
MICRODUCK_OPERATOR_HASH = "\$6\$microduckbeta\$lxVesOQbjM8IXwxq5s/GpwW0KnK1YuspITBn7crCGbeuodZd.PBnJJIS5E32lQK4/mugkqFe36SAr6iyo82Gu0"
EXTRA_USERS_PARAMS = "useradd -m -s /bin/bash -G robot,sudo,audio,video,dialout,i2c,plugdev,input -p '${MICRODUCK_OPERATOR_HASH}' microduck;"

# Plain wic stays listed: oe-core deletes an unlisted type once converted, and
# the beta's eMMC is flashed from the plain .wic.
IMAGE_FSTYPES += "wic.zst wic.zst.sha256sum wic.bmap"

# Rockchip's UFS copy and update.img, 14.5 GB nothing uses. No-ops because
# rockchip-image.bbclass appends them in ";"-joined words :remove cannot match.
do_image_wic_ufs() {
	:
}
gen_rkupdateimg() {
	:
}

# Fixed names, not per image: building both images in one job fails the second
# do_image_complete on them. Nothing reads them.
link_rootfs_image() {
	:
}
gen_rkparameter() {
	:
}

# os-release's BUILD_ID, so a flashed card knows its build (RAUC records it only
# on install). microduck-image-dev.bb sets the dev bundle's id instead.
require recipes-core/images/microduck-build-id.inc
MICRODUCK_BUILD_ID = "${MICRODUCK_SHIPPING_BUILD}"
MICRODUCK_BUILD_ID[vardepsexclude] = "DATETIME"
ROOTFS_POSTPROCESS_COMMAND += "microduck_build_id"
microduck_build_id() {
	v=$(echo '${DISTRO_VERSION}' | sed 's/\./\\./g')
	for f in ${IMAGE_ROOTFS}${nonarch_libdir}/os-release ${IMAGE_ROOTFS}${sysconfdir}/issue ${IMAGE_ROOTFS}${sysconfdir}/issue.net; do
		[ -e "$f" ] || continue
		sed -i "s/$v/${MICRODUCK_BUILD_ID}/g" "$f"
	done
	# os-release sanitises VERSION_ID, so the sed can miss: fail rather than lie.
	grep -qx 'VERSION_ID=${MICRODUCK_BUILD_ID}' ${IMAGE_ROOTFS}${nonarch_libdir}/os-release \
		|| bbfatal "os-release still names DISTRO_VERSION ${DISTRO_VERSION}, not build ${MICRODUCK_BUILD_ID}"
	echo 'BUILD_ID="${MICRODUCK_BUILD_ID}"' >> ${IMAGE_ROOTFS}${nonarch_libdir}/os-release
}

IMAGE_FEATURES += "ssh-server-openssh"

# / stays read-only (`ro` in the DTB's bootargs); the dev image drops this and
# remounts it rw. Writable state is on data or in RAM: docs/agents/rauc.md,
# "Read-only rootfs".
IMAGE_FEATURES += "read-only-rootfs"
# :append, to run after oe-core's read_only_rootfs_hook (a +=, parsed later).
ROOTFS_POSTPROCESS_COMMAND:append = " ${@bb.utils.contains('IMAGE_FEATURES', 'read-only-rootfs', 'microduck_read_only_rootfs', '', d)}"
microduck_read_only_rootfs() {
	fstab=${IMAGE_ROOTFS}${sysconfdir}/fstab
	sed -i 's/,x-systemd\.growfs//' $fstab
	grep -q '^/dev/root[[:space:]]\+/[[:space:]]\+auto[[:space:]]\+ro[[:space:]]' $fstab \
		|| bbfatal "fstab's root line is not 'ro' after read_only_rootfs_hook"

	# The daemon comes with the OS: a release's postinstall writes /etc and /usr,
	# so updaterd could only fail. Pinned to the image's own, never polled for.
	cfg=${IMAGE_ROOTFS}${sysconfdir}/robot/updater.toml
	ver=$(readlink ${IMAGE_ROOTFS}/opt/robot/daemon/current)
	ver=${ver#releases/}
	sed -i -e '/^check_interval[[:space:]]*=/d' \
		-e 's/^auto_apply[[:space:]]*=.*/auto_apply = "off"/' \
		-e "/^\[component\.daemon\]\$/a pinned = \"$ver\"" $cfg
	grep -qx 'auto_apply = "off"' $cfg && grep -qx "pinned = \"$ver\"" $cfg \
		&& ! grep -q '^check_interval' $cfg \
		|| bbfatal "updater.toml changed upstream; daemon updates not turned off"

	# A flashed slot's machine-id is transient on a read-only /; commit it once.
	# An installed slot gets the running one from the bundle hook instead.
	# An empty Condition*= drops all of the unit's conditions: restore the one
	# that limits it to a transient id, or / goes rw on every boot.
	d=${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-machine-id-commit.service.d
	install -d $d
	cat > $d/microduck-read-only.conf <<-'EOF'
		[Unit]
		ConditionPathIsReadWrite=
		ConditionPathIsMountPoint=${sysconfdir}/machine-id

		[Service]
		ExecStart=
		ExecStart=/bin/sh -c 'mount -o remount,rw / && systemd-machine-id-setup --commit; r=$?; mount -o remount,ro /; exit $r'
	EOF
}

# Only the GStreamer plugins mediad loads (packagegroup-microduck-media): each
# set's -meta RDEPENDS on all ~190. The dev image keeps this so a gap shows there first.
BAD_RECOMMENDATIONS += " \
    gstreamer1.0-plugins-base-meta \
    gstreamer1.0-plugins-good-meta \
    gstreamer1.0-plugins-bad-meta \
"

# ssh on the head's USB-C link only; a machine without the gadget (Zero 3W)
# would be left with no ssh at all.
IMAGE_INSTALL:append = " ${@bb.utils.contains('MACHINE_EXTRA_RDEPENDS', 'microduck-usb-gadget', 'microduck-ssh-access', '', d)}"

# An allowlist, so a new package cannot bring a setuid binary in unread. No
# user runs the others (one operator, with sudo); root keeps them, minus the bit.
MICRODUCK_SETUID_ALLOWED = " \
    ${bindir}/sudo \
    ${sbindir}/unix_chkpwd \
    ${libexecdir}/dbus-daemon-launch-helper \
"
ROOTFS_POSTPROCESS_COMMAND += "microduck_setuid_allowlist"
microduck_setuid_allowlist() {
	find ${IMAGE_ROOTFS} -xdev -type f -perm /6000 | while read -r f; do
		case " ${MICRODUCK_SETUID_ALLOWED} " in
		*" ${f#${IMAGE_ROOTFS}} "*) continue ;;
		esac
		bbnote "dropping setuid/setgid: ${f#${IMAGE_ROOTFS}}"
		chmod u-s,g-s "$f"
	done
}

# Only what the image chooses: a package that another one needs at runtime is that
# package's RDEPENDS, not a line here (rauc, the media stack, aplay come that way).
# padd: a shipping robot is driven with a gamepad.
# ldd: cargo-dist installers (rustypot-wizard's) read the glibc version with it.
# MICRODUCK_RADIO_PACKAGES: per machine; BLE provisioning needs the attach unit.
IMAGE_INSTALL:append = " \
    microduck-daemon \
    microduck-daemon-padd \
    microduck-board \
    microduck-data \
    ldd \
    rustypot-wizard \
    sudo \
    ${MICRODUCK_RADIO_PACKAGES} \
    i2c-tools \
    htop \
"

# Not all 750 modules of radxa's defconfig (40 MB): what the robot needs is built in.
# These two are all a running board loads besides its wifi driver (fq_codel is
# systemd's default qdisc); a module that is not installed cannot be loaded at all.
BAD_RECOMMENDATIONS += "kernel-modules"
IMAGE_INSTALL:append = " kernel-module-sch-fq-codel kernel-module-nfnetlink"

# The beta's face LEDs, ToF and NFC reader, for the daemons' groups (robot, nfcd).
IMAGE_INSTALL:append:microduck-beta = " microduck-face-leds microduck-tof-spidev microduck-nfc"
