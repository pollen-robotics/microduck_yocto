#!/usr/bin/env bash
# Write a release onto a robot's eMMC over USB-C: docs/flashing.md, scripted.
#
#   scripts/flash-emmc.sh [TAG] [MACHINE]
#   scripts/flash-emmc.sh microduck-os-v1.0.1 microduck-face-board-v1
#
# TAG defaults to the latest release, MACHINE to microduck-face-board-v1. Files
# are downloaded and decompressed once, into $FLASH_DIR/TAG (default
# ~/microduck-flash), and reused for every robot after that: run the script
# again for the next one.
#
# Needs: gh, zstd, rkdeveloptool. On a Mac:
#   brew install gh zstd pierre-rouanet/tools/rkdeveloptool
# The robot must be in maskrom or loader mode: hold Recovery while powering it
# on. On a Mac, click Allow when macOS asks about the USB accessory.
set -euo pipefail

REPO=pollen-robotics/microduck_yocto
TAG=${1:-}
MACHINE=${2:-microduck-face-board-v1}
FLASH_DIR=${FLASH_DIR:-$HOME/microduck-flash}

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# rkdeveloptool needs root on Linux (no udev rule), not on macOS.
rkdt() {
	if [ "$(uname)" = Darwin ]; then rkdeveloptool "$@"; else sudo rkdeveloptool "$@"; fi
}

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum | awk '{ print $1 }'
	else shasum -a 256 | awk '{ print $1 }'; fi
}

# Prints Maskrom, Loader, or nothing.
mode() {
	rkdt ld 2>/dev/null | grep -oE 'Maskrom|Loader' | head -1 || true
}

# The rk3566 DDR blob with Seeed's trfc_mode=1 (PR #29). The stock blob
# (trfc_mode=0) bricks some boards: docs/agents/beta-board.md, "A board stuck
# in maskrom". Located in the loader by its version string, which sits at a
# fixed offset in the blob, then hashed whole.
DDR_SHA256=00b6e57fee345394541afd83dc9b4f3104ec931729c3f653518a14abbd65b3f4
DDR_SIZE=59240
DDR_FWVER_OFFSET=54701

check_ddr() {
	local file=$1 at
	at=$(LC_ALL=C grep -obUa 'fwver: v1.26' "$file" | head -1 | cut -d: -f1)
	[ -n "$at" ] || die "$file: no rk3566 v1.26 DDR blob found"
	[ "$(dd if="$file" bs=1 skip=$((at - DDR_FWVER_OFFSET)) count=$DDR_SIZE 2>/dev/null | sha256)" = "$DDR_SHA256" ] ||
		die "$(basename "$file"): DDR blob lacks trfc_mode=1; it bricks some boards"
}

# Downloads, checks and decompresses the release once. Prints the .wic path.
prepare() {
	local dir=$1 loader zst wic
	loader=$dir/$MACHINE-loader.bin
	zst=$(ls "$dir"/microduck-image-"$MACHINE".rootfs-*.wic.zst 2>/dev/null | head -1 || true)
	if [ ! -f "$loader" ] || [ -z "$zst" ]; then
		say "downloading $TAG for $MACHINE into $dir"
		gh release download "$TAG" -R "$REPO" -D "$dir" --skip-existing \
			-p "$MACHINE-loader.bin" \
			-p "microduck-image-$MACHINE.rootfs-*.wic.zst*"
		zst=$(ls "$dir"/microduck-image-"$MACHINE".rootfs-*.wic.zst | head -1)
	fi
	wic=${zst%.zst}
	check_ddr "$loader"
	if [ ! -f "$wic" ]; then
		say "checking $(basename "$zst")"
		[ "$(sha256 <"$zst")" = "$(awk '{ print $1 }' "$zst.sha256sum")" ] ||
			die "checksum mismatch on $zst; delete it and re-run"
		say "decompressing it (12 GiB)"
		zstd -d -q "$zst" -o "$wic.part"
		mv "$wic.part" "$wic"
	fi
	echo "$wic"
}

main() {
	local dir wic m
	command -v rkdeveloptool >/dev/null || die "rkdeveloptool not found"
	[ -n "$TAG" ] || TAG=$(gh release view -R "$REPO" --json tagName -q .tagName)
	dir=$FLASH_DIR/$TAG
	mkdir -p "$dir"
	wic=$(prepare "$dir")

	m=$(mode)
	if [ -z "$m" ]; then
		say "waiting for the robot: hold Recovery while powering it on"
		[ "$(uname)" != Darwin ] || say "click Allow when macOS asks about the accessory"
		while [ -z "$m" ]; do sleep 1; m=$(mode); done
	fi
	say "robot in $m mode"
	if [ "$m" = Maskrom ]; then
		say "starting the loader"
		rkdt db "$dir/$MACHINE-loader.bin"
		[ "$(uname)" != Darwin ] || say "click Allow again if macOS asks"
		until [ "$(mode)" = Loader ]; do sleep 1; done
	fi
	rkdt rfi || die "the board does not answer: see Troubleshooting in docs/flashing.md"
	say "writing $(basename "$wic"): several minutes"
	rkdt wl 0 "$wic"
	say "done. Switch the power off, then on. Do not use 'rkdeveloptool rd'."
}

main
