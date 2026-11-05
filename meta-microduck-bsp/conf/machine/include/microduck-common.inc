# Shared by every microduck machine: the Radxa Zero 3W stand-in
# (microduck-zero3) and the beta board, the custom PCB's first spin
# (microduck-beta).

# On the Zero 3W, UART2 is both the RK3566 debug console -- exposed as ttyFIQ0
# by the vendor BSP's FIQ debugger -- and the wire robotd drives 15 Dynamixel
# XL330 servos plus the imu_to_dxl board (ID 200) on at 1 Mbaud. The beta board
# moved the motors to UART3 and sets this to "0": there UART2 is only the
# console, and the motor UART is still /dev/ttyS2 by a DT alias swap.
#
# They cannot share it. A getty does not merely hold the port open, it *reads*
# it, consuming the servo replies before robotd sees them, and kernel printk
# mid-transaction corrupts a reply. microduck_daemon's scripts/setup-board.sh
# records this costing an afternoon of debugging a correctly wired robot.
#
# MICRODUCK_MOTOR_UART = "1" hands UART2 to robotd:
#   - drops the serial console (debug moves to HDMI console + SSH)
#   - disables CONFIG_FIQ_DEBUGGER, so the port enumerates as /dev/ttyS2
#     (see recipes-kernel/linux/files/motorbus.cfg)
#
# Was "0" for bring-up, on the reasoning that you want serial the next time it
# won't boot. Flipped 2026-09-10, once the board booted from SD and answered on
# ssh: no USB-UART adapter was ever attached, so the serial console UART2 was
# being held for could not be read anyway, while robotd sat in a retry loop
# ("cannot open the bus ... /dev/ttyS2: No such file or directory", attempt=330).
# The no-boot path is still covered: the dts patch in recipes-kernel/linux/files
# puts console=tty0 in bootargs, so a kernel that dies prints to HDMI. That patch
# also still names console=ttyFIQ0, which simply fails to register once the FIQ
# debugger is gone -- harmless. Do NOT "fix" it to console=ttyS2, which would put
# printk back on the servo wires, the exact failure this flag exists to prevent.
MICRODUCK_MOTOR_UART ?= "1"

# One override for every microduck machine, so this layer's appends to recipes
# that other machines build too (bluez5, rockchip-mpp, gstreamer1.0-rockchip)
# apply to ours only: yocto-check-layer's test_signatures fails a BSP layer
# whose mere presence changes other machines' recipes. Not `microduck` (the
# distro's override) and not `microduck-board` (a package name, so
# `FILES:microduck-board` would be ambiguous).
MACHINEOVERRIDES =. "microduck-machine:"

# Which electronic board this is, in microduck_daemon's terms ([board] version in
# robotd.toml: "zero3", "beta" or "face-board-v1"). microduck-board writes it into
# the image; the updater derives the hardware revision a release is checked against
# from it. Each machine conf sets its own. MICRODUCK_BOARD_FALLBACK is what to
# declare instead when the seeded daemon predates MICRODUCK_BOARD's name.
MICRODUCK_BOARD ?= ""
MICRODUCK_BOARD_FALLBACK ?= ""

# The radio's userspace, per machine: what microduck-image installs for the
# Bluetooth attach, and what microduck-image-dev adds for diagnosing it. The
# driver and firmware themselves come through RK_WIFIBT_RRECOMMENDS. Defaults
# are the Zero 3W's AIC8800; a machine with another radio overrides both.
MICRODUCK_RADIO_PACKAGES ?= "aic8800-bt"
MICRODUCK_RADIO_DEV_PACKAGES ?= "aic8800-bt-test"

SERIAL_CONSOLES = "${@'' if d.getVar('MICRODUCK_MOTOR_UART') == '1' else '1500000;ttyFIQ0'}"

# Via packagegroup-base: wifi -> iw, wpa-supplicant, wireless-regdb-static;
# bluetooth -> bluez5; usbhost -> usbutils. rtc opted out: no RTC on the boards.
# Not alsa: its alsa-state restore would race microduck-beta-audio's codec setup.
MACHINE_FEATURES = "wifi bluetooth usbhost"
MACHINE_FEATURES_OPTED_OUT = "rtc"

# Our boot chain, as our own choice rather than rockchip-common.inc's ?= defaults:
# linux-rockchip_6.1.bbappend and u-boot-rockchip.bbappend are written against
# exactly these. meta-rockchip added linux-rockchip_6.12 in 2026-09.
PREFERRED_PROVIDER_virtual/kernel = "linux-rockchip"
PREFERRED_VERSION_linux-rockchip = "6.1%"
PREFERRED_VERSION_linux-libc-headers = "6.1-custom%"
PREFERRED_PROVIDER_virtual/bootloader = "u-boot-rockchip"

# The kernel lives in each rootfs slot: U-Boot loads /boot/Image and
# /boot/microduck.dtb from the slot it picked (recipes-bsp/u-boot/files/0001-...),
# so a RAUC bundle carries its own kernel and an update can change it. Only Image
# and the DTB, not boot.img and zboot.img (two 16 MiB copies nothing here reads).
# oe-core's kernel.bbclass leaves this RRECOMMENDS for machines to set; the
# default would pull every KERNEL_IMAGETYPES.
RRECOMMENDS:${KERNEL_PACKAGE_NAME}-base = "${KERNEL_PACKAGE_NAME}-image-image ${KERNEL_PACKAGE_NAME}-devicetree"
