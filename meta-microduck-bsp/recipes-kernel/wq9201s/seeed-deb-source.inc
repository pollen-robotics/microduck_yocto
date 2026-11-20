# Seeed's seeed_armbian_extension (deb_source): one pin for the WQ9201S driver,
# its firmware and rkaiq, so they cannot come from different releases.
# From our fork's `microduck` branch, which Seeed cannot rewrite: move it, then SRCREV.
# 2.2.3.94-2 (deb_source 4dee431) only adds kernel >= 6.4 changes: take it with a kernel move.
SEEED_DEB_SOURCE = "git://github.com/pollen-robotics/seeed_armbian_extension.git;protocol=https;branch=microduck"
SRCREV = "01e28cf33cc20b9df2f6e40577899c260ab2becd"
