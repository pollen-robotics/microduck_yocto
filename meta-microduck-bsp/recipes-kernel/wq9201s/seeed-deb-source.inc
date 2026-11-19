# Seeed's public seeed_armbian_extension, deb_source branch: one pinned commit for
# everything the beta takes from it -- the WQ9201S driver and its firmware (from
# wq9201s-wifi-bt-dkms) and rkaiq (camera_engine_rkaiq). One pin, so the driver
# and its firmware cannot come from different releases.
#
# Fetched from our fork's `microduck` branch, not Seeed's deb_source: bitbake's
# git fetcher only reaches commits a branch reaches, and Seeed has rewritten
# deb_source before. `microduck` is ours alone (Sync fork never touches it), so
# the pinned commit stays reachable. To bump, move that branch, then SRCREV.
#
# Checked 2026-11-19 at deb_source d53b0de: since 01e28cf, camera_engine_rkaiq
# is unchanged and wq9201s-wifi-bt-dkms only gained 2.2.3.94-2 (4dee431):
# changes for kernels from 6.4 on, warning flags and a prerm fix, no firmware
# change. Take it with a kernel move.
#
# The checkout lands in ${UNPACKDIR}/${BP}, so the recipes' S is
# ${UNPACKDIR}/${BP}/<directory>.
SEEED_DEB_SOURCE = "git://github.com/pollen-robotics/seeed_armbian_extension.git;protocol=https;branch=microduck"
SRCREV = "01e28cf33cc20b9df2f6e40577899c260ab2becd"
