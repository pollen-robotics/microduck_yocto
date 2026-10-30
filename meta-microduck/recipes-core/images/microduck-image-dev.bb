SUMMARY = "microduck robot OS -- dev image"
DESCRIPTION = "microduck-image plus what a developer needs and a robot must not \
ship. A strict superset: it adds, never substitutes, so anything verified on a \
dev board holds for the shipping image too."

require recipes-core/images/microduck-image.bb

# The reason this recipe exists.
#
# These three were EXTRA_IMAGE_FEATURES in kas/microduck.yml, which applies to
# every image built from that config, under a comment asking whoever ships an
# image to remember to delete the line. Here they are scoped to a target whose
# name says what it is, so microduck-image cannot have them.
#
# This is also the one dev/prod difference that genuinely cannot be applied as
# configuration afterwards. The dev key and allow_dev_keys can (see below), but a
# login cannot: you need one before you can configure anything, and with no
# package manager on the robot there is no way to add one later either.
# oelint-adv flags these in any image; this is the one place they are allowed.
# nooelint: oelint.var.badimagefeature
IMAGE_FEATURES += "allow-empty-password allow-root-login empty-root-password"

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

# The two GStreamer tracer plugins, each split out of its recipe so the shipping
# image does not carry them. `GST_TRACERS=latency(flags=pipeline+element)` and
# the Rust `buffer-lateness`, `queue-levels` and `pipeline-snapshot` (SIGUSR1
# writes .dot files to GST_DEBUG_DUMP_DOT_DIR) are how you find where the WebRTC
# path spends its milliseconds without instrumenting mediad. The tracer *hooks*
# are compiled into libgstreamer for both images -- oe-core builds it without
# them, see gstreamer1.0_%.bbappend -- only the plugins are dev-only.

# microduck-daemon-devkey is what makes this a *dev board* in updaterd's sense:
# it installs team.dev.pub and flips allow_dev_keys, so `robotctl update apply
# --ref main` and `provision-board.sh --ref BRANCH` work. Both halves ship
# together because either alone leaves a board that still refuses branch builds.
#
# This is the reason I argued against baking the key in earlier and was wrong:
# the objection was that a key without the flag saves no step, which is true --
# and is an argument for shipping both, not neither.
#
# It belongs here and nowhere else. A dev key on a customer robot would let
# anything a teammate builds install itself; microduck-image gets
# allow_dev_keys = false and the three release keys only, and cannot take a
# branch build even if it somehow resolved the tag, because the signature check
# fails rather than a policy check. This image is already must-not-ship for the
# password-less root login, so it changes no classification.
#
# Note it does NOT make this board auto-track main: updaterd's periodic check
# still skips prereleases, so branch installs stay an explicit act.
#
# rauc-conf-dev-ca is the same thing one level down, for OS bundles: it adds the
# development CA to RAUC's keyring, which otherwise trusts the production CA only.
# Every CI bundle is dev-signed, so without it this board would take nothing but
# production-signed builds. microduck-osupdate follows `dev` on a board that has
# it and `stable` on one that does not.

# microduck-daemon-bash-completion is `robotctl<TAB>`, and it is here rather than in
# the shipping image for the same reason as everything else on this list: nobody types
# commands on a shipping robot, so nothing there should pay for a Tab key. It pulls in
# bash-completion, which is the piece that was actually missing -- bash itself is
# already in both images. The daemon recipe's package block has the chain.
#
# MICRODUCK_RADIO_DEV_PACKAGES is aic8800-bt-test on the Zero 3W: AICSemi's own
# bt_test, which talks to the chip directly, so it tells a hardware fault from a
# stack fault. The controller itself works -- aic8800-bt-attach.service brings it
# up with hciattach (never btattach; AGENTS.md says why) -- so this is only a
# diagnostic, and the shipping image does not carry it.

# coreutils and util-linux instead of trusting busybox. Busybox's applets are
# subtly reduced in ways that cost debugging time rather than being a mild
# inconvenience -- measured over ssh on the board 2026-09-10: `head -4` is
# rejected outright (busybox wants `head -n 4`), and there is no `timeout`, no
# `findmnt` and no `systemd-analyze` at all, which broke three diagnostic scripts
# mid-run. update-alternatives puts the GNU versions ahead of the applets, so a
# script written against either one works.
#
# evtest is the gamepad diagnostic (padd itself comes from microduck-image.bb):
# it is how you tell a pad that never bonded from one that bonded and sends
# nothing, which is the distinction the whole of
# microduck_daemon/docs/robot/pair-a-gamepad.md turns on.
#
# tcpdump for the radio (iw is already there, from packagegroup-base-wifi via
# MACHINE_FEATURES). nmcli reports that a link is associated but not
# why it is bad, and this radio is the component the BLE workarounds in
# install-dev.md exist to work around.
#
# Still absent here, exactly as in the shipping image: gdb, build-essential,
# *-dev packages, tools-sdk. Cross-compile against the SDK
# (`bitbake microduck-image -c populate_sdk`).

# Deliberately NOT here: the team dev key, and allow_dev_keys = true.
#
# Both are needed before a board will take dev builds, and the key alone does
# nothing -- so baking it in would save no step while putting a trust anchor into
# an artifact that can be copied to a board which should not have one. The flag is
# a one-line edit to /etc/robot/updater.toml, which the daemon recipe already
# ships with `allow_dev_keys = false` present to be flipped, and
# microduck_daemon/scripts/install.sh does both halves together with validation.
# Per-board and revocable is the right shape for a trust decision:
# see microduck_daemon/docs/robot/install-dev.md.
#
# MICRODUCK_MOTOR_UART is not settable here either, tempting as it is to keep the
# serial console on dev boards. It is read by linux-rockchip_6.1.bbappend (to add
# motorbus.cfg to SRC_URI) and by microduck-common.inc (SERIAL_CONSOLES), neither
# of which can see a variable set in an image recipe. Varying it needs a separate
# MACHINE or a build-time flag, not an image.
