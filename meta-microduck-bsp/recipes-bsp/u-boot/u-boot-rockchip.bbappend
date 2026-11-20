# A writable U-Boot environment and A/B slot selection for RAUC.
# docs/agents/rauc.md has the why and the traps.
#
# Named without `_%`: the upstream recipe file is u-boot-rockchip.bb, and an
# unmatched bbappend fails the whole parse.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# `+=`, never `=`: SRC_URI carries a second git entry, rkbin, that make.sh needs.
# Run scripts/test-uboot-bootcmd.sh before changing 0001. 0002-0006 are mainline
# ext4/DOS fixes; their `CVE:` lines are how cve-check marks them patched.
SRC_URI += " \
    file://rauc-env.cfg \
    file://no-network.cfg \
    file://fw_env.config \
    file://0001-evb_rk3568-select-the-RAUC-slot-before-Rockchip-s-boot.patch \
    file://0002-Fix-ext4-block-group-descriptor-sizing.patch \
    file://0003-CVE-2019-13103-disk-stop-infinite-recursion-in-DOS.patch \
    file://0004-CVE-2019-13104-ext4-check-for-underflow-in-ext4fs_re.patch \
    file://0005-CVE-2019-13106-ext4-fix-out-of-bounds-memset.patch \
    file://0006-ext4-Fix-integer-overflow-in-ext4fs_read_symlink.patch \
"

# The name libubootenv falls back to on a blank environment. Without that file the
# first fw_setenv saves only one variable, and U-Boot then loses bootcmd.
# oelint-adv does not know this oe-core variable (u-boot.inc).
# nooelint: oelint.vars.mispell
UBOOT_INITIAL_ENV = "u-boot-initial-env"

# Written into uboot_env by the wks, so a reflashed card starts from the default
# environment instead of keeping the old card's bootcmd and counters.
UBOOT_INITIAL_ENV_BINARY = "1"
UBOOT_INITIAL_ENV_BINARY_SIZE = "0x8000"

# Fail the build, not the board, if the fragment did not take effect: every line of
# rauc-env.cfg must appear verbatim in the merged .config. Without it the env
# silently reverts to ENV_IS_NOWHERE.
microduck_check_uboot_config() {
	for line in $(grep -vE '^[[:space:]]*(#|$)' ${UNPACKDIR}/rauc-env.cfg); do
		grep -qxF "$line" ${B}/.config || bbfatal "rauc-env.cfg: '$line' is not in the merged ${B}/.config"
	done
	# no-network.cfg is all "is not set" lines, which the loop above skips as comments.
	! grep -q '^CONFIG_NET=y' ${B}/.config || bbfatal "no-network.cfg did not take: CONFIG_NET=y in ${B}/.config"
}
do_configure[postfuncs] += "microduck_check_uboot_config"

# The beta's DRAM init, Seeed's blobs: make.sh's default RK3568 1560 MHz blob
# never gets the board past power-on (docs/agents/beta-board.md). Our ini replaces
# RK3568MINIALL.ini, so make.sh picks them up unchanged.
RKBIN_UPSTREAM = "https://raw.githubusercontent.com/rockchip-linux/rkbin/3e288fe814e059dd06833495f845cab04ac20a5c"
SRC_URI:append:microduck-beta = " \
    ${RKBIN_UPSTREAM}/bin/rk35/rk3566_ddr_1056MHz_v1.26.bin;name=rk3566ddr;subdir=rkbin-beta \
    ${RKBIN_UPSTREAM}/bin/rk35/rk356x_spl_v1.14.bin;name=rk356xspl;subdir=rkbin-beta \
    file://microduck-beta/RK3568MINIALL.ini;subdir=rkbin-beta \
"
SRC_URI[rk3566ddr.sha256sum] = "9966c21aadf00737ccecc2fad6fe3c902ff26956433029f70dfd759d4f60616a"
SRC_URI[rk356xspl.sha256sum] = "add54b882996c06b3c22f4bdc1bc3f1be90edb5a306d6d72a1c348b452997236"

# Seeed's blob is the stock one with trfc_mode=1. Without it some boards are dead
# from power-on and cannot be reflashed from maskrom. Hash of Seeed's settings:
MICRODUCK_BETA_DDR_SHA256 = "00b6e57fee345394541afd83dc9b4f3104ec931729c3f653518a14abbd65b3f4"

microduck_beta_rkbin() {
	ddr=${UNPACKDIR}/rkbin/bin/rk35/rk3566_ddr_1056MHz_v1.26.bin
	install -m 0644 ${UNPACKDIR}/rkbin-beta/rk3566_ddr_1056MHz_v1.26.bin $ddr
	# trfc_mode lives in bits [2:1] of the byte at 0xe10d (57613): 0x00 -> 0x02.
	printf '\002' | dd of=$ddr bs=1 seek=57613 count=1 conv=notrunc status=none
	echo "${MICRODUCK_BETA_DDR_SHA256}  $ddr" | sha256sum -c --quiet - \
		|| bbfatal "rk3566 DDR blob with trfc_mode=1 does not match Seeed's settings"
	install -m 0644 ${UNPACKDIR}/rkbin-beta/rk356x_spl_v1.14.bin ${UNPACKDIR}/rkbin/bin/rk35/
	install -m 0644 ${UNPACKDIR}/rkbin-beta/microduck-beta/RK3568MINIALL.ini ${UNPACKDIR}/rkbin/RKBOOT/RK3568MINIALL.ini
}
# MACHINEOVERRIDES, not MACHINE: microduck-face-board-v1 is the same main board.
# Missing this would pack the stock DDR blob and leave it dead at power-on.
do_configure[prefuncs] += "${@'microduck_beta_rkbin' if 'microduck-beta' in d.getVar('MACHINEOVERRIDES').split(':') else ''}"

# And fail the build, not the board, if the idblock does not carry it.
microduck_check_beta_ddr() {
	if ! grep -aq 'fwver: v1.26' ${B}/idblock.img; then
		bbfatal "beta idblock does not carry the rk3566 DDR v1.26 blob"
	fi
}
do_compile[postfuncs] += "${@'microduck_check_beta_ddr' if 'microduck-beta' in d.getVar('MACHINEOVERRIDES').split(':') else ''}"

# CVEs the scanner matches on "2017.09" but this build cannot reach, each checked
# against the merged .config and the u-boot ELF. Left open: CVE-2018-18440 (its fix
# changes how the kernel loads) and CVE-2019-11690 (only `gpt`-made GUIDs, unused).
CVE_STATUS_GROUPS += "CVE_STATUS_UBOOT_NET CVE_STATUS_UBOOT_FIT_SIG CVE_STATUS_UBOOT_SQUASHFS CVE_STATUS_UBOOT_CMDS CVE_STATUS_UBOOT_ABSENT"
CVE_STATUS_UBOOT_NET = " \
    CVE-2018-18439 CVE-2019-14192 CVE-2019-14193 CVE-2019-14194 CVE-2019-14195 \
    CVE-2019-14196 CVE-2019-14197 CVE-2019-14198 CVE-2019-14199 CVE-2019-14200 \
    CVE-2019-14201 CVE-2019-14202 CVE-2019-14203 CVE-2019-14204 CVE-2022-30767 \
    CVE-2024-42040 CVE-2026-29007 CVE-2026-29008 CVE-2026-29009 CVE-2026-71971 \
    CVE-2026-74220 CVE-2026-74221 CVE-2026-74222 CVE-2026-74225 \
"
CVE_STATUS_UBOOT_NET[status] = "not-applicable-config: the network stack is not built (no-network.cfg); no network function is in the u-boot ELF"
CVE_STATUS_UBOOT_FIT_SIG = "CVE-2018-1000205 CVE-2020-10648 CVE-2021-27097 CVE-2021-27138 CVE-2026-46728"
CVE_STATUS_UBOOT_FIT_SIG[status] = "not-applicable-config: FIT signature verification is off (CONFIG_FIT_SIGNATURE, CONFIG_SPL_FIT_SIGNATURE unset); the boot script loads a raw Image"
CVE_STATUS_UBOOT_SQUASHFS = "CVE-2024-57254 CVE-2024-57255 CVE-2024-57257 CVE-2024-57258 CVE-2024-57259 CVE-2026-71973"
CVE_STATUS_UBOOT_SQUASHFS[status] = "not-applicable-config: this 2017.09 tree has no SquashFS support (no fs/squashfs)"
CVE_STATUS_UBOOT_CMDS = "CVE-2020-8432 CVE-2022-34835 CVE-2022-2347 CVE-2026-71972"
CVE_STATUS_UBOOT_CMDS[status] = "not-applicable-config: the code is not built: gpt rename (CONFIG_CMD_GPT_RENAME), i2c md (CONFIG_CMD_I2C), USB DFU (CONFIG_CMD_DFU), RLE8 bitmaps (no CONFIG_VIDEO_BMP_RLE8 here)"
CVE_STATUS_UBOOT_ABSENT = "CVE-2026-71974"
CVE_STATUS_UBOOT_ABSENT[status] = "not-applicable-config: the code is not in this 2017.09 tree (boot/bootmeth_android.c came years later)"
CVE_STATUS[CVE-2025-24857] = "not-applicable-platform: Qualcomm IPQ SoCs only; this is a Rockchip RK3566"
