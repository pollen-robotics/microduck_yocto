SUMMARY = "AICSemi AIC8800 SDIO wifi/BT driver and firmware"
DESCRIPTION = "Out-of-tree AICSemi aic8800_* kernel modules for the SDIO-attached \
AIC8800 wifi/BT combo fitted to some Radxa Zero 3W boards, plus its firmware. \
Not present in the kernel tree (radxa's or Armbian's) -- the device tree wires up the SDIO bus, \
power sequence and BT UART, but nothing drives it."
HOMEPAGE = "https://github.com/radxa-pkg/aic8800"
# Two licences in one tree, per debian/copyright:
#   Files: src/*   -> GPL-2   (AICSemi's driver: what we compile and ship, and it
#                              carries MODULE_LICENSE("GPL"))
#   Files: *       -> GPL-3+  (radxa's Debian packaging; the top-level LICENSE
#                              file is therefore the GPLv3 text)
# Both are declared so the SPDX SBOM describes the tree we actually fetch, even
# though only the GPL-2 part reaches the robot.
#
# Note debian/copyright's blanket "Files: *" also sweeps in the firmware blobs
# under src/*/driver_fw/fw, which are redistributable binaries rather than
# GPL-anything. That is upstream's claim, not ours to correct here.
LICENSE = "GPL-2.0-only & GPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=1ebbd3e34237af26da5dc08a4e440464 \
                    file://debian/copyright;md5=ccd22839cbff32b2bbe9a6ec05d11739"

inherit module systemd

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Tag 5.0+git20260123.5f7be68d-7. radxa-pkg wraps AICSemi's vendor drop in Debian
# packaging; we reuse their patches and build rules but not dpkg/DKMS.
SRCREV = "6e076049b719ac2ff7ce5c92786a680407b11cdb"
SRC_URI = "git://github.com/radxa-pkg/aic8800.git;protocol=https;nobranch=1 \
           file://aic8800-bt-attach.service \
"

# No `S =` line on purpose. wrynose actively rejects S = "${WORKDIR}/git" and
# S = "${UNPACKDIR}/git" with a do_unpack error: the git fetcher now unpacks to
# ${UNPACKDIR}/${BP}, which is what bitbake.conf's default S already points at.

# The vendor Makefile under driver/aic8800 is a plain kbuild fragment: it has no
# rule of its own that invokes the kernel build, which is why the DKMS config
# supplies `-C $kernel_source_dir M=<driver dir>`. module.bbclass instead assumes
# the module Makefile calls kbuild itself via KERNEL_SRC, so we pass -C and M=
# explicitly through MAKE_TARGETS / MODULES_INSTALL_TARGET.
B = "${S}/src/SDIO/driver_fw/driver/aic8800"
MAKE_TARGETS = "-C ${STAGING_KERNEL_DIR} M=${B} modules"
MODULES_INSTALL_TARGET = "-C ${STAGING_KERNEL_DIR} M=${B} modules_install"
MODULES_MODULE_SYMVERS_LOCATION = "."

# Apply exactly what debian/patches/series lists, in its order. Two patches in
# that directory are deliberately absent from series
# (fix-build-on-low-memory-devices-v2, fix-map-riscv64-subarch), so a `*.patch`
# glob would be wrong.
#
# Two of these are load-bearing for us:
#   fix-linux-6.1-build.patch      -- we are on the 6.1 vendor BSP
#   fix-sdio-firmware-path.patch   -- points the driver at
#                                     /lib/firmware/aic8800_fw/SDIO, which is
#                                     where do_install below puts the blobs
# Attached as a do_patch postfunc rather than `do_patch:append`, because do_patch
# is a *Python* task (patch.bbclass) and appending a shell body to it makes bitbake
# parse shell as Python.
#
# Driven by quilt rather than a hand-rolled loop over series, for a concrete
# reason: a postfunc re-runs whenever do_patch re-runs, and do_patch re-runs after
# a recipe edit *without* re-unpacking. A plain `patch` loop then meets an
# already-patched tree and dies with "Reversed (or previously applied) patch
# detected". quilt records applied state in .pc/, so a re-run is a no-op -- and it
# is the tool debian/patches is written for, so series semantics come for free.
#
# Line endings have to be normalised first. AICSemi's drop mixes CRLF and LF while
# the patches are uniformly LF, so affected hunks can never match -- e.g.
# fix-usb-firmware-path.patch fails with "Hunk #1 FAILED at 144 (different line
# endings)" on aicbluetooth.c. patch's -l/--ignore-whitespace does not rescue this
# one, so convert the text files instead: line endings do not affect C
# compilation, and this kills the whole class rather than one patch at a time.
#
# Restricted to source/makefile extensions on purpose -- sed across the tree would
# corrupt the firmware blobs under driver_fw/fw.
#
# Failures stay fatal deliberately. The whole series is applied, as Debian does,
# even though we only build the SDIO variant -- silently tolerating rejects would
# mean not knowing whether an SDIO-relevant fix landed.
apply_debian_patches() {
	cd ${S}
	find src -type f \( -name '*.c' -o -name '*.h' -o -name 'Makefile*' \
		-o -name '*.mk' -o -name 'Kconfig*' \) \
		-exec sed -i 's/\r$//' {} +

	export QUILT_PATCHES=debian/patches
	rc=0
	quilt --quiltrc /dev/null push -a || rc=$?
	# 0 = applied; 2 = nothing to do (already fully applied). Anything else is real.
	if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
		bbfatal "quilt push -a failed with exit $rc"
	fi
}
do_patch[postfuncs] += "apply_debian_patches"

FW_SUBDIR = "${nonarch_base_libdir}/firmware/aic8800_fw"

do_install:append() {
	install -d ${D}${FW_SUBDIR}/SDIO
	# Mirror Debian's aic8800-firmware.install and ship every chip variant
	# (aic8800, aic8800D80, aic8800D80N, aic8800D80X2, aic8800DC), letting the
	# driver select at runtime. The board is an AIC8800DS2 and none of those
	# directory names map to it obviously, so picking one here would be a guess.
	cp -R ${S}/src/SDIO/driver_fw/fw/* ${D}${FW_SUBDIR}/SDIO/
	# A compressed duplicate of the aic8800D80 directory; no use on target.
	rm -f ${D}${FW_SUBDIR}/SDIO/aic8800D80.7z

	install -d ${D}${bindir}
	install -m 0755 ${S}/src/tools/aicrf_test/bt_test ${D}${bindir}/bt_test

	install -d ${D}${systemd_system_unitdir}
	install -m 0644 ${UNPACKDIR}/aic8800-bt-attach.service \
		${D}${systemd_system_unitdir}/
}

# The BT controller needs an HCI attach, and the exact incantation is not
# obvious -- see the unit for the measurements. Enabled by default because BLE
# provisioning (btd, configd) is the product's way onto a network, and a radio
# that is present but unattached looks identical to a board with no Bluetooth.
SYSTEMD_PACKAGES = "${PN}-bt"
SYSTEMD_SERVICE:${PN}-bt = "aic8800-bt-attach.service"
SYSTEMD_AUTO_ENABLE:${PN}-bt = "enable"

# hciattach and hciconfig come from bluez5; nothing else is needed, since the
# rfkill handling is done through sysfs rather than the rfkill tool.
RDEPENDS:${PN}-bt += "bluez5"

# bt_test: AICSemi's own BT bring-up and diagnostic tool, from the same source
# tree. Debian ships it as the `aicrf-test` package -- debian/aicrf-test.install
# is one line, `src/tools/aicrf_test/bt_test usr/bin/`.
#
# Packaged because the UART path is a dead end and we need the vendor's own view
# of why. Measured on the board 2026-09-11: btattach on /dev/ttyS1 reaches
# TX 4 bytes / RX 0 with HCI_Reset timing out (-110), identically across
# 1500000 and 115200 baud with and without flow control. The driver cannot help
# -- aic8800_btlpm's aic_bluetooth_main.c registers a platform driver and rfkill
# and nothing else, no chrdev and no HCI transport, so an HCI attach really is
# the only path it offers. And BT power is inert while wifi holds the shared
# chip: aicbsp_set_subsys answers "power state no need to change, current: 1"
# to both block and unblock.
#
# bt_test knows the three transports the vendor supports --
# `-s uart <baud> <dev>`, `-s usb`, `-s wlan wlan0` -- and talks to
# /dev/aicbt_dev, which does not exist here. That `-s wlan` mode is the
# interesting one: it implies HCI over SDIO rather than the UART, which would
# explain everything measured so far. This tool can answer which transport the
# controller actually replies on, instead of us guessing at baud rates.
#
# Compiled by hand rather than via its Makefile: that Makefile hardcodes gcc,
# offers no hook but CROSS_COMPILE, and also builds wifi_test, which we do not
# ship.
do_compile:append() {
	${CC} ${CFLAGS} ${LDFLAGS} -o ${S}/src/tools/aicrf_test/bt_test \
		${S}/src/tools/aicrf_test/bt_test.c -lpthread
}

PACKAGES =+ "${PN}-firmware ${PN}-bt ${PN}-bt-test"
FILES:${PN}-firmware = "${FW_SUBDIR}"
FILES:${PN}-bt = "${systemd_system_unitdir}/aic8800-bt-attach.service"
FILES:${PN}-bt-test = "${bindir}/bt_test"

# The modules are useless without the blobs, and the SDIO device probes at boot.
RDEPENDS:${PN} += "${PN}-firmware"
KERNEL_MODULE_AUTOLOAD += "aic8800_bsp aic8800_fdrv aic8800_btlpm"

# aic8800_btlpm only handles BT low-power signalling. Bringing the controller up
# still needs an HCI attach on the UART the device tree's wireless-bluetooth node
# describes (btattach/hciattach) -- that is runtime work, not packaging.
