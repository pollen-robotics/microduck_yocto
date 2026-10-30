SUMMARY = "microduck OS update bundle -- shipping image"
DESCRIPTION = "microduck-bundle with the shipping image in its slot: the release \
candidate. CI signs it with the development key; promote-os re-signs one with the \
production key, and only that can reach a robot that runs microduck-image."

require recipes-core/bundles/microduck-bundle.bb

RAUC_SLOT_rootfs = "microduck-image"

# Its own build id, one second after the dev bundle's: microduck-build-id.inc says why.
require recipes-core/images/microduck-build-id.inc
MICRODUCK_BUNDLE_BUILD = "${MICRODUCK_SHIPPING_BUILD}"
MICRODUCK_BUNDLE_BUILD[vardepsexclude] = "DATETIME"
RAUC_BUNDLE_BUILD = "${MICRODUCK_BUNDLE_BUILD}"
# scripts/publish-os.sh reads the build id from the file name.
BUNDLE_NAME = "${BUNDLE_BASENAME}-${MACHINE}-${MICRODUCK_BUNDLE_BUILD}"
