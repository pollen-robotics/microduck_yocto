SUMMARY = "The official microduck policy set"
HOMEPAGE = "https://huggingface.co/pollen-robotics/microduck-policies"

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# Without a set robotd is `unhealthy` and every update rolls back. PV is the
# daemon's POLICY_VERSION, a minimum: docs/agents/daemon-recipe.md, "Policy set".
POLICY_REPO = "pollen-robotics/microduck-policies"

# A commit, since a Hub tag can move; `.source` still records the tag.
POLICY_REV = "236d1835b03ac7b45d962efbf2fe3a6940206112"
POLICY_BASE = "https://huggingface.co/${POLICY_REPO}/resolve/${POLICY_REV}"

# The whole manifest, as seed-policies.sh installs it. DL_DIR is flat, so
# each file is versioned in its downloadfilename.
SRC_URI = "\
    ${POLICY_BASE}/manifest.json;name=manifest;downloadfilename=${BPN}-${PV}-manifest.json \
    ${POLICY_BASE}/velstand.onnx;name=velstand;downloadfilename=${BPN}-${PV}-velstand.onnx \
    ${POLICY_BASE}/alpha_walking.onnx;name=alpha_walking;downloadfilename=${BPN}-${PV}-alpha_walking.onnx \
    ${POLICY_BASE}/alpha_stand.onnx;name=alpha_stand;downloadfilename=${BPN}-${PV}-alpha_stand.onnx \
    ${POLICY_BASE}/alpha_sitstand.onnx;name=alpha_sitstand;downloadfilename=${BPN}-${PV}-alpha_sitstand.onnx \
    ${POLICY_BASE}/alpha_ground_pick.onnx;name=alpha_ground_pick;downloadfilename=${BPN}-${PV}-alpha_ground_pick.onnx \
    ${POLICY_BASE}/ball_kick_left.onnx;name=ball_kick_left;downloadfilename=${BPN}-${PV}-ball_kick_left.onnx \
    ${POLICY_BASE}/ball_kick_right.onnx;name=ball_kick_right;downloadfilename=${BPN}-${PV}-ball_kick_right.onnx \
    ${POLICY_BASE}/roulade.onnx;name=roulade;downloadfilename=${BPN}-${PV}-roulade.onnx \
    ${POLICY_BASE}/roller.onnx;name=roller;downloadfilename=${BPN}-${PV}-roller.onnx \
    ${POLICY_BASE}/roller_crouch.onnx;name=roller_crouch;downloadfilename=${BPN}-${PV}-roller_crouch.onnx \
"

# The LFS oids at POLICY_REV, checked against the downloaded bytes.
SRC_URI[manifest.sha256sum] = "5c6a73f95f388f131aaef570f6113f0d36b84a72d5755662cd57e67adf7fd24c"
SRC_URI[velstand.sha256sum] = "ce894d30b3343036d499bfac1102bdaa58d59a21c1b58401ecb70fb6a2f63e0a"
SRC_URI[alpha_walking.sha256sum] = "e36332d383997d51401897734cd3e79cf5038406feddb18b4d57ecfb141daa6c"
SRC_URI[alpha_stand.sha256sum] = "1569268713e40deea795dd2922dba50d3621e15a872855408b6b1b125b1c094b"
SRC_URI[alpha_sitstand.sha256sum] = "a6f102d9fd655782ba85bfffe18175c34621da719cffcdd673be7982a06fc254"
SRC_URI[alpha_ground_pick.sha256sum] = "ffbf5109982ff999b0ba53afe86b9ae731bbec679d67fb7f8ab4c52152c88872"
SRC_URI[ball_kick_left.sha256sum] = "d6928284dccd3dd61e08bf2f760effa74309fbefd97b2b31afb2a60f526d196a"
SRC_URI[ball_kick_right.sha256sum] = "147a32c388c6b19111b3ac3b550a9a6dc8b8bf267118af4d8c3712522eedb5af"
SRC_URI[roulade.sha256sum] = "3d60da08fc13f29c1b57f41977aa898132c0d60042100149d8e775affcbca32b"
SRC_URI[roller.sha256sum] = "7b581097a9bc4782a695fd7654edb0c565649ad593ae439563ddf4b2b2e8a8c7"
SRC_URI[roller_crouch.sha256sum] = "a1a084be240469c76ac9d3fa44d4792f16d4b1da60398b3ecd3cfc5e2244d990"

inherit allarch

S = "${UNPACKDIR}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

# updaterd's layout. The `seed-` prefix tells the seeder and updaterd the set
# is theirs to replace; under any other name it is frozen.
POLICY_ROOT = "/opt/robot/policies"
POLICY_SET = "releases/seed-${PV}"

do_install() {
	install -d ${D}${POLICY_ROOT}/${POLICY_SET}

	for f in ${UNPACKDIR}/${BPN}-${PV}-*; do
		install -m 0644 "$f" ${D}${POLICY_ROOT}/${POLICY_SET}/"${f##*/${BPN}-${PV}-}"
	done

	# seed-policies.sh reads it; with no record the board never moves forward.
	# The keys of updater::policy::Source::render(), no build-time `fetched=`.
	cat > ${D}${POLICY_ROOT}/${POLICY_SET}/.source <<-EOT
		repo=${POLICY_REPO}
		version=${PV}
	EOT

	ln -snf ${POLICY_SET} ${D}${POLICY_ROOT}/current
}

FILES:${PN} = "${POLICY_ROOT}"
