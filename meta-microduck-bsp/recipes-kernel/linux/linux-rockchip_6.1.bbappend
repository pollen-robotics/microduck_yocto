# Rockchip vendor BSP 6.1 from Armbian's tree, carrying radxa's board description.
#
# armbian/linux-rockchip rk-6.1-rkr7.2 is Rockchip's rkr7.2 BSP kept merged with
# 6.1 stable: 6.1.172 at this SRCREV, against 6.1.84 for the radxa/kernel
# linux-6.1-stan-rkr4.1 tree this replaces. Two reasons to move:
#   - CVE fixes: radxa's branch stopped at 6.1.84 (early 2024).
#   - rkaiq rkr7 (the beta board's 3A engine, 6.0x32.0) needs a kernel newer than
#     6.1.115: older ones abort at init with "failed to get cac buf info"
#     (Seeed's postinst for that package). The beta board ran 6.1.172 under Armbian.
#
# What is radxa's rather than Armbian's, deliberately -- the parts that describe
# *this* board, which have run on it:
#   0000-*.patch      radxa's rk3566-radxa-zero-3w-aic8800ds2.dts and
#                     rk3566-radxa-zero3.dtsi from 270a678f8364. Armbian's own
#                     Zero 3 dtsi differs in ~300 lines (no rk3568-linux.dtsi,
#                     pmuio2 at 3.3 V instead of 1.8 V), so 0001-0003 stay cut
#                     against radxa's file.
#   radxa-rockchip-linux.kconfig
#                     radxa's arch/arm64/configs/rockchip_linux_defconfig from the
#                     same commit. Rockchip's rkr7.2 one differs in 726 lines; this
#                     keeps the effective config the one the board has run, and
#                     options new since 6.1.84 take their Kconfig default.
#
# Verified present in this tree: gc2093.c and imx219.c (the two camera sensors),
# rk3568-linux.dtsi and the dt-bindings the radxa dts and the beta DTS include.
#
# Fetched shallow (kas/microduck.yml, kernel-shallow): bitbake asks GitHub for
# SRCREV itself at depth 1, so this pin keeps working after Armbian pushes.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRCREV = "e97b8a3f30473ea345e0603a1390bb46fa7cc4f2"
SRC_URI = " \
    git://github.com/armbian/linux-rockchip.git;protocol=https;nobranch=1;branch=rk-6.1-rkr7.2 \
    file://0000-rk3566-radxa-zero-3w-device-tree-from-radxa.patch \
    file://0001-rk3566-radxa-zero-3w-restore-chosen-bootargs.patch \
    file://radxa-rockchip-linux.kconfig \
    file://cgroups.cfg \
    file://mali-csf.cfg \
    file://no-mali400.cfg \
    file://qemu-virt.cfg \
    file://rauc.cfg \
"

# Reproducible boot.img: microduck-bundle refuses a bundle whose boot.img differs from the card's.
#   no-mali400.cfg    the Mali-400 driver baked `date` into the Image
# (resource_tool used to write stack garbage into resource.img and needed a patch;
# this tree zero-initialises those structs itself.)

# The defconfig: radxa's, written into the tree as microduck_defconfig before
# do_kernel_metadata reads ${S}/arch/${ARCH}/configs/${KBUILD_DEFCONFIG}.
#
# Not through meta-rockchip's own mechanism, which cannot take a file from us.
# linux-rockchip.inc's do_kernel_metadata:prepend only assembles a defconfig
# `if [ ! -f "${KBUILD_DEFCONFIG}" ]` -- and rockchip-common.inc's default,
# rockchip_linux_defconfig, is in every Rockchip tree, so it never ran: the
# build took the tree's file as is (radxa's, while the tree was radxa's; in
# Armbian's it would be Rockchip's). Pointing KBUILD_DEFCONFIG at a missing name
# makes it run, but then
#
#     cat ${KBUILD_DEFCONFIGS:-$CONFIGS} > ${KBUILD_DEFCONFIG} || true
#
# is not a bitbake expansion, KBUILD_DEFCONFIGS is not exported, and $CONFIGS is
# a typo for $DEFCONFIGS: `cat` gets no argument and writes an empty defconfig.
# Two HF builds failed on exactly that on 2026-10-22.
#
# The file is not named *defconfig*: kernel-yocto's find_sccs takes any SRC_URI
# file with "defconfig" in its name as a second defconfig and warns that it
# dropped it.
KBUILD_DEFCONFIG = "microduck_defconfig"

microduck_install_defconfig() {
	install -m 0644 "${UNPACKDIR}/radxa-rockchip-linux.kconfig" "${S}/arch/${ARCH}/configs/${KBUILD_DEFCONFIG}"
}
do_kernel_metadata[prefuncs] += "microduck_install_defconfig"

# WATCH OUT when adding config fragments. Assume nothing about the effective
# config: check ${B}/.config after do_configure rather than trusting the
# defconfig name. mali-csf.cfg exists because a SoC-specific override everyone
# assumed was applied never was.

# meta-rockchip's linux-rockchip.inc points PATCHPATH at its own
# linux-rockchip_6.1/ directory: a do_mounts retry plus two drm-rockchip
# cursor/plane HACKs, all cut against JeffyCN's tree. None are needed here, and
# a failed apply is a hard error rather than tolerable fuzz -- so point
# PATCHPATH at a directory that does not exist: auto-patch.bbclass then adds
# nothing. Our patches go through SRC_URI only. A patch auto-patch adds is an
# *absolute* file:// URL, which put the layer's checkout path into the kernel's
# task signatures (moving the layer rehashed the kernel and everything after it).
#
# `:=` because THISDIR is a parse-time variable; a lazy `=` would expand to the
# wrong layer.
PATCHPATH := "${THISDIR}/no-auto-patches"

# See MICRODUCK_MOTOR_UART in conf/machine/include/microduck-common.inc.
#
# Two halves, and the config fragment alone is a no-op. motorbus.cfg turns
# CONFIG_FIQ_DEBUGGER off, which frees the *driver*; the dts patch enables &uart2
# and disables the fiq_debugger node, which frees the *hardware*. Rockchip's
# rk3568-linux.dtsi leaves &uart2 disabled and assigns UART2 to fiq_debugger, so
# with only the fragment applied the board came up on 2026-09-11 with no
# /dev/ttyFIQ0 (correct) and still no /dev/ttyS2 -- fe660000.serial was not even a
# platform device, and robotd kept looping on "cannot open the bus".
#
# The patch is conditional, unlike the ones in SRC_URI above: uart2 must stay
# disabled when MICRODUCK_MOTOR_UART is "0", or that mode loses the serial
# console it exists to keep.
SRC_URI += "${@bb.utils.contains('MICRODUCK_MOTOR_UART', '1', 'file://motorbus.cfg file://0002-rk3566-radxa-zero-3w-uart2-for-the-motor-bus.patch', '', d)}"

# The camera, and unlike the motor bus it needs no config fragment: the sensor
# drivers and the ISP are already =y in radxa's defconfig. The device tree was
# the entire gap -- with i2c2 and the csi2/isp chain left disabled, the board
# showed no /dev/video* and nothing in dmesg whether or not a camera was
# plugged in, which is a confusing way to look broken.
#
# Zero 3W only: it edits radxa's Zero 3W dts, and the beta board's camera is a
# different sensor described (or not yet) in its own DTS. `:append` lands after
# every `+=`, so it is still ordered after the MICRODUCK_MOTOR_UART line; it
# touches a different part of the same file, so it applies whether or not 0002
# did; both orders are checked. (0001 is unconditional and still patches the
# Zero 3W dts on a beta build -- harmless, that dts is simply not built there.)
SRC_URI:append:microduck-zero3 = " file://0003-rk3566-radxa-zero-3w-radxa-camera-8m-imx219.patch"

# A board whose device tree lives in this layer rather than in any kernel tree.
# The machine conf names the file (MICRODUCK_BOARD_DTS); it is copied into the
# kernel source after patching and listed in the rockchip dts Makefile, so the
# normal KERNEL_DEVICETREE build -- and meta-rockchip's per-DTB boot.img, which
# runs `make rockchip/<name>.dtb` through scripts/mkimg -- picks it up like any
# in-tree board.
#
# A file rather than a patch because it is a whole new board in bring-up: it will
# be edited constantly against a schematic that is itself older than the boards,
# and a readable .dts diffs better than a patch of one. Empty for the Zero 3W,
# whose device tree is radxa's own plus the patches above.
#
# A shell postfunc, not do_patch:append -- do_patch is a Python task (AGENTS.md).
MICRODUCK_BOARD_DTS ??= ""
SRC_URI += "${@'file://' + d.getVar('MICRODUCK_BOARD_DTS') if d.getVar('MICRODUCK_BOARD_DTS') else ''}"

microduck_install_board_dts() {
	dts="${MICRODUCK_BOARD_DTS}"
	[ -n "$dts" ] || return 0
	dir="${S}/arch/${ARCH}/boot/dts/rockchip"
	install -m 0644 "${UNPACKDIR}/$dts" "$dir/"
	dtb="${dts%.dts}.dtb"
	grep -qF "$dtb" "$dir/Makefile" || echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += $dtb" >> "$dir/Makefile"
	grep -qF "$dtb" "$dir/Makefile" || bbfatal "$dtb did not make it into $dir/Makefile"
}
do_patch[postfuncs] += "microduck_install_board_dts"

# The beta board's extra kernel options, and a check that they took. Same idea as
# microduck_check_uboot_config: a fragment line whose dependency is missing is
# silently dropped by merge_config, and the first symptom would be a face board
# with no LEDs on a board that otherwise boots fine.
SRC_URI:append:microduck-beta = " file://microduck-beta.cfg"

microduck_check_kernel_fragments() {
	for frag in ${@' '.join(u.split('://')[1].split(';')[0] for u in d.getVar('SRC_URI').split() if u.startswith('file://microduck-') and u.endswith('.cfg'))}; do
		for line in $(grep -vE '^[[:space:]]*(#|$)' ${UNPACKDIR}/$frag); do
			grep -qxF "$line" ${B}/.config || bbfatal "$frag: '$line' is not in the merged ${B}/.config"
		done
	done
}
do_configure[postfuncs] += "microduck_check_kernel_fragments"

# U-Boot boots /boot/microduck.dtb from the slot it picked (recipes-bsp/u-boot/), one
# name for every machine, so the same bootcmd serves both boards. A symlink to the
# DTB kernel-devicetree installs; its FILES glob (**/*.dtb) packages it too.
do_install:append() {
	dtb=$(basename "${@d.getVar('KERNEL_DEVICETREE').split()[0]}")
	[ -f "${D}/${KERNEL_DTBDEST}/$dtb" ] || bbfatal "$dtb is not in /${KERNEL_DTBDEST}: U-Boot would fall back to the boot partition"
	ln -sf "$dtb" "${D}/${KERNEL_DTBDEST}/microduck.dtb"
}
