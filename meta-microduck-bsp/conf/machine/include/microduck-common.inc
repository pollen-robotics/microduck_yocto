# Shared by every microduck machine.

# "1" gives UART2 to robotd's motor bus: no serial console, no FIQ debugger, so
# it enumerates as /dev/ttyS2. A getty reads servo replies and printk corrupts
# them, so they cannot share it (AGENTS.md). On the Zero 3W, console=tty0 covers
# a kernel that dies; never "fix" its dead console=ttyFIQ0 to ttyS2.
MICRODUCK_MOTOR_UART ?= "1"

# Scopes this layer's appends to recipes other machines build too:
# yocto-check-layer fails a BSP layer that changes other machines' signatures.
# Not `microduck` (the distro's) nor `microduck-board` (a package name).
MACHINEOVERRIDES =. "microduck-machine:"

# robotd.toml's [board] version ("zero3", "beta", "face-board-v1"), set per
# machine. The FALLBACK is declared instead when the seeded daemon predates the name.
MICRODUCK_BOARD ?= ""
MICRODUCK_BOARD_FALLBACK ?= ""

# The radio's Bluetooth attach (shipping) and diagnostics (dev). The Zero 3W's
# AIC8800 by default; the driver comes through RK_WIFIBT_RRECOMMENDS.
MICRODUCK_RADIO_PACKAGES ?= "aic8800-bt"
MICRODUCK_RADIO_DEV_PACKAGES ?= "aic8800-bt-test"

SERIAL_CONSOLES = "${@'' if d.getVar('MICRODUCK_MOTOR_UART') == '1' else '1500000;ttyFIQ0'}"

# No rtc: no battery. No alsa: alsa-state's restore would race microduck-beta-audio.
MACHINE_FEATURES = "wifi bluetooth usbhost"
MACHINE_FEATURES_OPTED_OUT = "rtc"

# Pinned, not rockchip-common.inc's ?= defaults: our appends are written
# against exactly these, and meta-rockchip has a 6.12 kernel too.
PREFERRED_PROVIDER_virtual/kernel = "linux-rockchip"
PREFERRED_VERSION_linux-rockchip = "6.1%"
PREFERRED_VERSION_linux-libc-headers = "6.1-custom%"
PREFERRED_PROVIDER_virtual/bootloader = "u-boot-rockchip"

# U-Boot loads Image and the DTB from the slot, so only those ship in the
# rootfs; the default would pull every KERNEL_IMAGETYPES (two 16 MiB copies).
RRECOMMENDS:${KERNEL_PACKAGE_NAME}-base = "${KERNEL_PACKAGE_NAME}-image-image ${KERNEL_PACKAGE_NAME}-devicetree"
