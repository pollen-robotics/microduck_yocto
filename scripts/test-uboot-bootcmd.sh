#!/bin/bash
# Test the RAUC slot-selection bootcmd in a U-Boot sandbox, before a board.
#
# Why this exists: the script runs as U-Boot's bootcmd on a board with no serial
# console. A hush syntax error there aborts bootcmd at a prompt nobody can see,
# and the only recovery is reflashing the card. So every change to the patch
# gets run here first.
#
# Why a *mainline* v2017.09 sandbox is faithful -- ONLY WITH THE VENDOR'S
# lib/strto.c COPIED IN. The vendor tree the board runs (JeffyCN/mirrors u-boot
# @ a93658f8) has common/cli_hush.c, cmd/test.c, cmd/setexpr.c, lib/ctype.c and
# the setenv/env_get functions of cmd/nvedit.c byte-identical to v2017.09, and
# autoboot runs bootcmd through the same run_command_list() that `u-boot -c`
# uses. lib/strto.c is the exception, and it matters: the vendor's
# simple_strtol honours the base it is given, so `test 0x3 -gt 0` (test passes
# base 10) is FALSE there, while mainline's switches to hex on "0x" and says
# true. A plain mainline sandbox passed a script that looped forever on the
# board (2026-09-25). With the vendor's strto.c the sandbox reproduced that
# board failure exactly, 8 of 9 cases, which is what makes it trustworthy now.
# The vendor tree's own sandbox does not build (Rockchip code is compiled
# unconditionally).
#
# Build the sandbox once (a few minutes; GCC 14 needs the relaxed flags):
#
#   git clone --depth 1 -b v2017.09 https://source.denx.de/u-boot/u-boot.git
#   cd u-boot
#   curl -sfL https://raw.githubusercontent.com/JeffyCN/mirrors/a93658f8f45dc0266be21840931131b10c325e03/lib/strto.c -o lib/strto.c
#   # and the vendor's counter format: its env_set_hex writes "0x%lx", mainline "%lx".
#   # A mainline-format sandbox passed a script that would never have fallen back
#   # on the board (2026-09-30): U-Boot's own "0x0" is not the string "0".
#   sed -i '/^int env_set_hex(/,/^}/{s/char str\[17\];/char str[19];/;s/"%lx", value/"0x%lx", value/}' cmd/nvedit.c
#   make sandbox_defconfig
#   sed -i 's/^CONFIG_SANDBOX_SDL=y/# CONFIG_SANDBOX_SDL is not set/' .config
#   make olddefconfig
#   sed -i '/always += .*_libfdt.so/s/^/#/' tools/Makefile   # needs python2 otherwise
#   W="-fcommon -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-int -std=gnu11"
#   make -j"$(nproc)" HOSTCFLAGS="$W" KCFLAGS="$W" NO_SDL=1 u-boot
#
# Then:  scripts/test-uboot-bootcmd.sh /path/to/u-boot/u-boot
#
# It also needs sgdisk and mke2fs (gdisk, e2fsprogs): the kernel-in-slot cases
# ext4load from a small GPT card image, so that part runs U-Boot's real ext4 code,
# symlinks included -- mainline v2017.09's fs/ext4, which this assumes matches the
# vendor tree's.
#
# The sandbox has no environment storage, so `saveenv` is stubbed with an echo;
# that it actually persists on the board was verified there, not here.
set -euo pipefail

SANDBOX=${1:?usage: $0 /path/to/v2017.09/sandbox/u-boot}
PATCH=$(dirname "$0")/../meta-microduck-bsp/recipes-bsp/u-boot/files/0001-evb_rk3568-select-the-RAUC-slot-before-Rockchip-s-boot.patch
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# The macro exactly as the patch adds it, compiled so the C string escaping is
# the compiler's, not a hand re-typing. RKIMG_BOOTCOMMAND is stubbed with a
# marker so each case can tell whether the boot chain was reached.
{
	echo '#include <stdio.h>'
	echo '#define RKIMG_BOOTCOMMAND "echo REACHED_BOOT_CHAIN;"'
	sed -n 's/^+//; /^#define MICRODUCK_RAUC_SELECT/,/rauc\.slot=\${rauc_slot}; "$/p' "$PATCH"
	sed -n 's/^+//; /^#define MICRODUCK_ROOTFS_BOOT/,/falling back to the boot partition\\"; "$/p' "$PATCH"
	echo 'int main(void){ fputs(MICRODUCK_RAUC_SELECT MICRODUCK_ROOTFS_BOOT RKIMG_BOOTCOMMAND, stdout); return 0; }'
} > "$work/gen.c"
gcc -o "$work/gen" "$work/gen.c"
# booti does not exist on the sandbox (not arm64): stub it with a marker and reset,
# which ends the process as a real booti would.
BOOTCMD=$("$work/gen" | sed -e 's/saveenv;/echo SAVEENV_CALLED;/g' \
	-e 's/booti \${kernel_addr_r} - \${fdt_addr_r};/echo BOOTI_FROM_PART ${rauc_partnum}; reset;/')
[ -n "$BOOTCMD" ] || { echo "could not extract the boot script from $PATCH"; exit 1; }
grep -qF BOOTI_FROM_PART <<< "$BOOTCMD" || { echo "booti stub did not apply; $PATCH changed shape"; exit 1; }

# A card for ext4load, bound as host device 0: GPT with the wks's entries, ext4 in
# partitions 6 (rootfs_a) and 7 (rootfs_b). /boot/Image and microduck.dtb are
# symlinks, as on the real rootfs, so U-Boot's ext4 symlink handling is exercised.
# mkcard CARD A B: A/B = 1 puts a kernel in that slot.
mkcard() {
	local card=$1 a_kernel=$2 b_kernel=$3 fs want
	truncate -s 64M "$card"
	# -o in a call of its own: combined with -n on a fresh file, sgdisk writes no
	# entries and still exits 0.
	sgdisk -o "$card" >/dev/null
	sgdisk -n 1:2048:+256K -n 2:0:+32K -n 3:0:+1M -n 4:0:+1M -n 5:0:+1M \
		-n 6:0:+16M -n 7:0:+16M "$card" >/dev/null
	for p in 6 7; do
		fs=$work/fs$p; rm -rf "$fs"; mkdir -p "$fs/boot"
		want=$a_kernel; [ "$p" = 7 ] && want=$b_kernel
		if [ "$want" = 1 ]; then
			echo "kernel-$p" > "$fs/boot/Image-6.1.84"; ln -s Image-6.1.84 "$fs/boot/Image"
			echo "dtb-$p" > "$fs/boot/board.dtb"; ln -s board.dtb "$fs/boot/microduck.dtb"
		fi
		mke2fs -q -t ext4 -d "$fs" "$work/p$p.img" 16M
		start=$(sgdisk -i "$p" "$card" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
		dd if="$work/p$p.img" of="$card" bs=512 seek="$start" conv=notrunc status=none
	done
}
mkcard "$work/none" 0 0; mkcard "$work/both" 1 1; mkcard "$work/a-only" 1 0
# devtype/devnum come from Rockchip's board init on the board; addresses are the
# board's kernel_addr_r/fdt_addr_r, inside the sandbox's RAM. The slot-selection
# cases run on a card with no kernel anywhere, so the script falls through to the
# boot chain and the counters are printed afterwards.
dev() { echo "host bind 0 $work/$1; setenv devtype host; setenv devnum 0; setenv kernel_addr_r 0x1000000; setenv fdt_addr_r 0x3000000;"; }
HOSTDEV=$(dev none)

pass=0; fail=0
check() {  # name, env setup, then expected substrings
	local name=$1 setup=$2; shift 2
	local out ok=1
	out=$("$SANDBOX" -c "$HOSTDEV $setup $BOOTCMD printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT bootargs" 2>&1) || true
	for want in "$@"; do grep -qF -- "$want" <<< "$out" || { ok=0; echo "     missing: $want"; }; done
	grep -qiE 'syntax error|Unknown command' <<< "$out" && { ok=0; echo "     parser complained"; }
	if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}

check "virgin env: seeds, picks A, decrements" "" \
	"booting slot A (rootfs_a)" "BOOT_ORDER=A" "BOOT_A_LEFT=0x2" "BOOT_B_LEFT=3" \
	"bootargs=root=PARTLABEL=rootfs_a rauc.slot=A" "SAVEENV_CALLED" "REACHED_BOOT_CHAIN"
check "after rauc install: B first" \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"booting slot B (rootfs_b)" "BOOT_A_LEFT=3" "BOOT_B_LEFT=0x2" "bootargs=root=PARTLABEL=rootfs_b rauc.slot=B"
check "B exhausted by RAUC (0): falls back to A, BOOT_ORDER untouched" \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 0;" \
	"booting slot A (rootfs_a)" "BOOT_ORDER=B A" "BOOT_A_LEFT=0x2" "BOOT_B_LEFT=0"
check "B exhausted by U-Boot itself (0x0): falls back to A" \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 0x0;" \
	"booting slot A (rootfs_a)" "BOOT_A_LEFT=0x2" "BOOT_B_LEFT=0x0"
check "a counter U-Boot wrote (0x2) still boots, to 0x1" \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 0x2;" \
	"booting slot B (rootfs_b)" "BOOT_B_LEFT=0x1"
check "A marked bad by RAUC (absent from BOOT_ORDER)" \
	"setenv BOOT_ORDER B; setenv BOOT_A_LEFT 0; setenv BOOT_B_LEFT 3;" \
	"booting slot B (rootfs_b)" "BOOT_ORDER=B" "BOOT_B_LEFT=0x2"
check "hex counter: a (=10) is > 0, decrements to 9" \
	"setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT a; setenv BOOT_B_LEFT 3;" \
	"booting slot A" "BOOT_A_LEFT=0x9"
check "counter 1 still boots, reaches 0" \
	"setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT 1; setenv BOOT_B_LEFT 3;" \
	"booting slot A" "BOOT_A_LEFT=0x0"
check "empty BOOT_A_LEFT: seeded, no abort" \
	"setenv BOOT_ORDER 'A B'; setenv BOOT_B_LEFT 3;" \
	"booting slot A" "BOOT_A_LEFT=0x2"
check "A pinned (BOOT_ORDER=A): boots A while it has attempts" \
	"setenv BOOT_A_LEFT 1; setenv BOOT_B_LEFT 3;" \
	"booting slot A (rootfs_a)" "BOOT_ORDER=A" "BOOT_A_LEFT=0x0" "BOOT_B_LEFT=3"
check "unknown bootname skipped" \
	"setenv BOOT_ORDER 'X B'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"booting slot B"

# Both exhausted, in U-Boot's own format for one of them: counters reset, then
# `reset` -- which ends the sandbox process, so the boot chain must never be reached.
out=$("$SANDBOX" -c "setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT 0; setenv BOOT_B_LEFT 0x0; $BOOTCMD" 2>&1) || true
if grep -qF "no slot has attempts left" <<< "$out" && ! grep -qF REACHED_BOOT_CHAIN <<< "$out"; then
	pass=$((pass + 1)); echo "ok   both exhausted: resets and reboots, never boots"
else fail=$((fail + 1)); echo "FAIL both exhausted: resets and reboots, never boots"; fi

# A pinned and spent: B still has attempts but is not in BOOT_ORDER, so it must
# not be booted -- counters reset and the board resets onto A again.
out=$("$SANDBOX" -c "setenv BOOT_A_LEFT 0x0; setenv BOOT_B_LEFT 3; $BOOTCMD" 2>&1) || true
if grep -qF "no slot has attempts left" <<< "$out" && ! grep -qF "booting slot B" <<< "$out" && ! grep -qF REACHED_BOOT_CHAIN <<< "$out"; then
	pass=$((pass + 1)); echo "ok   A pinned and spent: resets, never boots B"
else fail=$((fail + 1)); echo "FAIL A pinned and spent: resets, never boots B"; fi

# The kernel in the slot: booted from the slot's own partition, and never through
# Rockchip's chain. Then a slot without one falls back to that chain.
boot_case() {  # name, card, env setup, then expected / forbidden (!-prefixed) substrings
	local name=$1 card=$2 setup=$3 out ok=1; shift 3
	out=$("$SANDBOX" -c "$(dev "$card") $setup $BOOTCMD" 2>&1) || true
	for want in "$@"; do
		case "$want" in
		!*) grep -qF -- "${want#!}" <<< "$out" && { ok=0; echo "     unexpected: ${want#!}"; } ;;
		*) grep -qF -- "$want" <<< "$out" || { ok=0; echo "     missing: $want"; } ;;
		esac
	done
	grep -qiE 'syntax error|Unknown command' <<< "$out" && { ok=0; echo "     parser complained"; }
	if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; echo "$out" | tail -5 | sed 's/^/     | /'; fi
}
boot_case "kernel in A: loaded from partition 6, Rockchip chain not reached" both "" \
	"RAUC: kernel from rootfs_a" "BOOTI_FROM_PART 6" "!REACHED_BOOT_CHAIN"
boot_case "after rauc install, B first: loaded from partition 7" both \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"RAUC: kernel from rootfs_b" "BOOTI_FROM_PART 7" "!REACHED_BOOT_CHAIN"
boot_case "B has no kernel: falls back to the boot partition" a-only \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"no kernel in rootfs_b, falling back" "REACHED_BOOT_CHAIN" "!BOOTI_FROM_PART"

echo "---- $pass passed, $fail failed  (bootcmd ${#BOOTCMD} chars; CONFIG_SYS_CBSIZE does not bound it)"
[ "$fail" = 0 ]
