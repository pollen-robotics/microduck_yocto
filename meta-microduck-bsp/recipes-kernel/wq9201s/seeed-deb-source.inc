# Seeed's public seeed_armbian_extension, deb_source branch: one pinned commit for
# everything the beta takes from it -- the WQ9201S driver and its firmware (from
# wq9201s-wifi-bt-dkms) and rkaiq (camera_engine_rkaiq). One pin, so the driver
# and its firmware cannot come from different releases.
#
# Seeed rewrote deb_source's whole history on 2026-10-30, which dropped the commit
# this pinned (1f4bd1c) from the branch and failed every beta build in do_fetch:
# this is its rewritten copy, with identical wq9201s-wifi-bt-dkms and
# camera_engine_rkaiq trees. 2.2.3.94-2 (4dee431) is newer, but its changes are
# all for kernels from 6.4 on; take it with a kernel move.
SEEED_DEB_SOURCE = "git://github.com/Seeed-Studio/seeed_armbian_extension.git;protocol=https;branch=deb_source"
SRCREV = "01e28cf33cc20b9df2f6e40577899c260ab2becd"
