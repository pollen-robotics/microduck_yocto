#!/usr/bin/env bash
# Write a robot's eMMC over USB-C: docs/flashing.md, scripted. Or read it back.
#
#   scripts/flash-emmc.sh [flash] [WHAT] [MACHINE]   show the build, ask, write it
#   scripts/flash-emmc.sh latest [WHAT] [MACHINE]    print what WHAT resolves to
#   scripts/flash-emmc.sh recover [WHAT] [MACHINE]   rewrite only the idblock and U-Boot
#   scripts/flash-emmc.sh dump FILE [MACHINE]        read the whole eMMC into FILE
#   scripts/flash-emmc.sh clean                      delete the downloads, after asking
#
# WHAT is one of:
#   release (default)     the latest GitHub release: the shipping image
#   microduck-os-vX.Y.Z   that release
#   dev                   main's newest CI build: the dev image (root login, debug tools)
#   FOLDER                that build's folder in the cache bucket: the dev image
# MACHINE is microduck-face-board-v1 (default) or microduck-beta.
#
#   scripts/flash-emmc.sh release microduck-beta   latest release on a beta board
#   scripts/flash-emmc.sh dev microduck-beta       latest dev build on a beta board
#
# flash and recover show what they are about to write and ask first;
# FLASH_EMMC_YES=1 skips the question. Files are downloaded once, into
# $FLASH_DIR/<tag or folder>, by default the user cache dir:
# $XDG_CACHE_HOME/microduck-flash, i.e. ~/.cache/microduck-flash. A release's
# image is kept decompressed there, so the next robot is just another run; a
# dev build's is deleted after writing, as the next dev flash is usually newer.
#
# recover is for a board stuck in maskrom whose eMMC already carries our image:
# it replaces the DRAM init without a reflash (docs/agents/beta-board.md, "A
# board stuck in maskrom"). A release ships no idblock or U-Boot, so for one they
# come from the build's bucket folder, which CI prunes 14 days after the build.
#
# Needs: gh, zstd, rkdeveloptool, and for dev, FOLDER and recover the Hugging
# Face CLI (hf, logged in with access to the cache bucket). On a Mac:
#   brew install gh zstd pierre-rouanet/tools/rkdeveloptool
# The robot must be in maskrom or loader mode: hold Recovery while powering it
# on. On a Mac, click Allow when macOS asks about the USB accessory.
set -euo pipefail

REPO=pollen-robotics/microduck_yocto
BUCKET=hf://buckets/pollen-robotics/microduck-yocto-cache/deploy
FLASH_DIR=${FLASH_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/microduck-flash}

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

usage() { sed -n '2,36s/^# \{0,1\}//p' "$0"; }

# rkdeveloptool needs root on Linux (no udev rule), not on macOS.
rkdt() {
	if [ "$(uname)" = Darwin ]; then rkdeveloptool "$@"; else sudo rkdeveloptool "$@"; fi
}

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum | awk '{ print $1 }'
	else shasum -a 256 | awk '{ print $1 }'; fi
}

size() { wc -c <"$1" | tr -d ' '; }

# Only boards with a Rockchip USB loader in the release: the Zero 3W has none.
check_machine() {
	case $MACHINE in
	microduck-beta | microduck-face-board-v1) ;;
	*) die "MACHINE must be microduck-beta or microduck-face-board-v1, not '$MACHINE'" ;;
	esac
}

# Newest successful build-image run that built MACHINE, from a push to main or
# a dispatch. A run builds several machines, each in its own job, so the folder
# is read only from the "build (MACHINE)" job's log.
#
# That one job's log, fetched by its id, rather than `gh run view --log` on the
# whole run: gh 2.45 (Ubuntu 24.04's package) returns an empty whole-run log,
# with exit status 0, so every run looked like it had no MACHINE build and this
# failed with "no successful ... build" on a bucket full of them (2026-11-12).
# One job's log is also a fraction of the download.
latest_dev() {
	local id job log folder
	for id in $(gh run list -R "$REPO" -w build-image -s success -L 15 \
		--json databaseId -q '.[].databaseId'); do
		job=$(gh run view "$id" -R "$REPO" --json jobs \
			-q ".jobs[] | select(.name == \"build ($MACHINE)\" and .conclusion == \"success\") | .databaseId" \
			2>/dev/null | head -1) || continue
		[ -n "$job" ] || continue
		log=$(gh api "repos/$REPO/actions/jobs/$job/logs" 2>/dev/null) || continue
		folder=$(grep -oE "$BUCKET/[A-Za-z0-9]+" <<<"$log" | head -1) || true
		[ -n "$folder" ] || continue
		say "run https://github.com/$REPO/actions/runs/$id"
		say "$(gh run view "$id" -R "$REPO" --json headBranch,headSha,displayTitle \
			-q '"\(.headBranch)@\(.headSha[0:7]): \(.displayTitle)"')"
		basename "$folder"
		return
	done
	die "no successful $MACHINE build in the last 15 build-image runs"
}

# Newest OS release (promote-os.yml): microduck-os-vX.Y.Z.
latest_release() {
	local tag
	tag=$(gh release list -R "$REPO" -L 50 --json tagName \
		-q '[.[].tagName | select(startswith("microduck-os-v"))][0] // empty')
	[ -n "$tag" ] || die "no microduck-os-v* release"
	echo "$tag"
}

# release_job TAG: the bucket folder MACHINE's build in the release came from,
# as its notes name it.
release_job() {
	gh release view "$1" -R "$REPO" --json body -q .body |
		sed -nE "s/.*for \`$MACHINE\`.*HF job \`([0-9a-f]+)\`.*/\1/p" | head -1
}

# resolve WHAT: sets KIND (release or bucket), SRC (tag or folder), IMG (the
# image's name up to .rootfs) and DIR, its download dir. Not in a subshell: it
# sets globals. A bucket folder holds both images; a release, the shipping one.
resolve() {
	case $1 in
	release) KIND=release SRC=$(latest_release) ;;
	microduck-os-v*) KIND=release SRC=$1 ;;
	dev) KIND=bucket SRC=$(latest_dev) ;;
	*) KIND=bucket SRC=$(basename "$1") ;;
	esac
	if [ "$KIND" = release ]; then
		IMG=microduck-image-$MACHINE
	else
		command -v hf >/dev/null || die "hf (the Hugging Face CLI) not found"
		IMG=microduck-image-dev-$MACHINE
	fi
	DIR=$FLASH_DIR/$SRC
	mkdir -p "$DIR"
}

# Names of the files in the resolved source.
src_files() {
	if [ "$KIND" = release ]; then
		gh release view "$SRC" -R "$REPO" --json assets -q '.assets[].name'
	else
		hf buckets ls "$BUCKET/$SRC/" | awk '{ print $NF }' | sed 's|.*/||'
	fi
}

# get NAME DEST: downloads a file of the resolved source unless already there.
get() {
	[ -f "$2" ] && return
	if [ "$KIND" = release ]; then
		gh release download "$SRC" -R "$REPO" -p "$1" -O "$2.part"
	else
		hf buckets cp "$BUCKET/$SRC/$1" "$2.part" >/dev/null
	fi
	mv "$2.part" "$2"
}

# The loader is loader.bin-2017.09 in a bucket folder, <machine>-loader.bin in a
# release. Kept under the release's name either way.
get_loader() {
	local name=loader.bin-2017.09
	[ "$KIND" = bucket ] || name=$MACHINE-loader.bin
	get "$name" "$DIR/$MACHINE-loader.bin"
	check_ddr "$DIR/$MACHINE-loader.bin"
}

# The rk3566 DDR blob with Seeed's trfc_mode=1 (PR #29). The stock blob
# (trfc_mode=0) bricks some boards: docs/agents/beta-board.md, "A board stuck
# in maskrom". Checks the copy in a loader, an idblock, or the idblock at the
# start of a .wic: located by its version string, which sits at a fixed offset
# in the blob, then hashed whole.
DDR_SHA256=00b6e57fee345394541afd83dc9b4f3104ec931729c3f653518a14abbd65b3f4
DDR_SIZE=59240
DDR_FWVER_OFFSET=54701

check_ddr() {
	local file=$1 at
	at=$(head -c 8388608 "$file" | LC_ALL=C grep -obUa 'fwver: v1.26' | head -1 | cut -d: -f1) || true
	[ -n "$at" ] || die "$file: no rk3566 v1.26 DDR blob found"
	[ "$(dd if="$file" bs=1 skip=$((at - DDR_FWVER_OFFSET)) count=$DDR_SIZE 2>/dev/null | sha256)" = "$DDR_SHA256" ] ||
		die "$(basename "$file"): DDR blob lacks trfc_mode=1; it bricks some boards. Use a build from after PR #29."
}

# confirm ACTION WHAT: shows what is about to be written and asks, before any
# large download. FLASH_EMMC_YES=1 skips the question.
confirm() {
	local source built
	if [ "$KIND" = release ]; then
		source="release $SRC, https://github.com/$REPO/releases/tag/$SRC"
	else
		source="CI build, bucket folder $SRC"
	fi
	built=$(sed -nE 's/.*rootfs-([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2}).*/\1-\2-\3 \4:\5/p' <<<"$2")
	{
		echo
		echo "  About to $1 the $MACHINE eMMC with:"
		echo "    source: $source"
		echo "    image:  $2"
		[ -z "$built" ] || echo "    built:  $built"
		echo
	} >&2
	ask "Go ahead?" "nothing written"
}

# ask QUESTION ABORTED: dies with "aborted, ABORTED" unless the answer is yes.
# FLASH_EMMC_YES=1 answers yes.
ask() {
	local answer
	[ -z "${FLASH_EMMC_YES:-}" ] || return 0
	[ -t 0 ] || die "stdin is not a terminal: set FLASH_EMMC_YES=1 to go ahead without asking"
	read -r -p "$1 [y/N] " answer
	case $answer in
	[yY] | [yY][eE][sS]) ;;
	*) die "aborted, $2" ;;
	esac
}

# Prints Maskrom, Loader, or nothing.
mode() {
	rkdt ld 2>/dev/null | grep -oE 'Maskrom|Loader' | head -1 || true
}

# to_loader LOADER: waits for the robot, then gets it to loader mode, running
# LOADER (DRAM init) first if it is in maskrom.
to_loader() {
	local loader=$1 m
	m=$(mode)
	if [ -z "$m" ]; then
		say "waiting for the robot: hold Recovery while powering it on"
		[ "$(uname)" != Darwin ] || say "click Allow when macOS asks about the accessory"
		while [ -z "$m" ]; do sleep 1; m=$(mode); done
	fi
	say "robot in $m mode"
	if [ "$m" = Maskrom ]; then
		[ -n "$loader" ] || die "the robot is in maskrom: needs a loader (run flash once first)"
		say "starting the loader"
		rkdt db "$loader"
		[ "$(uname)" != Darwin ] || say "click Allow again if macOS asks"
		until [ "$(mode)" = Loader ]; do sleep 1; done
	fi
	rkdt rfi || die "the board does not answer: see Troubleshooting in docs/flashing.md"
}

flash() {
	local img zst wic
	check_machine
	resolve "$1"
	img=$(src_files | grep -E "^$IMG\.rootfs-[0-9]+\.wic\.zst\$" | head -1) ||
		die "no $IMG .wic.zst in $SRC"
	zst=$DIR/$img
	wic=${zst%.zst}
	confirm flash "$img"

	get_loader
	if [ ! -f "$wic" ]; then
		get "$img.sha256sum" "$zst.sha256sum"
		say "downloading $img"
		get "$img" "$zst"
		say "checking $img"
		[ "$(sha256 <"$zst")" = "$(awk '{ print $1 }' "$zst.sha256sum")" ] ||
			die "checksum mismatch on $zst; delete it and re-run"
		say "decompressing it (12 GiB)"
		zstd -d -q -f "$zst" -o "$wic.part"
		mv "$wic.part" "$wic"
	fi
	check_ddr "$wic"

	to_loader "$DIR/$MACHINE-loader.bin"
	say "writing $(basename "$wic"): several minutes"
	rkdt wl 0 "$wic"
	[ "$KIND" = release ] || rm -f "$wic"
	say "done. Switch the power off, then on. Do not use 'rkdeveloptool rd' (warm resets hang)."
}

# Where the .wks puts things, in 512-byte sectors (microduck-ab.wks.in).
IDBLOCK_SECTOR=64
IDBLOCK_MAX=$((3552 * 1024))
UBOOT_SECTOR=16384
UBOOT_SIZE=$((4 * 1024 * 1024))

# Rewrites the idblock (DRAM init + SPL) and U-Boot, leaving the partitions
# alone. The board must already carry our image: both go where our .wks puts
# them, which is not necessarily where Seeed's factory image has them.
recover() {
	local job
	check_machine
	resolve "$1"
	if [ "$KIND" = release ]; then
		job=$(release_job "$SRC")
		[ -n "$job" ] || die "$SRC: its notes name no $MACHINE HF job"
		say "$SRC's $MACHINE build is in bucket folder $job"
		resolve "$job"
	fi
	confirm "rewrite the idblock and U-Boot of" "idblock.img-2017.09 + uboot-$MACHINE-2017.09-r0.bin"

	get_loader
	get idblock.img-2017.09 "$DIR/idblock.img" ||
		die "no idblock in $SRC: CI prunes bucket folders 14 days after the build"
	get "uboot-$MACHINE-2017.09-r0.bin" "$DIR/uboot.img"
	check_ddr "$DIR/idblock.img"
	[ "$(size "$DIR/idblock.img")" -le "$IDBLOCK_MAX" ] || die "idblock.img does not fit its 3552 KiB"
	[ "$(size "$DIR/uboot.img")" -eq "$UBOOT_SIZE" ] || die "uboot.img is not 4 MiB"

	to_loader "$DIR/$MACHINE-loader.bin"
	say "writing the idblock"
	rkdt wl "$IDBLOCK_SECTOR" "$DIR/idblock.img"
	say "writing U-Boot"
	rkdt wl "$UBOOT_SECTOR" "$DIR/uboot.img"
	say "done. Switch the power off, then on. If it still does not boot, run flash."
}

# Reads the whole eMMC. Takes rl's length in sectors, as the Homebrew
# rkdeveloptool does; Debian's takes bytes (docs/agents/beta-board.md), which
# the size check below catches.
dump() {
	local file=$1 n loader
	[ -n "$file" ] || die "usage: $0 dump FILE [MACHINE]"
	[ ! -e "$file" ] || die "$file exists"
	check_machine
	loader=$(find "$FLASH_DIR" -maxdepth 2 -name "$MACHINE-loader.bin" 2>/dev/null | head -1)
	to_loader "$loader"
	n=$(rkdt rfi | awk '/Flash Size:.*Sectors/ { print $3 }')
	[ -n "$n" ] || die "could not read the eMMC size from rkdeveloptool rfi"
	say "reading $n sectors ($((n / 2048)) MiB) into $file: about an hour"
	rkdt rl 0 "$n" "$file"
	[ "$(size "$file")" -eq $((n * 512)) ] || die "$file is short: the read did not finish"
	say "done. Compress with: zstd -T0 --rm $file"
}

# Deletes the downloads, after listing them with their sizes and asking. Only
# the folders this script makes are touched (a release tag, a 24-hex bucket
# folder), so a FLASH_DIR pointed at a shared place loses nothing else.
clean() {
	local d name
	local -a dirs=()
	for d in "$FLASH_DIR"/*/; do
		name=$(basename "$d")
		case $name in
		microduck-os-v*) ;;
		*) [[ $name =~ ^[0-9a-f]{24}$ ]] || continue ;;
		esac
		dirs+=("${d%/}")
	done
	if [ ${#dirs[@]} -eq 0 ]; then
		say "nothing to clean in $FLASH_DIR"
		return
	fi
	du -sh "${dirs[@]}" >&2
	ask "Delete these ${#dirs[@]} folders?" "nothing deleted"
	rm -rf "${dirs[@]}"
	rmdir "$FLASH_DIR" 2>/dev/null || true
	say "deleted ${#dirs[@]} folders from $FLASH_DIR"
}

main() {
	local cmd=flash
	case ${1:-} in
	-h | --help | help) usage; exit 0 ;;
	clean) clean; return ;;
	flash | latest | recover | dump) cmd=$1; shift ;;
	esac
	command -v gh >/dev/null || die "gh not found"
	case $cmd in
	dump)
		MACHINE=${2:-microduck-face-board-v1}
		command -v rkdeveloptool >/dev/null || die "rkdeveloptool not found"
		dump "${1:-}"
		return
		;;
	esac
	MACHINE=${2:-microduck-face-board-v1}
	case $cmd in
	latest) check_machine; resolve "${1:-release}"; echo "$SRC" ;;
	flash | recover)
		command -v rkdeveloptool >/dev/null || die "rkdeveloptool not found"
		command -v zstd >/dev/null || die "zstd not found"
		"$cmd" "${1:-release}"
		;;
	esac
}

main "$@"
