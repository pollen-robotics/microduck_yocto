SUMMARY = "The official microduck duck detector model"
DESCRIPTION = "The model mediad's duck detector runs: duck_detect.rknn for the NPU and \
duck_detect.onnx, the CPU fallback. Shipped in the image so a robot can look for ducks \
without ever having been online. The detector itself stays off by default \
([duck_detector] enabled in robotd.toml)."
HOMEPAGE = "https://huggingface.co/pollen-robotics/microduck-duck-detector"

# What the model repo declares. It is fine-tuned from Ultralytics' yolo11n.pt (the
# model card says so), whose weights Ultralytics publishes under AGPL-3.0.
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# microduck-policies is the same thing for robotd and carries the reasoning; this is
# its pattern for the detector. Upstream, `scripts/seed-detector.sh` fills
# /opt/robot/detector from `hooks/postinstall` -- which an image never runs, so
# without this a freshly flashed robot has no model until its first update, and none
# at all offline.
#
# The pin belongs to the daemon: DETECTOR_VERSION in its scripts/seed-detector.sh,
# held against [workspace.metadata.detector] in its Cargo.toml.
# The tag is "duck-v1"; PV is "v1" because a hyphen in PV breaks package versions.
DETECTOR_REPO = "pollen-robotics/microduck-duck-detector"
DETECTOR_TAG = "duck-${PV}"

# Fetched by commit, recorded as the tag -- a Hub tag can be moved.
DETECTOR_REV = "eeda8d200e4e91490d09b55c94648773406cc416"
DETECTOR_BASE = "https://huggingface.co/${DETECTOR_REPO}/resolve/${DETECTOR_REV}"

# The two files the seeder installs (DETECTOR_FILES), not duck_detect.pt: that is the
# training checkpoint, which nothing on the robot reads. downloadfilename because
# DL_DIR is flat and every retrain uses the same file names.
SRC_URI = "\
    ${DETECTOR_BASE}/duck_detect.rknn;name=rknn;downloadfilename=${BPN}-${PV}-duck_detect.rknn \
    ${DETECTOR_BASE}/duck_detect.onnx;name=onnx;downloadfilename=${BPN}-${PV}-duck_detect.onnx \
"
# The LFS oids at ${DETECTOR_REV}, which are the files' sha256.
SRC_URI[rknn.sha256sum] = "b3b79b7dbddeaa51a2475f4021d8ae2004f870cf6f4ad5291f88ae9077ae475a"
SRC_URI[onnx.sha256sum] = "2e34657a655a15221f93f6149730875274da4fb1b1c67dc883cde769fec35c30"

# Weights only: one build serves every machine. The Zero 3W, whose NPU is off, uses
# the .onnx; the beta boards the .rknn (with librknnrt).
inherit allarch

S = "${UNPACKDIR}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

# The seeder's layout: releases/seed-<tag> beside a relative `current` symlink. The
# `seed-` prefix and the .source record are what let `robotctl duck-detector update`
# move a board past this set later, and what seed-detector.sh reads to leave it alone.
DETECTOR_ROOT = "/opt/robot/detector"
DETECTOR_SET = "releases/seed-${DETECTOR_TAG}"

do_install() {
	install -d ${D}${DETECTOR_ROOT}/${DETECTOR_SET}
	for f in ${UNPACKDIR}/${BPN}-${PV}-*; do
		install -m 0644 "$f" ${D}${DETECTOR_ROOT}/${DETECTOR_SET}/"${f##*/${BPN}-${PV}-}"
	done

	# The seeder also writes fetched=, a build date here, which would only cost
	# reproducibility; updater::policy::Source ignores keys it does not know.
	cat > ${D}${DETECTOR_ROOT}/${DETECTOR_SET}/.source <<-EOT
		repo=${DETECTOR_REPO}
		version=${DETECTOR_TAG}
	EOT

	ln -snf ${DETECTOR_SET} ${D}${DETECTOR_ROOT}/current
}

FILES:${PN} = "${DETECTOR_ROOT}"
