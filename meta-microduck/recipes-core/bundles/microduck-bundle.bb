SUMMARY = "microduck OS update bundle"
DESCRIPTION = "Signed RAUC bundle carrying one rootfs slot image."

# The newest OS release (microduck-os-v<X.Y.Z>), which build-hfjob.sh and
# build-local.sh read from the tags (scripts/os-release.sh), so a release needs
# no bump here. `rauc info` reports it as version=. Defaulted in microduck.conf.
PV = "${MICRODUCK_OS_VERSION}"

inherit bundle

# Out of `world`, as image.bbclass does for images: this builds microduck-image-dev,
# which only our machines can (u-boot-rockchip-env), and bundle.bbclass does not
# exclude itself. yocto-check-layer's x86 world build failed on it.
EXCLUDE_FROM_WORLD = "1"

# Must equal compatible= in recipes-core/rauc/files/system.conf; RAUC refuses a
# bundle for another machine.
RAUC_BUNDLE_COMPATIBLE = "${MACHINE}"
RAUC_BUNDLE_FORMAT = "verity"

# Rootfs only, and that is the whole OS: the kernel and DTB are in each slot's
# /boot, where U-Boot loads them from (recipes-bsp/u-boot/), so a bundle carries
# its own kernel and an update can change it.
RAUC_BUNDLE_SLOTS = "rootfs"

# The hook refuses a card whose U-Boot still boots the `boot` partition: there a
# new kernel in the slot would never run, against its own modules. See the hook.
SRC_URI = "file://microduck-bundle-hook"
# Fetching anything makes do_populate_lic demand a checksum; bundle.bbclass only
# sets LICENSE ?= "MIT". Same line as microduck-data.bb.
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"
RAUC_BUNDLE_HOOKS[file] = "microduck-bundle-hook"
RAUC_BUNDLE_HOOKS[hooks] = "install-check"

# The dev image, so the card built alongside and every updated slot keep a
# password-less root to test with. microduck-bundle-shipping.bb carries the
# shipping image, and is the one that gets promoted to stable.
RAUC_SLOT_rootfs = "microduck-image-dev"
# Required: bundle.bbclass defaults to the first IMAGE_FSTYPES entry, tar.zst here.
RAUC_SLOT_rootfs[fstype] = "ext4"
# Carries the running slot's machine-id over, so the journal on the data partition
# stays one directory across updates. See the hook.
RAUC_SLOT_rootfs[hooks] = "post-install"

# The signing pair lives in the build directory and never in this repo or the
# image; only the public CAs are committed (recipes-core/rauc/files/). This is the
# development pair; the production one never enters a build (promote-os.yml).
# README.md has the one-time key generation. build-hfjob.sh writes the pair here.
RAUC_KEY_FILE ?= "${TOPDIR}/rauc-keys/development-1.key.pem"
RAUC_CERT_FILE ?= "${TOPDIR}/rauc-keys/development-1.cert.pem"
