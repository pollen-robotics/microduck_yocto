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

# The macros exactly as the patch adds them, compiled so the C string escaping is
# the compiler's, not a hand re-typing. `gen select` prints the slot selection
# alone, `gen` the whole bootcmd.
{
	echo '#include <stdio.h>'
	echo '#include <string.h>'
	sed -n 's/^+//; /^#define MICRODUCK_RAUC_SELECT/,/rauc\.slot=\${rauc_slot}; "$/p' "$PATCH"
	sed -n 's/^+//; /^#define MICRODUCK_ROOTFS_[AB]_GUID /p' "$PATCH"
	sed -n 's/^+//; /^#define MICRODUCK_ROOTFS_BOOT/,/^[[:space:]]*"fi; "$/p' "$PATCH"
	echo 'int main(int c, char **v){ fputs(c > 1 && !strcmp(v[1], "select") ? MICRODUCK_RAUC_SELECT : MICRODUCK_RAUC_SELECT MICRODUCK_ROOTFS_BOOT, stdout); return 0; }'
} > "$work/gen.c"
gcc -o "$work/gen" "$work/gen.c"
stub_saveenv() { sed -e 's/saveenv;/echo SAVEENV_CALLED;/g'; }
# The slot-selection cases: selection alone, then a marker, then the counters are
# printed. A `reset` (both slots spent) ends the process before the marker.
SELECT="$("$work/gen" select | stub_saveenv) echo AFTER_SELECT;"
# booti does not exist on the sandbox (not arm64): stub it with a marker and reset,
# which ends the process as a real booti would.
BOOTCMD=$("$work/gen" | stub_saveenv |
	sed -e 's/booti \${kernel_addr_r} - \${fdt_addr_r};/echo BOOTI_FROM_PART ${rauc_partnum} nokernel=${rauc_nokernel}.; reset;/')
[ -n "$BOOTCMD" ] || { echo "could not extract the boot script from $PATCH"; exit 1; }
grep -qF BOOTI_FROM_PART <<< "$BOOTCMD" || { echo "booti stub did not apply; $PATCH changed shape"; exit 1; }
grep -qF 'giving up on slot' <<< "$BOOTCMD" || { echo "no-kernel path not extracted; $PATCH changed shape"; exit 1; }
# Every reset turned into a marker, so the counters a no-kernel boot leaves can be
# printed afterwards.
NORESET=$(sed -e 's/reset;/echo RESET_CALLED;/g' <<< "$BOOTCMD")

# A card for ext4load, bound as host device 0: GPT with the wks's entries and the
# slots' fixed partition GUIDs, which is how the script finds them. Three layouts:
# "new" (boot, no boot_b: rootfs_a 5, rootfs_b 6, data 7), "noboot" (cards flashed by
# a #98 build, no boot either: 4, 5, 6) and "old" (cards flashed with boot and
# boot_b: 6, 7, 8); "noguid" is the new layout without the GUIDs.
# /boot/Image and microduck.dtb are symlinks, as on the real rootfs, so U-Boot's ext4
# symlink handling is exercised.
# mkcard CARD LAYOUT A B: A/B = 1 puts a kernel in that slot.
GUID_A=$(sed -n 's/^+#define MICRODUCK_ROOTFS_A_GUID "\(.*\)"$/\1/p' "$PATCH")
GUID_B=$(sed -n 's/^+#define MICRODUCK_ROOTFS_B_GUID "\(.*\)"$/\1/p' "$PATCH")
mkcard() {
	local card=$1 layout=$2 a_kernel=$3 b_kernel=$4 fs want pa pb
	truncate -s 64M "$card"
	# -o in a call of its own: combined with -n on a fresh file, sgdisk writes no
	# entries and still exits 0.
	sgdisk -o "$card" >/dev/null
	if [ "$layout" = old ]; then
		pa=6; pb=7
		sgdisk -n 1:2048:+256K -n 2:0:+32K -n 3:0:+1M -n 4:0:+1M -n 5:0:+1M \
			-n 6:0:+16M -n 7:0:+16M -n 8:0:+1M "$card" >/dev/null
	elif [ "$layout" = noboot ]; then
		pa=4; pb=5
		sgdisk -n 1:2048:+256K -n 2:0:+32K -n 3:0:+1M \
			-n 4:0:+16M -n 5:0:+16M -n 6:0:+1M "$card" >/dev/null
	else
		pa=5; pb=6
		sgdisk -n 1:2048:+256K -n 2:0:+32K -n 3:0:+1M -n 4:0:+1M \
			-n 5:0:+16M -n 6:0:+16M -n 7:0:+1M "$card" >/dev/null
	fi
	[ "$layout" = noguid ] || sgdisk -u "$pa:$GUID_A" -u "$pb:$GUID_B" "$card" >/dev/null
	for p in $pa $pb; do
		fs=$work/fs$p; rm -rf "$fs"; mkdir -p "$fs/boot"
		want=$a_kernel; [ "$p" = "$pb" ] && want=$b_kernel
		if [ "$want" = 1 ]; then
			echo "kernel-$p" > "$fs/boot/Image-6.1.84"; ln -s Image-6.1.84 "$fs/boot/Image"
			echo "dtb-$p" > "$fs/boot/board.dtb"; ln -s board.dtb "$fs/boot/microduck.dtb"
		fi
		mke2fs -q -t ext4 -d "$fs" "$work/p$p.img" 16M
		start=$(sgdisk -i "$p" "$card" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
		dd if="$work/p$p.img" of="$card" bs=512 seek="$start" conv=notrunc status=none
	done
}
[ -n "$GUID_A" ] && [ -n "$GUID_B" ] || { echo "no MICRODUCK_ROOTFS_[AB]_GUID in $PATCH"; exit 1; }
mkcard "$work/none" new 0 0; mkcard "$work/both" new 1 1; mkcard "$work/a-only" new 1 0
mkcard "$work/old-both" old 1 1; mkcard "$work/noboot-both" noboot 1 1; mkcard "$work/noguid" noguid 1 1
# devtype/devnum come from Rockchip's board init on the board; addresses are the
# board's kernel_addr_r/fdt_addr_r, inside the sandbox's RAM.
dev() { echo "host bind 0 $work/$1; setenv devtype host; setenv devnum 0; setenv kernel_addr_r 0x1000000; setenv fdt_addr_r 0x3000000;"; }

pass=0; fail=0
check() {  # name, env setup, then expected substrings
	local name=$1 setup=$2; shift 2
	local out ok=1
	out=$("$SANDBOX" -c "$setup $SELECT printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT bootargs" 2>&1) || true
	for want in "$@"; do grep -qF -- "$want" <<< "$out" || { ok=0; echo "     missing: $want"; }; done
	grep -qiE 'syntax error|Unknown command' <<< "$out" && { ok=0; echo "     parser complained"; }
	if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}

check "virgin env: seeds, picks A, decrements" "" \
	"booting slot A (rootfs_a)" "BOOT_ORDER=A" "BOOT_A_LEFT=0x2" "BOOT_B_LEFT=3" \
	"bootargs=root=PARTLABEL=rootfs_a rauc.slot=A" "SAVEENV_CALLED" "AFTER_SELECT"
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
# `reset` -- which ends the sandbox process, so nothing after the selection runs.
out=$("$SANDBOX" -c "setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT 0; setenv BOOT_B_LEFT 0x0; $SELECT" 2>&1) || true
if grep -qF "no slot has attempts left" <<< "$out" && ! grep -qF AFTER_SELECT <<< "$out"; then
	pass=$((pass + 1)); echo "ok   both exhausted: resets and reboots, never boots"
else fail=$((fail + 1)); echo "FAIL both exhausted: resets and reboots, never boots"; fi

# A pinned and spent: B still has attempts but is not in BOOT_ORDER, so it must
# not be booted -- counters reset and the board resets onto A again.
out=$("$SANDBOX" -c "setenv BOOT_A_LEFT 0x0; setenv BOOT_B_LEFT 3; $SELECT" 2>&1) || true
if grep -qF "no slot has attempts left" <<< "$out" && ! grep -qF "booting slot B" <<< "$out" && ! grep -qF AFTER_SELECT <<< "$out"; then
	pass=$((pass + 1)); echo "ok   A pinned and spent: resets, never boots B"
else fail=$((fail + 1)); echo "FAIL A pinned and spent: resets, never boots B"; fi

# The kernel in the slot: booted from the slot's own partition. A slot without one
# is given up on: its counter zeroed and saved, then a reset. CMD picks the
# variant: BOOTCMD as on the board, NORESET to print the counters left behind.
boot_case() {  # name, card, env setup, then expected / forbidden (!-prefixed) substrings
	local name=$1 card=$2 setup=$3 out ok=1; shift 3
	out=$("$SANDBOX" -c "$(dev "$card") $setup ${CMD:-$BOOTCMD} printenv BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT rauc_nokernel" 2>&1) || true
	for want in "$@"; do
		case "$want" in
		!*) grep -qF -- "${want#!}" <<< "$out" && { ok=0; echo "     unexpected: ${want#!}"; } ;;
		*) grep -qF -- "$want" <<< "$out" || { ok=0; echo "     missing: $want"; } ;;
		esac
	done
	grep -qiE 'syntax error|Unknown command' <<< "$out" && { ok=0; echo "     parser complained"; }
	if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; echo "$out" | tail -5 | sed 's/^/     | /'; fi
}
boot_case "new layout, kernel in A: found by GUID at partition 5" both "" \
	"rootfs_a is partition 5" "RAUC: kernel from rootfs_a" "BOOTI_FROM_PART 5" "!giving up" "!BOOT_ORDER="
boot_case "new layout, B first: found by GUID at partition 6" both \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"rootfs_b is partition 6" "RAUC: kernel from rootfs_b" "BOOTI_FROM_PART 6" "!giving up"
boot_case "a #98 card (no boot), A: found at partition 4" noboot-both "" \
	"rootfs_a is partition 4" "BOOTI_FROM_PART 4" "!giving up"
boot_case "old layout (boot and boot_b), A: found at partition 6" old-both "" \
	"rootfs_a is partition 6" "BOOTI_FROM_PART 6" "!giving up"
boot_case "old layout, B first: found at partition 7" old-both \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"rootfs_b is partition 7" "BOOTI_FROM_PART 7" "!giving up"
# A card whose slots lack the GUIDs: nothing found, so nothing is loaded from a
# guessed partition -- handled as a slot without a kernel.
CMD=$NORESET boot_case "no slot GUID on the card: no partition guessed" noguid \
	"setenv BOOT_ORDER 'A B';" "!BOOTI_FROM_PART" "giving up on slot A"
# On the board the reset ends it: nothing may run after giving up on a slot.
boot_case "B has no kernel: gives up and resets, boots nothing" a-only \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"no bootable kernel in rootfs_b, giving up on slot B" "!BOOTI_FROM_PART" "!BOOT_ORDER="
# With reset stubbed: B's counter is zeroed and saved, so the next boot takes A;
# A's is untouched and BOOT_ORDER is left to RAUC.
CMD=$NORESET boot_case "B has no kernel: zeroes and saves B, next boot is A" a-only \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 3;" \
	"SAVEENV_CALLED" "RESET_CALLED" "BOOT_ORDER=B A" "BOOT_A_LEFT=3" "BOOT_B_LEFT=0" "rauc_nokernel=1" "!BOOTI_FROM_PART"
CMD=$NORESET boot_case "no kernel anywhere: gives up on A first" none "setenv BOOT_ORDER 'A B';" \
	"giving up on slot A" "BOOT_A_LEFT=0" "BOOT_B_LEFT=3" "rauc_nokernel=1" "!BOOTI_FROM_PART"
# ... then, after that reset, B has none either: it stops rather than give up on B
# too, reset into "no slot has attempts left", restore both counters and go round
# again for ever. The mark is cleared, so a power cycle tries both once more.
CMD=$NORESET boot_case "no kernel anywhere, A already given up: stops on B, no loop" none \
	"setenv BOOT_ORDER 'A B'; setenv BOOT_A_LEFT 0; setenv BOOT_B_LEFT 3; setenv rauc_nokernel 1;" \
	"no bootable kernel in rootfs_b either; stopping" "BOOT_B_LEFT=0x2" "!RESET_CALLED" "!giving up" \
	"!rauc_nokernel=1" "!BOOTI_FROM_PART"
# A kernel that loads clears the mark before booting, so a later slot without a
# kernel is given up on as usual rather than taken for the second of a pair.
boot_case "B given up, A has a kernel: the mark is cleared before booting A" a-only \
	"setenv BOOT_ORDER 'B A'; setenv BOOT_A_LEFT 3; setenv BOOT_B_LEFT 0; setenv rauc_nokernel 1;" \
	"BOOTI_FROM_PART 5 nokernel=." "!nokernel=1"
# A one-slot order (every board once a trial ends): nothing to reset onto, so it
# stops -- no zeroing, no second saveenv, no reset -- instead of looping.
CMD=$NORESET boot_case "A alone in BOOT_ORDER without a kernel: stops, no loop" none "" \
	"no other slot to boot; stopping" "BOOT_ORDER=A" "BOOT_A_LEFT=0x2" "!RESET_CALLED" "!giving up" "!BOOTI_FROM_PART"
boot_case "  ... and, as on the board, nothing runs after it" none "" \
	"no other slot to boot; stopping" "!BOOTI_FROM_PART"

echo "---- $pass passed, $fail failed  (bootcmd ${#BOOTCMD} chars; CONFIG_SYS_CBSIZE does not bound it)"
[ "$fail" = 0 ]
