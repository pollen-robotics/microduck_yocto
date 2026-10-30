#!/bin/sh
# Publish a built RAUC bundle to an OS update channel (prototype).
#
#   scripts/publish-os.sh <hf-job-id> [machine] [channel]
#   scripts/publish-os.sh 6ad1ed6bc66288145225bc28 microduck-zero3 dev
#   BUNDLE=microduck-bundle-shipping scripts/publish-os.sh <hf-job-id> microduck-zero3 candidate
#   BUILD=<build> JOB=<hf-job-id> VERSION=1.0.0 scripts/publish-os.sh <file.raucb> microduck-zero3 stable
#
# Takes the bundle a build-hfjob.sh job left in the cache bucket's deploy/<job>/ --
# $BUNDLE-<machine>-<build>.raucb, microduck-bundle by default -- or a bundle file
# given by path, which is how promote-os.yml publishes the one it re-signed. Writes,
# in the public bucket (pollen-robotics/microduck-os):
#
#   os/<machine>/<build>/<channel>.raucb   the bundle
#   os/<machine>/builds/<build>.env        that build's manifest
#   os/<machine>/index.txt                 every published build, for the list
#   os/<machine>/<channel>.env             the channel: its newest build
#
# The bundle first, the channel file last, so a robot never reads a channel naming
# a bundle that is not there yet. microduck-osupdate on the robot reads the channel
# and checks every field; RAUC verifies the bundle itself.
#
# The bundle is named after its channel because one build is published twice:
# to candidate dev-signed, then to stable re-signed, and a robot halfway through
# downloading the first must not find different bytes under its URL. The
# build's manifest and index line move to the latest channel.
#
# <build> is the bundle's RAUC_BUNDLE_BUILD, which is also the 14 digits at the end
# of its file name (bundle.bbclass gives BUNDLE_NAME and RAUC_BUNDLE_BUILD the same
# ${DATETIME}; microduck-bundle-shipping.bb keeps the two equal too). RAUC records
# it per slot, and the robot compares it. A file loses its name to the re-sign, so
# its build comes from BUILD.
#
# The dev channel carries the dev image (password-less root): fine for a bench
# prototype, and nothing in it is secret, but robots in the field must only ever
# follow a channel of the shipping image.
set -eu

SRC=${1:?usage: $0 <hf-job-id | file.raucb> [machine] [channel]}
MACHINE=${2:-microduck-zero3}
CHANNEL=${3:-dev}
BUNDLE=${BUNDLE:-microduck-bundle}
CACHE=${HFJOB_BUCKET:-pollen-robotics/microduck-yocto-cache}
PUBLIC=${OS_BUCKET:-pollen-robotics/microduck-os}
HF=${HF:-hf}

check() {
	printf '%s' "$2" | grep -Eqx -- "$3" || { echo "$0: bad $1 '$2'" >&2; exit 1; }
}
check machine "$MACHINE" '[a-z0-9-]{1,40}'
check channel "$CHANNEL" '[a-z0-9-]{1,40}'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case "$SRC" in
*.raucb)
	[ -s "$SRC" ] || { echo "$0: no bundle at $SRC" >&2; exit 1; }
	build=${BUILD:-}
	JOB=${JOB:-}
	cp "$SRC" "$work/bundle.raucb"
	;;
*)
	JOB=$SRC
	check BUNDLE "$BUNDLE" '[a-z0-9-]{1,60}'
	name=$($HF buckets ls "$CACHE/deploy/$JOB" | grep -oE "$BUNDLE-$MACHINE-[0-9]{14}\.raucb" | sort -u | tail -n 1)
	[ -n "$name" ] || { echo "$0: no $BUNDLE-$MACHINE-*.raucb in deploy/$JOB" >&2; exit 1; }
	build=${name%.raucb}; build=${build##*-}
	$HF buckets cp "hf://buckets/$CACHE/deploy/$JOB/$name" "$work/bundle.raucb" > /dev/null
	;;
esac
# The commit the bundle was built from, for promote-os.yml's release tag. In CI's
# build run that is GITHUB_SHA; a promote run passes the candidate's own COMMIT,
# since its GITHUB_SHA is whatever main is at the time.
COMMIT=${COMMIT:-${GITHUB_SHA:-}}
check build "$build" '[0-9]{14}'
[ -z "$JOB" ] || check job "$JOB" '[0-9a-f]{24}'
[ -z "$COMMIT" ] || check commit "$COMMIT" '[0-9a-f]{40}'
size=$(wc -c < "$work/bundle.raucb")
sha256=$(sha256sum "$work/bundle.raucb" | cut -d' ' -f1)
# What robots show. A stable release passes its own (promote-os.yml: 1.0.0); a
# dev or candidate build is <newest release>+<build> (scripts/os-release.sh):
# `+`, not `-`, because a semver `-` would sort it before that release.
[ -n "${VERSION:-}" ] || VERSION=$("$(dirname "$0")/os-release.sh")+$build
version=$VERSION
check version "$version" '[0-9A-Za-z.+_-]{1,64}'

path=os/$MACHINE/$build/$CHANNEL.raucb
$HF buckets cp "$work/bundle.raucb" "hf://buckets/$PUBLIC/$path" > /dev/null
printf 'VERSION=%s\nBUILD=%s\nURL=%s\nSHA256=%s\nSIZE=%s\nCOMPATIBLE=%s\nJOB=%s\nCHANNEL=%s\nCOMMIT=%s\n' \
	"$version" "$build" "https://huggingface.co/buckets/$PUBLIC/resolve/$path" \
	"$sha256" "$size" "$MACHINE" "$JOB" "$CHANNEL" "$COMMIT" > "$work/channel.env"
# The build's own manifest: what a robot installs when someone picks this build
# from the list rather than a channel's newest. A promotion repoints it at stable.
$HF buckets cp "$work/channel.env" "hf://buckets/$PUBLIC/os/$MACHINE/builds/$build.env" > /dev/null

# The index the robot's list comes from: "<channel> <build> <version>", newest
# last, one line per build (a republished build moves to the end).
# shortcut: read-modify-write, so two publishes at the same moment can drop one's
# line; its builds/<build>.env and channel file are still there. A build's dev
# and candidate publishes run one after the other, but a promote-os run that
# overlaps a push to main can lose a line; a lock, or one file per line, if
# that starts to happen.
if ! $HF buckets cp "hf://buckets/$PUBLIC/os/$MACHINE/index.txt" "$work/index.txt" > /dev/null 2>&1; then
	: > "$work/index.txt"
fi
grep -v " $build " "$work/index.txt" > "$work/index.new" || true
printf '%s %s %s\n' "$CHANNEL" "$build" "$version" >> "$work/index.new"
$HF buckets cp "$work/index.new" "hf://buckets/$PUBLIC/os/$MACHINE/index.txt" > /dev/null

# Last: the channel moves only once its build is listed and installable.
$HF buckets cp "$work/channel.env" "hf://buckets/$PUBLIC/os/$MACHINE/$CHANNEL.env" > /dev/null

echo "published $version to $MACHINE/$CHANNEL:"
cat "$work/channel.env"
