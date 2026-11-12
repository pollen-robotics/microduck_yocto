SUMMARY = "The official microduck policy set"
HOMEPAGE = "https://huggingface.co/pollen-robotics/microduck-policies"

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# Why this recipe exists. This is the one copy of the story -- AGENTS.md, README.md and
# microduck-daemon point here rather than retell it, because at v6 there is one file to
# update and it is this one.
#
# robotd resolves every policy slot under /opt/robot/policies/current, and a slot it
# cannot read is not a limitation -- it is `unhealthy`:
#
#     robotd/src/main.rs:793
#     if let Some(reason) = self.policy_error.load_full() {
#         return unhealthy(format!("policy unavailable: {reason}"));
#     }
#
# `unhealthy` is what the updater's health gate rolls a release back on. Observed on the
# board:
#
#     "reason": "health check failed: not healthy within 30s: policy unavailable:
#      reading /opt/robot/policies/current/velstand.onnx: No such file or directory"
#
# Note that is a *rollback*, not a refusal: the release downloaded, verified, swapped,
# started, failed the gate and was reverted. It repeats on every *attempted* apply --
# not on every check_interval, since updater.toml sets auto_apply = "mandatory" and
# 0.14.1's manifest names no min_supported, so a candidate sits there unapplied until
# someone asks for it.
#
# And it is the verdict of a *powered* robot. With servo power off, robotd's health
# check returns `degraded` at the bus check (ticks == 0 with waiting > 0) before it ever
# reaches policy_error, and an apply passes the gate. So this does not make a board
# unupdatable in every state -- it makes it unupdatable in the state the robot is in
# when anyone would notice, which is the one that matters.
#
# Upstream fills that directory from `scripts/seed-policies.sh`, run by
# `hooks/postinstall` on every update and by `scripts/install.sh` on a fresh board. An
# image installs through neither, so nothing ever ran it here. Re-running it at first
# boot would not fix this either: it needs curl, which this image did not carry (see
# recipes-microduck/onnxruntime for the other half of that discovery, and
# microduck-daemon for where curl now comes from), and it needs the network to be up
# before the first update check -- on a robot provisioned over BLE because it has no
# wifi yet, that is a robot that cannot walk out of the box.
#
# So the image ships the set, and the seeder then leaves it alone. That is not a
# coincidence: seed-policies.sh reads the `.source` record written below, compares
# `version` against its own pin, and exits 0 for anything at or above it. A set from
# another repo, or one with no record, it refuses to touch at all.

# The pin is `PV`, so it is in the filename: microduck-policies_v9.bb. And it belongs to
# the daemon rather than to us -- `POLICY_VERSION` in the release's own
# scripts/seed-policies.sh, which an xtask test holds against
# [workspace.metadata.policies] in Cargo.toml. It was v5 from daemon 0.13.0 to 0.15.1, v7
# from 0.15.2 to 0.16.1 (velstand steers the trunk while standing; sitstand no longer
# tips backward), v8 from 0.16.2 to 0.18.8 (velstand gets up from a fall smoothly and
# tracks yaw commands), and is v9 from 0.19.0, so rename this file in step with a daemon
# bump.
#
# v9 is a rollback, not new weights: velstand.onnx and manifest.json are byte-identical
# to v7's (the checksums below are v7's), because v8's velstand was worse on the real
# robot. It is a new number rather than a re-tag of v7 because the seeder only ever
# moves a board *up* -- a board already on v8 would never go back to a set called v7.
#
# Seeding *below* what the daemon names is the one thing that actively breaks: its
# defaults name files only the newer set carries -- velstand.onnx is exactly such a file,
# new in v5 -- so robotd would fail to load its gait, and seed-policies.sh would try to
# move the board up over the network on the first update, which is where we came in.
# Seeding above it is safe; the pin is a minimum, not a ceiling.
POLICY_REPO = "pollen-robotics/microduck-policies"

# Fetched by commit, recorded as the tag. A Hub tag is a mutable ref -- it can be moved
# onto different weights -- and "reproducible" is the reason this tree pins every layer
# to a commit too. `.source` still says `v9`, because that is the string seed-policies.sh
# and `robotctl policy check` compare against.
# The Hub's refs API lists tag v9 at 8dc9feca: that is the annotated tag object, which
# peels to this commit (the same holds for v7, listed at f745f108 and pinned at 6677ec00).
POLICY_REV = "283771bcb3690a0a94a288c108365d9b630d21e4"
POLICY_BASE = "https://huggingface.co/${POLICY_REPO}/resolve/${POLICY_REV}"

# The whole set, not the subset robotd's defaults happen to name today.
#
# This is what seed-policies.sh installs -- it downloads every `"file"` in the revision's
# manifest.json -- and matching it is what makes the two paths produce the same board.
# It also costs nothing to be complete: 7.9 MiB of weights on a rootfs that is already
# 1.9 G, and the alternative is that `robotctl policy load <slot> roller.onnx` fails on a
# robot whose set is silently a subset of the one it says it has.
#
# manifest.json comes with them because robotd reads it: robotd-params' `set_manifest()`
# takes the ground-pick period, the sitstand ramp and which policies are skills from
# `${POLICY_DIR}/manifest.json`, falling back to the prototype's hard-coded numbers when
# it is absent. A set without it runs, subtly differently.
#
# Every file takes a downloadfilename, and the collision that makes it necessary is not
# between recipes: DL_DIR is flat and keyed by filename alone, so v5 and v6 of
# velstand.onnx would be the same cache entry holding different bytes. Bitbake does
# recover from that -- the checksum fails and the file is re-fetched as
# `_bad-checksum_` -- but on a pre-seeded cache it is a confusing way to find out.
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

# The Hub stores these in LFS, and an LFS object's oid *is* its sha256 -- so these came
# from the tree listing at ${POLICY_REV} and were confirmed against the downloaded bytes,
# rather than being taken on trust from one of the two.
SRC_URI[manifest.sha256sum] = "5c6a73f95f388f131aaef570f6113f0d36b84a72d5755662cd57e67adf7fd24c"
SRC_URI[velstand.sha256sum] = "ce894d30b3343036d499bfac1102bdaa58d59a21c1b58401ecb70fb6a2f63e0a"
SRC_URI[alpha_walking.sha256sum] = "e36332d383997d51401897734cd3e79cf5038406feddb18b4d57ecfb141daa6c"
SRC_URI[alpha_stand.sha256sum] = "1569268713e40deea795dd2922dba50d3621e15a872855408b6b1b125b1c094b"
SRC_URI[alpha_sitstand.sha256sum] = "a6f102d9fd655782ba85bfffe18175c34621da719cffcdd673be7982a06fc254"
SRC_URI[alpha_ground_pick.sha256sum] = "ffbf5109982ff999b0ba53afe86b9ae731bbec679d67fb7f8ab4c52152c88872"
SRC_URI[ball_kick_left.sha256sum] = "d6928284dccd3dd61e08bf2f760effa74309fbefd97b2b31afb2a60f526d196a"
SRC_URI[ball_kick_right.sha256sum] = "147a32c388c6b19111b3ac3b550a9a6dc8b8bf267118af4d8c3712522eedb5af"
SRC_URI[roulade.sha256sum] = "3d60da08fc13f29c1b57f41977aa898132c0d60042100149d8e775affcbca32b"
SRC_URI[roller.sha256sum] = "cf05651d2708a2f9364212e86b866c97a70ace8131c492500105e8f28bf99afd"
SRC_URI[roller_crouch.sha256sum] = "a1a084be240469c76ac9d3fa44d4792f16d4b1da60398b3ecd3cfc5e2244d990"

# Weights and a JSON file. Nothing here is compiled, linked or tuned, so one build
# serves every machine.
inherit allarch

# Loose files, no unpack directory, so point S at UNPACKDIR itself -- where the
# fetcher already puts downloadfilename= files. That is the idiom oe-core's own
# file-only recipes use on wrynose (systemd-conf, base-files: S = "${UNPACKDIR}").
#
# It was S = "${WORKDIR}/sources" with UNPACKDIR = "${S}", which the pinned oe-core
# rejects outright: do_qa_unpack (insane.bbclass:1448) fails any S whose
# *unexpanded* value contains ${WORKDIR}, whatever it expands to --
#
#   ERROR: microduck-policies-v5-r0 do_unpack: S should be set relative to
#   UNPACKDIR, e.g. replace WORKDIR with UNPACKDIR in "S = ${WORKDIR}/sources"
#
# AGENTS.md's rule is therefore broader than its wording: no ${WORKDIR} in S at
# all, not only the ${WORKDIR}/git form.
S = "${UNPACKDIR}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

# The layout is the updater's, and that is the point: `releases/<name>/` beside a
# `current` symlink, swapped by rename. updater/src/policy.rs installs sets exactly this
# way, so a set that arrived in the image and a set that arrived from
# `robotctl policy update` are the same kind of thing.
#
# `seed-` is load-bearing. Both the seeder and updaterd treat that prefix as "ours" and
# refuse to disturb a `current` without it -- so a set installed here can be moved
# forward later, while one named anything else would be left frozen forever.
POLICY_ROOT = "/opt/robot/policies"
POLICY_SET = "releases/seed-${PV}"

do_install() {
	install -d ${D}${POLICY_ROOT}/${POLICY_SET}

	# Installed under the name the manifest uses, which means stripping the DL_DIR
	# prefix back off on the way in.
	for f in ${UNPACKDIR}/${BPN}-${PV}-*; do
		install -m 0644 "$f" ${D}${POLICY_ROOT}/${POLICY_SET}/"${f##*/${BPN}-${PV}-}"
	done

	# Where this set came from, beside the set. It is what lets `robotctl policy check`
	# ask the Hub whether there is anything newer without anyone configuring the repo a
	# second time, and -- the reason it is not optional here -- it is what
	# seed-policies.sh reads to decide whether to leave us alone. Without it the set
	# parses as "no record", which the seeder refuses to touch: safe, but it would also
	# never move the board forward again.
	#
	# Two keys, matching `updater::policy::Source::render()` exactly. The shell seeder
	# also writes a `fetched=` timestamp and `Source::parse` ignores keys it does not
	# know, but a build-time timestamp is a reproducibility problem for no gain: the
	# thing it would record is the date of a build, not of a download.
	cat > ${D}${POLICY_ROOT}/${POLICY_SET}/.source <<-EOT
		repo=${POLICY_REPO}
		version=${PV}
	EOT

	# Relative, not absolute, and for the seeder's stated reason: an absolute target
	# resolves against the wrong directory the moment POLICY_ROOT is not what it was
	# written with -- ${D} being exactly such a moment.
	ln -snf ${POLICY_SET} ${D}${POLICY_ROOT}/current
}

FILES:${PN} = "${POLICY_ROOT}"
