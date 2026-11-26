# runqemu for a board's own image: every build writes a qemuboot.conf beside its
# .wic, so CI and developers boot the very image that ships, on QEMU's virt board.

IMAGE_CLASSES += "qemuboot"

QB_SYSTEM_NAME = "qemu-system-aarch64"
# oelint-adv does not know this oe-core variable (qemuboot.bbclass).
# nooelint: oelint.vars.mispell
QB_MACHINE = "-machine virt"
QB_CPU = "-cpu cortex-a55"
QB_SMP = "-smp 4"
QB_MEM = "-m 2048"
QB_GRAPHICS = "-display none"
QB_SERIAL_OPT = "-serial mon:stdio"
# The whole board disk (rootfs_a, rootfs_b, data); the kernel comes from the deploy dir.
QB_DEFAULT_FSTYPE = "wic.zst"
QB_FSINFO = "wic:no-kernel-in-fs"
QB_DRIVE_TYPE = "/dev/vd"
# The class default reaches qemuboot.conf unexpanded, as a ${@...} string.
QB_DEFAULT_KERNEL = "${KERNEL_IMAGETYPE}"
QB_KERNEL_ROOT = "PARTLABEL=rootfs_a ro"
# rockchip_drm_init oopses on virt: it calls Rockchip's TF-A, which QEMU lacks.
QB_KERNEL_CMDLINE_APPEND = "console=ttyAMA0 initcall_blacklist=rockchip_drm_init"
# The shipping image's ssh listens on usb0 only, which QEMU lacks: open it on every interface.
QB_KERNEL_CMDLINE_APPEND += "systemd.wants=microduck-ssh-wifi.service"
