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

# Upstream now ships a LICENSE file, so point at the whole thing rather than a
# line range in Cargo.toml. The old form pinned `license = "Apache-2.0"` by line
# number and md5, which survived exactly as long as nobody edited the manifest
# above it: at 6507d2e that declaration has moved from line 28 to line 88, and
# line 28 is now a comment about `ort` version floors. A whole-file checksum
# cannot drift that way.
#
# 86d3f3a9 is the standard Apache-2.0 text (201 lines). It differs from oe-core's
# well-known 89aea4e1 only because that one is the licence as distributed in
# common-licenses with no trailing appendix differences -- both are Apache-2.0,
# and the checksum here describes the file we actually fetch.
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=86d3f3a95c324c9479bd8986968f4327"

inherit cargo cargo-update-recipe-crates pkgconfig systemd useradd

# microduck_daemon is a public repo, so this fetches anonymously, and so do the
# robots: updaterd pulls release assets over plain HTTPS with no token. That is
# load-bearing -- updater-design.md §11 records that a *private* repo's
# releases/download/<tag>/<asset> URL returns 404 with or without a token, and
# only the api.github.com/.../releases/assets/<id> form works authenticated.
#
# Which release: none in this file; it comes in as the two variables below
# (README.md, "Which daemon the image seeds"), and without them the recipe skips
# itself rather than building a version nobody chose.
#
# SRCREV_daemon is still a RELEASE, never main: the manifest's source_revision,
# the commit CI built that release's binaries from -- not the tag, not main. That
# matters more than it looks. The recipe once pinned 6507d2e, 21 commits *ahead*
# of release 0.12.0, and both called themselves 0.12.0. updaterd compares
# versions, so it would have seen 0.12.0 == 0.12.0, concluded there was nothing to
# do, and never converged, while the two binaries differed. A version that does
# not identify the code makes "is this robot up to date?" unanswerable. AUTOREV on
# main would be the same mistake, and kas/microduck.yml rejects it by name.
#
# microduck-daemon-crates.inc is regenerated per build; the committed copy is
# only what the last regeneration wrote.
MICRODUCK_DAEMON_VERSION ??= ""
MICRODUCK_DAEMON_SRCREV ??= ""
PV = "${MICRODUCK_DAEMON_VERSION}"

python __anonymous() {
    if not d.getVar("MICRODUCK_DAEMON_VERSION") or not d.getVar("MICRODUCK_DAEMON_SRCREV"):
        raise bb.parse.SkipRecipe("no daemon release chosen: MICRODUCK_DAEMON_VERSION and "
                                  "MICRODUCK_DAEMON_SRCREV are unset. Build through "
                                  "scripts/build-hfjob.sh or scripts/build-local.sh, or see "
                                  "README.md 'Which daemon the image seeds'.")
}

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = "git://git@github.com/pollen-robotics/microduck_daemon.git;protocol=ssh;branch=main;name=daemon \
           git://github.com/pollen-robotics/bmi088-rs;protocol=https;nobranch=1;name=bmi088;destsuffix=bmi088-rs \
           file://60-robot-i2c.rules \
           file://robotctl.bash_completion \
           file://microduck-voice-bank.service \
"
# 0.15.3 was the first release that builds on oe-core wrynose's Rust 1.94.1
# (RUSTVERSION in tcmode-default.inc): 0.15.1 and 0.15.2 needed 1.99 for two
# atomics' try_update in mediad, and microduck#358 brought the floor back to 1.89
# and recorded 1.94 as the ceiling in CONTRIBUTING.md. A release that needs a
# newer Rust than that is a CI failure here, not a reason to pin an older one.
SRCREV_daemon = "${MICRODUCK_DAEMON_SRCREV}"
SRCREV_bmi088 = "bd113f317b14923f50f9a12a06678fe162b7fe06"
SRCREV_FORMAT = "daemon_bmi088"

# bmi088 is the one git dependency in the lockfile -- tof's BMI088 IMU driver,
# ours rather than crates.io's because the published ones stop at the raw
# registers. It has to be named here because cargo-update-recipe-crates only
# emits crates.io entries:
#
#     crates_candidates = list(filter(lambda c: 'crates.io' in c.get('source', ''), ...))
#
# so a git dep never reaches microduck-daemon-crates.inc and would be missing at
# build time. cargo_common.bbclass closes the gap: cargo_common_do_patch_paths
# walks SRC_URI for git entries that carry BOTH `name` and `destsuffix`, appends
#
#     [patch."https://github.com/pollen-robotics/bmi088-rs"]
#     bmi088 = { path = "<UNPACKDIR>/bmi088-rs" }
#
# to the cargo config, and strips the `source = "git...` lines from Cargo.lock so
# --frozen still passes. `name` must therefore be the *crate* name (bmi088), not
# the repository name (bmi088-rs).
#
# SRCREV_bmi088 is the commit, not the tag. v0.1.2 is an annotated tag, so
# `git ls-remote` shows the tag object 172ddbee while the commit underneath --
# the one the lockfile pins -- is bd113f31. Using the tag object here fetches
# something cargo then rejects.
#
# Unlike the crates.io list, this one does not follow the release CI picks. A
# release that moves bmi088 to another commit fails CI until it is bumped here.
#
# Naming the main repo `daemon` is forced by having two git URLs: SRCREV_FORMAT
# has to spell out both, and a bare SRCREV no longer applies to either.

require microduck-daemon-crates.inc

# No `S =` assignment -- wrynose errors out on S = "${UNPACKDIR}/git"; the default
# ${UNPACKDIR}/${BP} is correct. See AGENTS.md.

# rustls resolves to the aws-lc-rs provider, whose aws-lc-sys build script invokes
# CMake. There is no OpenSSL anywhere in the tree.
DEPENDS += "cmake-native"

# libudev, for padd only: gilrs depends on libudev-sys unconditionally on Linux and
# no feature disables it. duck-control/Cargo.toml calls that "a real cost" because
# their cargo-zigbuild cross-build has no pkg-config sysroot.
#
# Under Yocto it needs both halves, and missing either fails the build:
#   DEPENDS "systemd"   provides the target libudev to link against
#   inherit pkgconfig   provides the pkg-config *binary* that libudev-sys/build.rs
#                       shells out to. cargo_common already exports
#                       PKG_CONFIG_SYSROOT_DIR and friends, so without this the
#                       env looks right and the build still dies with
#                       "The pkg-config command could not be found."
DEPENDS += "systemd"

# GStreamer, for mediad. It links the bindings rather than driving gst-launch:
# gstreamer, gstreamer-app, gstreamer-webrtc, gstreamer-video and glib, each of
# which has a -sys crate whose build.rs pkg-configs a .pc out of the sysroot.
#
# They are declared under
#
#     [target.'cfg(target_os = "linux")'.dependencies]
#
# rather than plain [dependencies], which is easy to miss when reading the
# manifest and is exactly how this was missed the first time -- the 0.12.0 build
# failed at
#
#     error: failed to run custom build command for `gstreamer-sys v0.24.5`
#     Package 'gstreamer-1.0' not found
#
# tof's bmi088 hides in the same kind of section. When adding a workspace member,
# read the target-conditional tables too.
#
# Which recipe provides what:
#   glib-2.0                    glib-2.0.pc, gobject-2.0.pc, gio-2.0.pc
#   gstreamer1.0                gstreamer-1.0.pc, gstreamer-base-1.0.pc
#   gstreamer1.0-plugins-base   gstreamer-app-1.0.pc, gstreamer-video-1.0.pc,
#                               gstreamer-sdp-1.0.pc
#   gstreamer1.0-plugins-bad    gstreamer-webrtc-1.0.pc -- which exists only
#                               because our bbappend turns the webrtc
#                               PACKAGECONFIG on; without it this would fail with
#                               the same shape of error as above.
DEPENDS += "glib-2.0 gstreamer1.0 gstreamer1.0-plugins-base gstreamer1.0-plugins-bad"

# Everything the board can use, expressed as the workspace minus four exclusions
# rather than a list of packages to include. That is the repo's own convention --
# its Cargo.toml sets default-members for exactly this reason, so "a new daemon is
# picked up without anybody remembering" -- and it means a crate added upstream
# gets built here without editing this line.
#
# The four exclusions:
#   xtask         release tooling that links the full minisign and can sign
#   test-support  test scaffolding
#   duckctl       the laptop-side client; cross-compiling a Bluetooth stack for a
#                 board that must never run it, as upstream's own comment says
#   duck-ether    not in upstream's default-members either
#
# Everything else builds, including mediad, tof, sounds, duck-detect and
# pet-detect.
CARGO_BUILD_FLAGS += "--workspace --exclude xtask --exclude test-support --exclude duckctl --exclude duck-ether"

# Both units hard-require this group; updater/systemd/sysusers.d/robot.conf exists
# upstream to create it at first boot. Creating it at image build time instead is
# deterministic and does not depend on sysusers ordering, so that file is not
# installed.
#
# btd runs as its own unprivileged user (btd/systemd/sysusers.d/btd.conf upstream:
# `u btd - "Robot BLE transport adapter" - -`) because it is the process parsing
# bytes from anyone in radio range. Its unit also declares
# SupplementaryGroups=robot bluetooth, and systemd refuses to start a unit whose
# supplementary groups do not exist -- so `bluetooth` is created here even though
# it grants nothing on this image: oe-core's bluez5 D-Bus policy has no
# group="bluetooth" rule, only `user="root"` and a permissive `context="default"`.
# The group exists to satisfy systemd, not to carry a permission.
#
# robot-account is the opposite case: its whole purpose is the permission. It is to
# own /var/lib/robot/hf-token (/etc/robot/hf-token before daemon PR #483, which moved
# it off the slot), the owner's Hugging Face bearer token, so that only mediad
# reads it rather than everything in `robot` (btd, padd, tofd, every operator
# shell) -- microduck#230. The daemon still gives it group `robot` today. mediad reaches it through its unit's
# SupplementaryGroups=, like `robot`, so no membership is needed; updaterd writes
# the file as root and only needs the name to resolve. Upstream creates it in
# updater/systemd/sysusers.d/robot.conf, which is not installed here, so without
# this mediad.service refuses to start and the camera is dead. It is created
# ahead of the SRCREV_daemon bump that needs it: an unreferenced group is inert.
USERADD_PACKAGES = "${PN}"
# nfcd is both the unit's User= and the group microduck-nfc's udev rule gives the
# beta's reader (/dev/spidev1.0) to, so the daemon reaches it as its primary group.
GROUPADD_PARAM:${PN} = "-r robot; -r robot-account; -r bluetooth; -r btd; -r mediad; -r tofd; -r padd; -r i2c; -r nfcd; -r netpadd"
USERADD_PARAM:${PN} = "-r -g btd -d / -s /sbin/nologin -c 'Robot BLE transport adapter' btd; \
                       -r -g mediad -d / -s /sbin/nologin -c 'Robot media and WebRTC gateway' mediad; \
                       -r -g tofd -d / -s /sbin/nologin -c 'Robot ToF sensor daemon' tofd; \
                       -r -g padd -d / -s /sbin/nologin -c 'Robot gamepad intent client' padd; \
                       -r -g nfcd -d / -s /sbin/nologin -c 'Robot NFC reader daemon' nfcd; \
                       -r -g netpadd -d / -s /sbin/nologin -c 'Robot gamepad over UDP' netpadd"

# mediad, tofd and padd get their users and groups even though their units are
# not enabled here, because systemd refuses to start a unit whose User= or
# SupplementaryGroups= do not exist -- so creating them is what makes
# `systemctl enable mediad` work on a robot that does have the hardware, with no
# rebuild. The names and descriptions match upstream's own sysusers.d files.
#
# The supplementary groups each unit asks for:
#   mediad   video render robot     video/render already exist (udev-conf-rockchip
#                                   and the DRM rules put the VPU and render nodes
#                                   in them)
#   tofd     i2c robot              i2c does NOT exist on a stock image, hence the
#                                   groupadd above and the udev rule below
#   padd     input robot            input already exists and /dev/input/event* is
#                                   already root:input
#   nfcd     dialout robot          dialout already exists; it is the bench USB
#                                   reader's /dev/ttyACM*
#   netpadd  robot                  nothing else: the pad is on the network
#
# netpadd is enabled but stays down: its ExecCondition= runs only when
# `[netpad] enabled` is set, and padd stands down for it then. Without the unit,
# setting that key left the robot with no pad at all -- padd stood down because
# the netpadd binary ships, and nothing took over.

# All nine units, all enabled. The robot is the common case: a board with
# servos, a camera, a ToF sensor and a gamepad should come up working, and
# needing to remember an enable command per daemon is how a robot ends up half
# running with nothing obviously wrong.
#
# The cost lands on a bare bring-up board, which has none of that hardware and
# where none of these three carries a Condition= to skip itself -- so mediad,
# tofd and padd fail there (nfcd does not: with no reader it logs once and
# retries the port every thirty seconds) and `systemctl --failed` stops being a clean health
# signal. That is the right way round: on a bring-up board someone is already
# watching and
#
#     systemctl disable --now mediad tofd padd
#
# is a one-off, whereas on a robot the alternative is a daemon that silently
# never started.
#
# padd.service is assigned to ${PN}-padd rather than ${PN}, because the unit is
# packaged with its binary (see the FILES split below) and systemd.bbclass
# expects a service to be listed against the package that ships it.
# SYSTEMD_PACKAGES has to name both, since it otherwise defaults to ${PN} alone
# and padd.service would be installed but never enabled.
#
# robot-boot-check.service has no [Install] by design -- only its timer starts it
# -- so the timer is what gets enabled.
SYSTEMD_PACKAGES = "${PN} ${PN}-padd"
SYSTEMD_SERVICE:${PN} = "robotd.service updaterd.service configd.service btd.service mediad.service tofd.service nfcd.service netpadd.service robot-boot-check.timer microduck-voice-bank.service"
SYSTEMD_SERVICE:${PN}-padd = "padd.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
	# Install as a release tree, the layout updaterd owns:
	#
	#   /opt/robot/daemon/releases/<ver>/bin/...
	#   current → releases/<ver>     units point here
	#   golden  → releases/<ver>     never pruned; the rescue net reads it
	#
	# The units are installed verbatim, ExecStart untouched. That is the whole
	# point of this change. They already say /opt/robot/daemon/current/bin/, and
	# the previous packaging rewrote them to ${bindir} -- "option 2", distro-managed
	# binaries -- which quietly disabled the update system underneath: updaterd
	# would verify a signed release, extract it, swap `current`, report success,
	# and systemd would go on running the old binary from /usr/bin. An update that
	# installs correctly and changes nothing is the worst shape of failure.
	#
	# Atomicity is a rename(2) of the `current` symlink on one filesystem
	# (updater-design.md §7.1), so /opt/robot/daemon must not straddle a mount.
	#
	# Everything cargo installed moves, rather than a hand-kept list of names.
	# The list was wrong the moment it was written -- it omitted padd, which
	# would have stayed in ${bindir}, been swept into the main package by the
	# default ${bindir}/* glob, and left ${PN}-padd shipping nothing but a
	# padd.service whose ExecStart points at a path no package provides. A
	# failed unit on every boot of both images, and the gamepad split defeated.
	#
	# A glob is also what updaterd assumes: the orphan check refuses a release
	# that lacks a binary an installed unit execs, so a workspace binary missing
	# from the release tree is not a packaging nit, it is an unbootable update.
	# Adding a member upstream must not require editing a list here to stay true.
	install -d ${D}/opt/robot/daemon/releases/${PV}/bin
	for b in ${D}${bindir}/*; do
		[ -e "$b" ] || continue
		mv "$b" ${D}/opt/robot/daemon/releases/${PV}/bin/
	done
	ln -snf releases/${PV} ${D}/opt/robot/daemon/current
	ln -snf releases/${PV} ${D}/opt/robot/daemon/golden

	# robotctl is what a person types, so keep it on PATH. A symlink through
	# `current` rather than a copy, so it follows the active release instead of
	# pinning the seed forever.
	install -d ${D}${bindir}
	ln -snf /opt/robot/daemon/current/bin/robotctl ${D}${bindir}/robotctl

	# Tab-completion for it, in bash-completion's *dynamic* directory rather than
	# the ${sysconfdir}/bash_completion.d/ that scripts/setup-login.sh uses.
	#
	# Same file either way -- it asks the binary for its own completions -- but
	# /etc/bash_completion.d is sourced by every interactive bash at startup, so
	# an eager copy spawns a robotctl on every login (measured on duck-882e: a
	# 0.14 s login shell against 0.05 s), where this one is read the first time
	# somebody types `robotctl<TAB>` and never otherwise.
	#
	# That saving is not ours yet, though. Pulling bash-completion in creates
	# /etc/bash_completion.d, which is precisely the guard that has been stopping
	# setup-login.sh's install_completions() -- so the first daemon update after
	# this image writes the eager copy, it registers the completion first, and the
	# file installed here never fires. Nothing breaks, both being the same loader,
	# but the lazy path only becomes real once setup-login.sh writes into
	# ${datadir}/bash-completion/completions too, which is a microduck_daemon
	# change and a separate PR.
	install -d ${D}${datadir}/bash-completion/completions
	install -m 0644 ${UNPACKDIR}/robotctl.bash_completion \
		${D}${datadir}/bash-completion/completions/robotctl

	# The robot's name in the shell prompt, `microduck@microduck-beta (sky-gtc):~$`,
	# from the snippet scripts/setup-login.sh writes to /etc/profile.d. On a board
	# that has taken an update the postinstall hook has written it already; on a
	# fresh image nothing has run setup-login.sh, so every duck flashed from one
	# image showed the same bare hostname until its first update. Cut out of the
	# script rather than copied into files/, so there is one snippet and it cannot
	# drift; the first update then rewrites this same path with the same text.
	# In ${PN}, not a dev-only package: the hook writes it on every board, shipping
	# ones included, so leaving it out would only make a fresh robot differ from an
	# updated one. Bash syntax behind a $BASH_VERSION guard; bash is in both images.
	install -d ${D}${sysconfdir}/profile.d
	sed -n "/<<'PROMPT'\$/,/^PROMPT\$/p" ${S}/scripts/setup-login.sh | sed '1d;$d' \
		> ${D}${sysconfdir}/profile.d/robot-name-prompt.sh
	if ! grep -q _robot_name_inject ${D}${sysconfdir}/profile.d/robot-name-prompt.sh; then
		bbfatal "scripts/setup-login.sh in this daemon release has no PROMPT heredoc to cut the name prompt from; update the extraction above"
	fi
	chmod 0644 ${D}${sysconfdir}/profile.d/robot-name-prompt.sh

	# Units, verbatim: their ExecStart already points into current/.
	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${S}/robotd/systemd/robotd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/updater/systemd/updaterd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/configd/systemd/configd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/btd/systemd/btd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/mediad/systemd/mediad.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/tof/systemd/tofd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/nfc/systemd/nfcd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/netpadd/systemd/netpadd.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/padd/systemd/padd.service ${D}${systemd_system_unitdir}/

	# The boot recovery net, verbatim from the release: the timer runs
	# robot-boot-check a second after boot, which hands a release whose daemons did
	# not come up to robot-rescue (current -> golden, reboot). Both units name
	# /usr/local/sbin, so that is where the scripts go: outside the release tree,
	# because they run exactly when the release cannot be trusted.
	install -m 0644 ${S}/updater/systemd/robot-boot-check.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${S}/updater/systemd/robot-boot-check.timer ${D}${systemd_system_unitdir}/
	install -d ${D}${prefix}/local/sbin
	install -m 0755 ${S}/scripts/robot-boot-check ${D}${prefix}/local/sbin/
	install -m 0755 ${S}/scripts/robot-rescue ${D}${prefix}/local/sbin/

	install -m 0644 ${UNPACKDIR}/microduck-voice-bank.service ${D}${systemd_system_unitdir}/

	# /dev/i2c-* arrives 0600 root:root, so tofd's SupplementaryGroups=i2c buys it
	# nothing without this -- the same shape of silent failure that left
	# /dev/mpp_service unopenable by a non-root mediad until udev-conf-rockchip
	# was installed. Matched on the kernel name, as meta-rockchip's own rule does.
	install -d ${D}${nonarch_base_libdir}/udev/rules.d
	install -m 0644 ${UNPACKDIR}/60-robot-i2c.rules \
		${D}${nonarch_base_libdir}/udev/rules.d/

	# The base config. CONFFILES only protects it across a package upgrade: a RAUC update
	# rewrites the whole slot, /etc with it, so per-robot edits live in
	# /var/lib/robot/robotd.toml, layered over this file (daemon PR #483). updater.toml has
	# no such layer yet, and an OS update resets it.
	install -d ${D}${sysconfdir}/robot
	install -m 0644 ${S}/deploy/robotd.toml ${D}${sysconfdir}/robot/
	install -m 0644 ${S}/deploy/updater.toml ${D}${sysconfdir}/robot/

	# The shipped updater.toml names a placeholder repo, so a stock image polls
	# https://api.github.com/repos/ORG/duck-daemon/releases and logs a 404 every
	# check_interval (6h) forever. Point it at the real one. Upstream leaves it a
	# placeholder deliberately -- it is a per-deployment value, and provisioning
	# fills it in -- but an image *is* a deployment, so it belongs here.
	sed -i -e 's|^repo\( *\)= *"ORG/duck-daemon"|repo\1= "pollen-robotics/microduck_daemon"|' \
		${D}${sysconfdir}/robot/updater.toml
	grep -q 'repo.*pollen-robotics/microduck_daemon' ${D}${sysconfdir}/robot/updater.toml \
		|| bbfatal "updater.toml repo rewrite did not apply -- upstream format changed?"

	# minisign trust anchor. All three keys ship from the first image on purpose so
	# key rotation never needs a reflash.
	install -d ${D}${sysconfdir}/robot/trusted_keys
	install -m 0644 ${S}/deploy/trusted_keys/*.pub ${D}${sysconfdir}/robot/trusted_keys/

	# The dev key, staged but packaged separately (see ${PN}-devkey). It lives in
	# deploy/dev-key/, not deploy/trusted_keys/, so the glob above cannot pick it
	# up by accident -- which is upstream's design and worth preserving.
	install -m 0644 ${S}/deploy/dev-key/team.dev.pub ${D}${sysconfdir}/robot/trusted_keys/

	# Storage=persistent, SystemMaxUse=200M, ForwardToSyslog=no.
	install -d ${D}${sysconfdir}/systemd/journald.conf.d
	install -m 0644 ${S}/deploy/journald.conf.d/10-robot.conf \
		${D}${sysconfdir}/systemd/journald.conf.d/

	install -d ${D}${localstatedir}/lib/robot/updater

	# TEMPORARY, remove-with-real-radio -- the btd-pause marker for gamepad pairing.
	#
	# The `--pause-btd-on-pair` half of microduck_daemon's scripts/setup-board.sh,
	# baked in because provision-board.sh is the Armbian path and never runs against
	# a Yocto board. robotctl reads only this file's existence (WEIRD_BLE_MARKER in
	# robotctl/src/main.rs) and stops btd for the pairing window of `robotctl pad
	# pair`. Harmless where it is not needed: it costs a pad-pairing window with no
	# BLE provisioning, and nothing else. docs/agents/zero3-board.md has the
	# measurement and the opt-out; deleting the file is how a board opts out.
	#
	# Under ${localstatedir}, not ${sysconfdir}, because that is where robotctl
	# looks; it is state, not configuration, and so not a CONFFILE either -- there
	# is nothing to merge.
	printf '%s\n' \
		'This board needs btd paused while a gamepad bonds.' \
		'robotctl reads only whether this file exists. See microduck_yocto' \
		'docs/agents/zero3-board.md, "Gamepad pairing" (TEMPORARY, remove-with-real-radio).' \
		> ${D}${localstatedir}/lib/robot/weird-ble
	chmod 0644 ${D}${localstatedir}/lib/robot/weird-ble
}

CONFFILES:${PN} = "${sysconfdir}/robot/robotd.toml ${sysconfdir}/robot/updater.toml"

# padd split out so a gamepad stack can be dropped without rebuilding, and so the
# libudev runtime dependency is visible rather than buried in the main package.
# Its unit travels with it: a padd.service in the main package would reference a
# binary that is not necessarily installed. PACKAGES =+ puts this package ahead
# of ${PN}, so it claims both before ${PN}'s broader globs do.
#
# Note the split now only governs the *seed*. updaterd replaces the whole release
# tree on update, so a later release reinstates padd whether or not this package
# was installed -- the orphan check (updater-design.md §7.3) keeps that honest by
# refusing a release that lacks a binary an installed unit execs.
PACKAGES =+ "${PN}-padd"
FILES:${PN}-padd = "/opt/robot/daemon/releases/${PV}/bin/padd ${systemd_system_unitdir}/padd.service"

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

# Completions as their own package, for the same reason padd and the dev key are:
# so an image takes them by name or not at all.
#
# It is not the 300 bytes, it is the RDEPENDS: bash-completion brings a 132 KB
# dispatcher, its profile snippet and an empty directory -- the megabyte of
# completion scripts is oe-core's separate bash-completion-extra package, which
# nothing here asks for. Small, then, but a shipping robot is not where anyone
# types commands, so nothing there should pay for a Tab key.
# microduck-image-dev installs it; microduck-image cannot get it by accident.
#
# That RDEPENDS is also what makes this work rather than merely exist:
# bash-completion ships ${sysconfdir}/profile.d/bash_completion.sh, which poky's
# /etc/profile sources for every login shell, and that is what defines the dynamic
# loader that goes looking in ${datadir}/bash-completion/completions. Without the
# package, the file installed above is read by nothing -- which is exactly the state
# this image was in: setup-login.sh's install_completions() returns early when
# /etc/bash_completion.d does not exist, and that directory comes from this package
# too.
#
# FILES is the whole ${datadir}/bash-completion tree rather than the one path, which
# is what oe-core's own bash-completion.bbclass uses -- the class is not inherited
# here only because its `DEPENDS:append = " bash-completion"` would add a build edge
# for a recipe that generates nothing at build time.
PACKAGES =+ "${PN}-bash-completion"
FILES:${PN}-bash-completion = "${datadir}/bash-completion"
RDEPENDS:${PN}-bash-completion += "${PN} bash-completion"

# The dev-board trust anchor, as its own package so it can only reach an image
# that asks for it by name. microduck-image-dev installs it; microduck-image
# cannot get it by accident.
#
# Both halves in one package, deliberately. install-dev.md is emphatic that the
# key and the flag are useless apart -- "either alone leaves a board that still
# refuses branch builds" -- and a board that looks provisioned but silently
# refuses `--ref` is a bad afternoon. Packaging them together makes half-applied
# impossible.
#
# What this buys: `robotctl update apply --ref main` and
# `provision-board.sh --ref BRANCH`. It does NOT make a dev board auto-track a
# branch. updaterd's newest_version skips anything GitHub flags as a prerelease
# and anything carrying a semver prerelease component, so the 6-hourly check
# still resolves stable on a dev board too; branch builds are always an explicit
# act. That filter is what keeps a customer robot off candidate builds, and it is
# not configurable away -- a board pointed at another channel by editing
# tag_prefix still refused, because "the prefix said where to look, and the
# prerelease filter refused to look".
#
# The `.dev.` infix in the filename is load-bearing: updaterd classifies a
# trusted key as a dev key by name, so team.dev.pub landing under any other name
# would be trusted as a *release* key.
PACKAGES =+ "${PN}-devkey"
FILES:${PN}-devkey = "${sysconfdir}/robot/trusted_keys/team.dev.pub"
RDEPENDS:${PN}-devkey += "${PN}"

pkg_postinst:${PN}-devkey() {
	cfg=$D${sysconfdir}/robot/updater.toml
	sed -i -e 's/^allow_dev_keys\( *\)= *false/allow_dev_keys\1= true/' "$cfg"
	if ! grep -q '^allow_dev_keys *= *true' "$cfg"; then
		echo "ERROR: could not enable allow_dev_keys in $cfg" >&2
		exit 1
	fi

	# And the sentence above it, which upstream wrote for a client robot: "Both false,
	# and this is the file that makes them false". Left standing, the one line in
	# updater.toml that is about trust disagrees with the paragraph introducing it --
	# on a board where root has no password, so "somebody edited this and missed the
	# comment" is a reading with real consequences. Its file header asks for better:
	# "every value below is either a decision or a fact".
	#
	# Only the first sentence goes. The rest of the paragraph -- what the flag allows,
	# and that /etc survives an update -- is what a reader of a dev board wants, and is
	# still true. One line replaces one line: a multi-line right-hand side would need
	# `\n`, which BusyBox sed on a target-run postinst does not owe us.
	sed -i -e 's/^# Both false, and this is the file that makes them false on a client robot\./# NOT both false: microduck-daemon-devkey flipped allow_dev_keys on this image./' "$cfg"

	# Upstream prose is not an API. If the sentence is ever reworded, this rewrite
	# silently stops applying and the board goes back to shipping a file that
	# contradicts itself -- so fail the build instead, the way the repo rewrite above
	# does. Assert the sentence we wrote is present, not that theirs is gone: a
	# rewording that drops "Both false" defeats the sed and a negative grep both.
	if ! grep -q '^# NOT both false: microduck-daemon-devkey' "$cfg"; then
		echo "ERROR: could not rewrite the 'Both false' paragraph in $cfg;" >&2
		echo "       the daemon reworded it -- re-read it and fix this sed" >&2
		exit 1
	fi
}

# updaterd shells out to systemctl for its on_apply restart action, and every
# HTTPS fetch needs the system trust store.
#
# networkmanager and bluez5 are new with configd/btd, and declared rather than
# left to the image: configd drives NetworkManager over D-Bus and is useless
# without it, and btd talks to bluetoothd the same way. Both happen to be in
# microduck-image already, which is exactly how a missing dependency stays
# invisible until someone builds a leaner image -- the same way libnice reached
# the rootfs as a shlib side effect while webrtcbin had no ICE.
RDEPENDS:${PN} += "systemd ca-certificates networkmanager bluez5"

# curl: hooks/postinstall runs scripts/seed-policies.sh and scripts/seed-detector.sh on
# every update, and both are POSIX shell fetching with curl. Without it every seeder fails
# instantly, the hook warns (never fatal), and the update completes having seeded nothing.
# openssl is already in the rootfs via ssh-server-openssh, so this costs curl alone.
#
# Seeding the policy set in the image (recipes-microduck/microduck-policies, which has the
# why in full) covers a fresh board; this is what lets a board *follow* the pin when a
# later release moves POLICY_VERSION. updaterd's own policy installer speaks rustls and
# needs no curl, but it is reached from `robotctl policy update` alone.
RDEPENDS:${PN} += "curl"

# robot-rescue swaps current -> golden with GNU `mv -fT`, falling back to BSD
# `mv -fh` when `mv --version` fails. Busybox's mv has neither, so on an image
# without coreutils the rescue would fail at the one moment it exists for.
RDEPENDS:${PN} += "coreutils"

# webrtcsink, and it is a hard dependency rather than a recommendation: mediad
# calls ElementFactory::make("webrtcsink") during pipeline construction and exits
# 1 when it is absent, so a rootfs without this has a unit that crash-loops from
# first boot. Observed on 2026-09-15 -- restart counter 37 before anyone looked.
#
# gstreamer1.0-plugins-rs also carries the patch that teaches webrtcsink about
# mpph264enc, and gstreamer1.0-rockchip carries the one that lets mpph264enc
# admit constrained-baseline. Neither is optional for video: without the second,
# webrtcsink's discovery finds no codec at all and every session dies on
# not-negotiated, because mediad restricts video-caps to H.264.
#
# gstreamer1.0-rockchip is named here for the same reason networkmanager is --
# it arrives in these images anyway, via the machine's own gstreamer stack, and
# that is exactly how a dependency stays invisible until a leaner image drops it.
RDEPENDS:${PN} += "gstreamer1.0-plugins-rs gstreamer1.0-rockchip"

# duck-control, duck-detect and pet-detect all take ort 2.0.0-rc.11 with the
# "load-dynamic" feature, so libonnxruntime is dlopened at first use rather than
# linked. The workspace pins a floor of 1.23 (an earlier board shipped 1.20.1
# against an ort that panics below that) and a target of 1.28.0.
#
# Packaged as recipes-microduck/onnxruntime (Microsoft's prebuilt aarch64 tarball, the
# same one scripts/setup-board.sh fetches). RRECOMMENDS rather than RDEPENDS because
# robotd installs and starts fine without it and only fails when asked to walk, so a
# minimal image can drop it. ORT_DYLIB_PATH overrides the location. aarch64 only,
# like the tarball: elsewhere (yocto-check-layer's x86 world) it does not exist.
RRECOMMENDS:${PN}:append:aarch64 = " onnxruntime"

# The policy set. RDEPENDS, not RRECOMMENDS: a powered robot with no set reports
# `unhealthy` (robotd/src/main.rs, policy_error), and unhealthy is what the health gate
# rolls a release back on -- so every *attempted* update reverts. Seeded here because an
# image installs through neither hooks/postinstall nor scripts/install.sh; the recipe
# carries the rest of the story. Bump it with POLICY_VERSION in the daemon's own
# scripts/seed-policies.sh (v5 at 0.13.0 to 0.15.1, v7 from 0.15.2 to 0.16.1, v8 from
# 0.16.2).
RDEPENDS:${PN} += "microduck-policies"

# RAUC marks a slot good only if the same check robot-boot-check makes passes:
# its own recipe, installed wherever the daemon is.
RDEPENDS:${PN} += "microduck-slot-health"
