# Seeed's public seeed_armbian_extension, deb_source branch: one pinned commit for
# everything the beta takes from it -- the WQ9201S driver and its firmware (from
# wq9201s-wifi-bt-dkms) and rkaiq (camera_engine_rkaiq). One pin, so the driver
# and its firmware cannot come from different releases.
#
# Fetched as GitHub's archive of the commit, not with git: bitbake's git fetcher
# only reaches commits that a branch reaches, while GitHub serves a commit and
# its archive by hash. So the build depends on the commit only, not on where the
# branch points. The checksum pins the content, and once fetched the archive
# lives in our download mirror too.
#
# Checked 2026-11-19 at deb_source d53b0de: since 01e28cf, camera_engine_rkaiq
# is unchanged and wq9201s-wifi-bt-dkms only gained 2.2.3.94-2 (4dee431):
# changes for kernels from 6.4 on, warning flags and a prerm fix, no firmware
# change. Take it with a kernel move.
#
# subdir=${BP} with striplevel=1 unpacks it where the git checkout was, so the
# recipes' S stays ${UNPACKDIR}/${BP}/<directory>.
SEEED_DEB_SOURCE_REV = "01e28cf33cc20b9df2f6e40577899c260ab2becd"
SEEED_DEB_SOURCE = "https://github.com/Seeed-Studio/seeed_armbian_extension/archive/${SEEED_DEB_SOURCE_REV}.tar.gz;downloadfilename=seeed_armbian_extension-${SEEED_DEB_SOURCE_REV}.tar.gz;subdir=${BP};striplevel=1"
SRC_URI[sha256sum] = "4f7e3d486e37ded5e31cc1b6c053953e7f2d87ea363134bad6d414c67ac7100b"
# insane.bbclass rejects GitHub archive URLs because GitHub has regenerated them
# with different bytes before. Here that would fail do_fetch on the checksum,
# loudly, and the download mirror keeps the bytes we checked. Downloads on
# 2026-11-09 and 2026-11-19 gave the same checksum.
# shortcut: if the commit ever leaves every branch, GitHub may garbage-collect
# it. If that matters, push the commit to a fork of ours.
INSANE_SKIP += "src-uri-bad"
