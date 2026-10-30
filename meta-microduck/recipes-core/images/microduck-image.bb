SUMMARY = "microduck robot OS"
LICENSE = "MIT"

require recipes-core/images/core-image-base.bb

# meta-rockchip: produces the .wic in deploy/.
inherit rockchip-image extrausers

# The operator account, the same as the Radxa images': microduck / microduck,
# sudo with that password. Everything the daemon's tooling assumes defaults to
# it -- duckctl ssh, scripts/dev-push.sh and provision-board.sh all log in as
# `microduck@` and sudo from there. robot lets robotctl read the daemons'
# sockets without root (scripts/install.sh adds its operator the same way);
# audio, video, dialout and i2c are the devices a person debugging a duck pokes
# at by hand. The hash is `openssl passwd -6 -salt microduckbeta microduck`,
# fixed so the image stays reproducible; '$' is escaped for bitbake.
MICRODUCK_OPERATOR_HASH = "\$6\$microduckbeta\$lxVesOQbjM8IXwxq5s/GpwW0KnK1YuspITBn7crCGbeuodZd.PBnJJIS5E32lQK4/mugkqFe36SAr6iyo82Gu0"
EXTRA_USERS_PARAMS = "useradd -m -s /bin/bash -G robot,sudo,audio,video,dialout,i2c,plugdev,input -p '${MICRODUCK_OPERATOR_HASH}' microduck;"
# Group sudo may sudo: recipes-extended/sudo/sudo_%.bbappend.

# The card image to download and flash is the compressed .wic.zst plus its .bmap:
# `bmaptool copy` writes only the blocks in use, instead of dd copying all 13 GB.
# Plain `wic` stays in the list. oe-core deletes a type that is not listed as soon
# as it has been converted (image.bbclass, rm_tmp_images), and a beta board's
# eMMC is flashed from the plain .wic with `rkdeveloptool wl`
# (docs/agents/beta-board.md). build-hfjob.sh leaves it out of the bucket instead.
#
# wic.zst.sha256sum is oe-core's sha256sum conversion: `sha256sum -c` on it
# checks a download before it goes anywhere near a card. bmaptool checks the
# data again while flashing, against the per-range sums in the .bmap.
IMAGE_FSTYPES += "wic.zst wic.zst.sha256sum wic.bmap"

# Two rockchip outputs nothing here uses, 14.5 GB per build between them:
# - .ufs.wic, a second 13 GB copy with 4K sectors for UFS storage (we boot from SD)
# - update.img, for Rockchip's own flashing tool (we use dd/bmaptool)
# These are no-ops rather than an IMAGE_POSTPROCESS_COMMAND:remove, because
# rockchip-image.bbclass appends them inside ";"-joined words such as
# "do_image_wic_ufs;gen_rkparameter;", which :remove cannot match.
do_image_wic_ufs() {
	:
}
gen_rkupdateimg() {
	:
}

# Two more, for a different reason: their names are fixed, not per image.
# - rootfs.img, a symlink to the image's ext4
# - parameter, Rockchip's partition table for its flashing tool
# CI builds microduck-image and microduck-image-dev in one job (the shipping and
# dev bundles), and the second image's do_image_complete then fails: "trying to
# install files into a shared area when those files already exist". Nothing here
# reads either file; the wks takes idblock/uboot/boot by their own names.
link_rootfs_image() {
	:
}
gen_rkparameter() {
	:
}

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " \
    microduck-daemon \
    microduck-daemon-padd \
    microduck-board \
    rauc \
    u-boot-rockchip-env \
    microduck-data \
    microduck-osupdate \
    packagegroup-microduck-media \
    alsa-utils-aplay \
    ldd \
    rustypot-wizard \
    sudo \
    kernel-modules \
    ca-certificates \
    networkmanager \
    ${MICRODUCK_RADIO_PACKAGES} \
    i2c-tools \
    htop \
"

# The beta's face LEDs, ToF and NFC reader, for the daemons' groups (robot, nfcd).
IMAGE_INSTALL:append:microduck-beta = " microduck-face-leds microduck-tof-spidev microduck-nfc"

# bluez5, iw, wpa-supplicant, wireless-regdb-static, usbutils: from packagegroup-base via MACHINE_FEATURES.
# rauc would arrive via packagegroup-base too; listed to keep the updater visible.

# u-boot-rockchip-env is /etc/fw_env.config and /etc/u-boot-initial-env, which
# RAUC's uboot backend needs; the fw_printenv/fw_setenv it runs arrive through
# meta-rauc's own RDEPENDS on u-boot-fw-utils. See recipes-bsp/u-boot/.

# MICRODUCK_RADIO_PACKAGES is per machine (microduck-common.inc has the
# default): the Zero 3W's is aic8800-bt, the beta board's wq9201s-bt.
#
# aic8800-bt is the HCI attach unit, in the shipping image rather than the dev
# one: BLE is how a robot with no network gets provisioned (configd over btd), so
# a controller that never attaches is a product fault, not a debug inconvenience.
# The chip answers only through hciattach with the port speed set before the line
# discipline attaches -- see the unit for the measurements that established that.

# rustypot-wizard is the servo setup tool people reach for on a robot, and ldd
# is what its cargo-dist installer (and every other cargo-dist installer) runs
# to read the glibc version: without it the installer reports glibc "too old"
# and finds no download for aarch64-unknown-linux-gnu. Seen on the beta board,
# 2026-10-06.

# alsa-utils-aplay is aplay and arecord, and the robot's voice depends on it:
# robotd and sounds play every wav by running `aplay -D <device>` (robotd's
# sound.rs), so without it a robot accepts `robotctl quack` and stays silent.
# Found missing on the first beta board, 2026-10-05.

# microduck-daemon-padd is installed here, not only in the dev image: a shipping
# robot is driven with a gamepad, and without padd `robotctl health` reports it
# stopped and a paired pad moves nothing.
#
# This recipe is the one that ships. Everything a robot must not carry -- a
# password-less root login above all -- belongs in microduck-image-dev.bb, which
# requires this file and only ever adds to it.

# Notes on what is deliberately absent:
#
# - systemd-timesyncd: not a separate package. timesyncd is in oe-core
#   systemd's default PACKAGECONFIG, so it ships with systemd. It still matters
#   a lot -- this board has no battery-backed RTC, and updaterd's preflight
#   check exists because a 1970 clock fails TLS with an opaque error. Verify
#   with `timedatectl`, do not assume.
#
# - no *-dev packages, no build-essential, no gdb. Cross-compile against the
#   SDK (`bitbake microduck-image -c populate_sdk`) instead of shipping headers
#   to the robot.
