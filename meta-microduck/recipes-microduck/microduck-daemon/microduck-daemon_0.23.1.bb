SUMMARY = "microduck robot control and update daemons"
DESCRIPTION = "robotd (50 Hz Dynamixel control loop), updaterd (signed, \
rollback-safe update engine), robotctl (local CLI), padd (gamepad client), \
netpadd (the same client fed over UDP, off unless [netpad] enabled), \
configd (wifi and robot identity, drives NetworkManager), btd (the BLE \
transport that fronts configd, so a robot with no network can be provisioned \
from a phone), mediad, tofd, nfcd, sounds and the duck/pet detectors. Every \
unit is enabled: a robot with the hardware should come up working. On a board \
without it, disable the three that need parts -- mediad, tofd, padd."
HOMEPAGE = "https://github.com/pollen-robotics/microduck_daemon"

# Why each part of this recipe is the way it is: docs/agents/daemon-recipe.md.

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=86d3f3a95c324c9479bd8986968f4327"

inherit cargo cargo-update-recipe-crates pkgconfig systemd useradd features_check
REQUIRED_DISTRO_FEATURES = "systemd bluetooth wifi"

# aws-lc-sys runs CMake. A DEPENDS, not `inherit cmake`.
DEPENDS += "cmake-native"
# libudev for padd's gilrs (inherit pkgconfig supplies the binary).
DEPENDS += "systemd"
# mediad's gstreamer -sys crates; webrtc comes from our plugins-bad bbappend.
DEPENDS += "glib-2.0 gstreamer1.0 gstreamer1.0-plugins-base gstreamer1.0-plugins-bad"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "git://github.com/pollen-robotics/microduck_daemon.git;protocol=https;branch=main;name=daemon \
           git://github.com/pollen-robotics/bmi088-rs;protocol=https;nobranch=1;name=bmi088;destsuffix=bmi088-rs \
           file://60-robot-i2c.rules \
           file://robotctl.bash_completion \
           file://microduck-voice-bank.service \
"
# A release's source_revision, never main: set by scripts/bump-daemon.sh.
SRCREV_daemon = "93b26bbf2acf73babb53cd6b47e800d2661f54f4"
# The commit under the v0.1.2 tag, not the tag object. name= must be the crate name.
SRCREV_bmi088 = "bd113f317b14923f50f9a12a06678fe162b7fe06"
SRCREV_FORMAT = "daemon_bmi088"

require microduck-daemon-crates.inc

CARGO_BUILD_FLAGS += "--workspace --exclude xtask --exclude test-support --exclude duckctl --exclude duck-ether"

export DUCK_REVISION = "${SRCREV_daemon}"

# Upstream's sysusers.d files are not installed: every unit's User= and groups are made here.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r robot; -r robot-account; -r bluetooth; -r btd; -r mediad; -r tofd; -r padd; -r i2c; -r nfcd; -r netpadd; -r autod; -r mapd"
USERADD_PARAM:${PN} = "-r -g btd -d / -s /sbin/nologin -c 'Robot BLE transport adapter' btd; \
                       -r -g mediad -d / -s /sbin/nologin -c 'Robot media and WebRTC gateway' mediad; \
                       -r -g tofd -d / -s /sbin/nologin -c 'Robot ToF sensor daemon' tofd; \
                       -r -g padd -d / -s /sbin/nologin -c 'Robot gamepad intent client' padd; \
                       -r -g nfcd -d / -s /sbin/nologin -c 'Robot NFC reader daemon' nfcd; \
                       -r -g netpadd -d / -s /sbin/nologin -c 'Robot gamepad over UDP' netpadd; \
                       -r -g autod -d / -s /sbin/nologin -c 'Robot autonomous brain' autod; \
                       -r -g mapd -d / -s /sbin/nologin -c 'Robot onboard map' mapd"

SYSTEMD_PACKAGES = "${PN} ${PN}-padd"
SYSTEMD_SERVICE:${PN} = "robotd.service updaterd.service configd.service btd.service mediad.service tofd.service nfcd.service netpadd.service duck-gateway.service autod.service mapd.service robot-boot-check.timer microduck-voice-bank.service"
SYSTEMD_SERVICE:${PN}-padd = "padd.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
	# The release tree updaterd owns; units exec current/bin/.
	install -d ${D}/opt/robot/daemon/releases/${PV}/bin
	for b in ${D}${bindir}/*; do
		[ -e "$b" ] || continue
		mv "$b" ${D}/opt/robot/daemon/releases/${PV}/bin/
	done

	# Keep in step with the --include lines of the daemon's _build-release.yml.
	install -d ${D}/opt/robot/daemon/releases/${PV}/models
	install -m 0644 ${S}/duck-control/models/*.onnx ${S}/pet-detect/models/*.onnx \
		${D}/opt/robot/daemon/releases/${PV}/models/
	if [ -d ${S}/robotd/emotions ]; then
		install -d ${D}/opt/robot/daemon/releases/${PV}/emotions
		install -m 0644 ${S}/robotd/emotions/* ${D}/opt/robot/daemon/releases/${PV}/emotions/
	fi
	ln -snf releases/${PV} ${D}/opt/robot/daemon/current
	ln -snf releases/${PV} ${D}/opt/robot/daemon/golden

	install -d ${D}${bindir}
	ln -snf /opt/robot/daemon/current/bin/robotctl ${D}${bindir}/robotctl

	install -d ${D}${datadir}/bash-completion/completions
	install -m 0644 ${UNPACKDIR}/robotctl.bash_completion \
		${D}${datadir}/bash-completion/completions/robotctl

	install -d ${D}${sysconfdir}/profile.d
	sed -n "/<<'PROMPT'\$/,/^PROMPT\$/p" ${S}/scripts/setup-login.sh | sed '1d;$d' \
		> ${D}${sysconfdir}/profile.d/robot-name-prompt.sh
	if ! grep -q _robot_name_inject ${D}${sysconfdir}/profile.d/robot-name-prompt.sh; then
		bbfatal "scripts/setup-login.sh in this daemon release has no PROMPT heredoc to cut the name prompt from; update the extraction above"
	fi
	chmod 0644 ${D}${sysconfdir}/profile.d/robot-name-prompt.sh

	# One line per unit: scripts/bump-daemon.sh greps for "/<dir>/systemd/<unit> ".
	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${S}/robotd/systemd/robotd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/updater/systemd/updaterd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/configd/systemd/configd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/btd/systemd/btd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/mediad/systemd/mediad.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/tof/systemd/tofd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/nfc/systemd/nfcd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/netpadd/systemd/netpadd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/duck-gateway/systemd/duck-gateway.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/padd/systemd/padd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/autod/systemd/autod.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/mapd/systemd/mapd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/updater/systemd/robot-boot-check.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/updater/systemd/robot-boot-check.timer ${D}${systemd_system_unitdir}/
	install -d ${D}${prefix}/local/sbin
	install -m 0755 ${S}/scripts/robot-boot-check ${D}${prefix}/local/sbin/
	install -m 0755 ${S}/scripts/robot-rescue ${D}${prefix}/local/sbin/

	for u in ${S}/*/systemd/*.service ${S}/*/systemd/*.timer; do
		[ -e "$u" ] || continue
		[ -e ${D}${systemd_system_unitdir}/"${u##*/}" ] || \
			bbfatal "daemon ${PV} ships ${u#${S}/}, which this recipe does not install: add its install line, SYSTEMD_SERVICE entry and User="
	done

	install -m 0644 ${UNPACKDIR}/microduck-voice-bank.service ${D}${systemd_system_unitdir}/

	install -d ${D}${nonarch_base_libdir}/udev/rules.d
	install -m 0644 ${UNPACKDIR}/60-robot-i2c.rules \
		${D}${nonarch_base_libdir}/udev/rules.d/
	# padd reads a Nintendo pad's battery on its hidraw node; hooks/postinstall installs this elsewhere.
	install -m 0644 ${S}/padd/systemd/udev/70-robot-pad-hidraw.rules \
		${D}${nonarch_base_libdir}/udev/rules.d/

	install -d ${D}${sysconfdir}/robot
	install -m 0644 ${S}/deploy/robotd.toml ${D}${sysconfdir}/robot/
	install -m 0644 ${S}/deploy/updater.toml ${D}${sysconfdir}/robot/

	# Upstream ships a placeholder repo; an image is a deployment.
	sed -i -e 's|^repo\( *\)= *"ORG/duck-daemon"|repo\1= "pollen-robotics/microduck_daemon"|' \
		${D}${sysconfdir}/robot/updater.toml
	grep -q 'repo.*pollen-robotics/microduck_daemon' ${D}${sysconfdir}/robot/updater.toml \
		|| bbfatal "updater.toml repo rewrite did not apply -- upstream format changed?"

	install -d ${D}${sysconfdir}/robot/trusted_keys
	install -m 0644 ${S}/deploy/trusted_keys/*.pub ${D}${sysconfdir}/robot/trusted_keys/
	# Packaged in ${PN}-devkey.
	install -m 0644 ${S}/deploy/dev-key/team.dev.pub ${D}${sysconfdir}/robot/trusted_keys/

	install -d ${D}${sysconfdir}/systemd/journald.conf.d
	install -m 0644 ${S}/deploy/journald.conf.d/10-robot.conf \
		${D}${sysconfdir}/systemd/journald.conf.d/

	install -d ${D}${localstatedir}/lib/robot/updater

	# TEMPORARY, remove-with-real-radio: docs/agents/zero3-board.md, "Gamepad pairing".
	printf '%s\n' \
		'This board needs btd paused while a gamepad bonds.' \
		'robotctl reads only whether this file exists. See microduck_yocto' \
		'docs/agents/zero3-board.md, "Gamepad pairing" (TEMPORARY, remove-with-real-radio).' \
		> ${D}${localstatedir}/lib/robot/weird-ble
	chmod 0644 ${D}${localstatedir}/lib/robot/weird-ble
}

CONFFILES:${PN} = "${sysconfdir}/robot/robotd.toml ${sysconfdir}/robot/updater.toml"

PACKAGES =+ "${PN}-devkey ${PN}-bash-completion ${PN}-padd"

FILES:${PN}-padd = "/opt/robot/daemon/releases/${PV}/bin/padd ${systemd_system_unitdir}/padd.service \
    ${nonarch_base_libdir}/udev/rules.d/70-robot-pad-hidraw.rules"
FILES:${PN}-bash-completion = "${datadir}/bash-completion"
# The key and allow_dev_keys together: either alone is a board that refuses branch builds.
FILES:${PN}-devkey = "${sysconfdir}/robot/trusted_keys/team.dev.pub"
FILES:${PN} += " \
    /opt/robot/daemon \
    ${bindir}/robotctl \
    ${systemd_system_unitdir} \
    ${prefix}/local/sbin/robot-boot-check \
    ${prefix}/local/sbin/robot-rescue \
    ${nonarch_base_libdir}/udev/rules.d/60-robot-i2c.rules \
    ${sysconfdir}/robot \
    ${sysconfdir}/profile.d/robot-name-prompt.sh \
    ${sysconfdir}/systemd/journald.conf.d/10-robot.conf \
    ${localstatedir}/lib/robot \
"

pkg_postinst:${PN}-devkey() {
	cfg=$D${sysconfdir}/robot/updater.toml
	sed -i -e 's/^allow_dev_keys\( *\)= *false/allow_dev_keys\1= true/' "$cfg"
	if ! grep -q '^allow_dev_keys *= *true' "$cfg"; then
		echo "ERROR: could not enable allow_dev_keys in $cfg" >&2
		exit 1
	fi

	# Keep the file's own prose true; fail if upstream rewords it.
	sed -i -e 's/^# Both false, and this is the file that makes them false on a client robot\./# NOT both false: microduck-daemon-devkey flipped allow_dev_keys on this image./' "$cfg"
	if ! grep -q '^# NOT both false: microduck-daemon-devkey' "$cfg"; then
		echo "ERROR: could not rewrite the 'Both false' paragraph in $cfg;" >&2
		echo "       the daemon reworded it -- re-read it and fix this sed" >&2
		exit 1
	fi
}

RDEPENDS:${PN}-bash-completion += "${PN} bash-completion"
RDEPENDS:${PN}-devkey += "${PN}"
RDEPENDS:${PN} += "systemd ca-certificates networkmanager bluez5"
# hooks/postinstall's seeders fetch with curl.
RDEPENDS:${PN} += "curl"
# robot-rescue needs GNU mv -fT.
RDEPENDS:${PN} += "coreutils"
# mediad exits without webrtcsink; gstreamer1.0-rockchip carries the mpph264enc patch.
RDEPENDS:${PN} += "gstreamer1.0-plugins-rs gstreamer1.0-rockchip"
# The rest of mediad's elements, and media-ctl/v4l2-ctl. layer.conf: safe dep.
RDEPENDS:${PN} += "packagegroup-microduck-media"
# robotd plays sounds with aplay; pet-detect records with arecord (same package).
RDEPENDS:${PN} += "alsa-utils-aplay"
# No policy set: robotd is unhealthy and every update rolls back.
RDEPENDS:${PN} += "microduck-policies"
RDEPENDS:${PN} += "microduck-slot-health"
RRECOMMENDS:${PN}:append:aarch64 = " onnxruntime"
RRECOMMENDS:${PN} += "microduck-detector"
