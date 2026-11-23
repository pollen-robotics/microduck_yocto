# Armbian's rk-6.1-rkr7.2 with radxa's Zero 3W DTS and defconfig: CVE fixes, and
# rkaiq rkr7 needs a kernel past 6.1.115. Every part: docs/agents/kernel.md.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI = " \
    git://github.com/armbian/linux-rockchip.git;protocol=https;nobranch=1;branch=rk-6.1-rkr7.2 \
    file://0000-rk3566-radxa-zero-3w-device-tree-from-radxa.patch \
    file://0001-rk3566-radxa-zero-3w-restore-chosen-bootargs.patch \
    file://radxa-rockchip-linux.kconfig \
    file://cgroups.cfg \
    file://microduck-gamepads.cfg \
    file://mali-csf.cfg \
    file://no-mali400.cfg \
    file://no-mali-gpu.cfg \
    file://qemu-virt.cfg \
    file://microduck-readonly-rootfs.cfg \
    file://rauc.cfg \
    file://watchdog.cfg \
"

# Radxa's defconfig is for every board radxa sells; these take out what no
# microduck has. One fragment per area, so a regression bisects to one.
SRC_URI += " \
    file://microduck-trim-debug.cfg \
    file://microduck-trim-fs.cfg \
    file://microduck-trim-input.cfg \
    file://microduck-trim-keep.cfg \
    file://microduck-trim-net.cfg \
    file://microduck-trim-storage.cfg \
    file://microduck-trim-virt.cfg \
"

# Exploited-CVE backports (docs/agents/kernel.md has the table). Drop each once
# SRCREV reaches the stable release that carries it: it will no longer apply.
SRC_URI += " \
    file://0010-net-skbuff-preserve-shared-frag-marker-during-coalescing.patch \
    file://0011-netfilter-bridge-make-ebt-snat-ARP-rewrite-writable.patch \
    file://0012-ipv6-account-for-fraggap-on-the-paged-allocation-path.patch \
    file://0013-rtmutex-Use-waiter-task-instead-of-current-in.patch \
    file://0014-ipv6-mcast-extend-RCU-protection-in-igmp6-send.patch \
"

# boot.img with the board DTB and no kernel: U-Boot reads its own DTB there
# (without it, no serial number); the kernel comes from the slot.
microduck_boot_img_dtb_only() {
	[ -s "${B}/resource.img" ] || bbfatal "no resource.img in ${B}: mkimg changed"
	for img in boot.img zboot.img; do
		"${S}/scripts/mkbootimg" --kernel /dev/null --second "${B}/resource.img" -o "${B}/$img"
	done
}
do_compile[postfuncs] += "microduck_boot_img_dtb_only"

# meta-rockchip's defconfig assembly cannot take our file, so install it. Not
# named *defconfig*: kernel-yocto would drop it as a second defconfig.
KBUILD_DEFCONFIG = "microduck_defconfig"

microduck_install_defconfig() {
	install -m 0644 "${UNPACKDIR}/radxa-rockchip-linux.kconfig" "${S}/arch/${ARCH}/configs/${KBUILD_DEFCONFIG}"
}
do_kernel_metadata[prefuncs] += "microduck_install_defconfig"

# A directory that does not exist: meta-rockchip's auto-patches are not for this
# tree and would put absolute layer paths in the signatures. `:=` for THISDIR.
PATCHPATH := "${THISDIR}/no-auto-patches"

# Both halves or neither: the fragment frees the driver, the DTS patch the UART.
SRC_URI += "${@bb.utils.contains('MICRODUCK_MOTOR_UART', '1', 'file://motorbus.cfg file://0002-rk3566-radxa-zero-3w-uart2-for-the-motor-bus.patch', '', d)}"

# Applies with or without 0002; both orders are checked.
SRC_URI:append:microduck-zero3 = " file://0003-rk3566-radxa-zero-3w-radxa-camera-8m-imx219.patch"

# Board DTS files kept in this layer, copied into the tree and its Makefile.
# A list: a variant's DTS can include another. Postfunc: do_patch is Python.
MICRODUCK_BOARD_DTS ??= ""
SRC_URI += "${@' '.join('file://' + f for f in d.getVar('MICRODUCK_BOARD_DTS').split())}"

microduck_install_board_dts() {
	dir="${S}/arch/${ARCH}/boot/dts/rockchip"
	for dts in ${MICRODUCK_BOARD_DTS}; do
		install -m 0644 "${UNPACKDIR}/$dts" "$dir/"
		dtb="${dts%.dts}.dtb"
		grep -qF "$dtb" "$dir/Makefile" || echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += $dtb" >> "$dir/Makefile"
		grep -qF "$dtb" "$dir/Makefile" || bbfatal "$dtb did not make it into $dir/Makefile"
	done
}
do_patch[postfuncs] += "microduck_install_board_dts"

SRC_URI:append:microduck-beta = " file://microduck-beta.cfg file://microduck-trim-display.cfg file://microduck-trim-media.cfg"

# Only on this machine, so the other boards' kernels stay byte-identical.
SRC_URI:append:microduck-face-board-v1 = " \
    file://0005-leds-add-Awinic-AW2023-LED-driver.patch \
    file://0006-leds-add-Awinic-AW21009-LED-driver.patch \
    file://microduck-face-board-v1.cfg \
"

# After every SRC_URI line, as oelint.var.order wants.
SRCREV = "e97b8a3f30473ea345e0603a1390bb46fa7cc4f2"

# merge_config drops a line whose dependency is missing, silently, and another
# option's `select` turns an "is not set" back on just as silently.
microduck_check_kernel_fragments() {
	for frag in ${@' '.join(u.split('://')[1].split(';')[0] for u in d.getVar('SRC_URI').split() if u.startswith('file://microduck-') and u.endswith('.cfg'))}; do
		for line in $(grep -E '^CONFIG_' ${UNPACKDIR}/$frag); do
			grep -qxF "$line" ${B}/.config || bbfatal "$frag: '$line' is not in the merged ${B}/.config"
		done
		for sym in $(sed -n 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p' ${UNPACKDIR}/$frag); do
			! grep -qE "^$sym=" ${B}/.config || bbfatal "$frag: $sym is off in the fragment but $(grep -E "^$sym=" ${B}/.config) in ${B}/.config"
		done
	done
}
do_configure[postfuncs] += "microduck_check_kernel_fragments"

# One DTB name for every machine, so one U-Boot bootcmd serves them all.
do_install:append() {
	dtb=$(basename "${@d.getVar('KERNEL_DEVICETREE').split()[0]}")
	[ -f "${D}/${KERNEL_DTBDEST}/$dtb" ] || bbfatal "$dtb is not in /${KERNEL_DTBDEST}: U-Boot would fall back to the boot partition"
	ln -sf "$dtb" "${D}/${KERNEL_DTBDEST}/microduck.dtb"
}
