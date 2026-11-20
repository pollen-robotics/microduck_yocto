#!/bin/sh
# os-release's BUILD_ID must be the build RAUC installed in the booted slot.
# No install record (flashed card, QEMU) passes; qemu-board-test.sh checks the bundle.
set -eu
os=$(sed -n 's/^BUILD_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release)
eval "$(rauc status --detailed --output-format=shell 2>/dev/null)" || true
booted=${RAUC_SYSTEM_BOOTED_BOOTNAME:-}
bundle=
for i in ${RAUC_SLOTS:-}; do
	eval "name=\${RAUC_SLOT_BOOTNAME_$i:-}"
	# shellcheck disable=SC2154 # set by the eval above
	[ "$name" = "$booted" ] && eval "bundle=\${RAUC_SLOT_STATUS_BUNDLE_BUILD_$i:-}"
done
if [ -z "$bundle" ]; then
	echo "os-release build ${os:-?}; slot ${booted:-?} has no RAUC install record to compare"
	exit 0
fi
echo "os-release build $os; RAUC installed build $bundle into slot $booted"
[ "$os" = "$bundle" ]
