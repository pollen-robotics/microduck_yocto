# The kernel (`linux-rockchip_6.1.bbappend`)

Why each part of the kernel append is there.

## The tree

Armbian's `linux-rockchip` `rk-6.1-rkr7.2`: Rockchip's rkr7.2 BSP kept merged
with 6.1 stable (6.1.172 at the pin), instead of radxa's
`linux-6.1-stan-rkr4.1` (6.1.84). Two reasons:

- CVE fixes: radxa's branch stopped at 6.1.84 (early 2024).
- rkaiq rkr7, the beta's 3A engine, needs a kernel newer than 6.1.115; older
  ones abort at init with "failed to get cac buf info".

It is fetched shallow (`kas/microduck.yml`, kernel-shallow): bitbake asks
GitHub for the SRCREV at depth 1, so the pin keeps working after Armbian pushes.

What stays radxa's, because it describes the Zero 3W and has run on it:

- `0000-*.patch`: radxa's `rk3566-radxa-zero-3w-aic8800ds2.dts` and
  `rk3566-radxa-zero3.dtsi` (270a678f8364). Armbian's own Zero 3 dtsi differs in
  ~300 lines (no `rk3568-linux.dtsi`, pmuio2 at 3.3 V), and 0001-0003 are cut
  against radxa's file.
- `radxa-rockchip-linux.kconfig`: radxa's `rockchip_linux_defconfig` from the
  same commit. Rockchip's rkr7.2 one differs in 726 lines; options new since
  6.1.84 take their Kconfig default.

## The defconfig

The kconfig file is installed as `microduck_defconfig` before
`do_kernel_metadata` reads it. meta-rockchip's own mechanism cannot take a file
from us: it builds a defconfig only if `KBUILD_DEFCONFIG` is missing from the
tree, and then writes an *empty* one (`$CONFIGS` is a typo, and
`KBUILD_DEFCONFIGS` is not exported). Two HF builds failed on that (2026-10-22).
AGENTS.md has the longer story.

The file name avoids "defconfig": kernel-yocto's `find_sccs` takes any such
SRC_URI file as a second defconfig and drops it with a warning.

Never trust the effective config from the defconfig name: read `${B}/.config`
after `do_configure`. `mali-csf.cfg` exists because a SoC override everyone
assumed was applied never was. `microduck_check_kernel_fragments` fails the
build when a line of a `microduck-*.cfg` fragment did not survive merge_config
(a missing dependency drops it silently: a face board with no LEDs), and when
one of its `# ... is not set` lines came back on through another option's `select`.

## The trim

Radxa's defconfig builds in drivers for every board radxa sells. The
`microduck-trim-*.cfg` fragments turn off, one area each, what no microduck has:
debug and test options, foreign and network filesystems, touchscreens and USB
serial chips, Ethernet/CAN/modems, PCIe/SATA/NVMe/UFS/MTD storage, and KVM.
`-display` and `-media` (other sensors, audio codecs, all of the display side)
go on the beta family only: the Zero 3W has HDMI and an IMX219.

Kept on purpose: `CONFIG_DRM` (the NPU is a DRM GEM device, `/dev/dri/card0` is
RKNPU), `CONFIG_PCI` (the QEMU test boots on virtio-pci), and the CP210x, FTDI,
CH341 and PL2303 USB serial drivers (Dynamixel and debug dongles).

**Turning an option off also turns off what it alone selected.** Radxa's
defconfig is a minimal one, and kernel-yocto merges it with the fragments in one
`alldefconfig` pass, so anything that was on only through a `select` goes with its
selector. `CONFIG_USB` itself is not in the defconfig: it was on through the USB
touchscreen's select, and the first trim build failed in `wq_wlan`'s modpost
(`usb_alloc_urb` undefined). `microduck-trim-keep.cfg` restores each such option
that matters, and says which selector it lost. Out-of-tree modules (`wq_wlan`,
`aic8800`) cannot select anything, so what they link against must be on by name.

To try a fragment in seconds rather than in an hour's build: unpack the kernel's
`gitshallow_*linux-rockchip*` tarball from `downloads/`, then run
`scripts/kconfig/merge_config.sh` (no `-m`) over the defconfig file and the
fragments in SRC_URI order, with `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`.
That is kernel-yocto's own pass, and gives the board's `/proc/config.gz` apart
from the toolchain lines. Do not `make microduck_defconfig` first: the expanded
`.config` records every selected option by name and hides exactly the losses above.
Then compare the `=y`/`=m` sets before and after the trim, and build
`wq_wlan` against the result (`make M=<rwnx_drv> modules`).

No module is installed apart from the image's short list
(`microduck-image.bb`), so an option left at `=m` costs build time, not image size.

## No auto-patches

meta-rockchip points `PATCHPATH` at its own `linux-rockchip_6.1/` patches (a
do_mounts retry and two drm cursor/plane hacks), cut against JeffyCN's tree.
None are needed, and a failed apply is fatal, so `PATCHPATH` names a directory
that does not exist. auto-patch also adds *absolute* `file://` URLs, which put
the layer's checkout path into the kernel's task signatures. `:=` because
`THISDIR` is a parse-time variable.

## CVE backports

Known-exploited (CISA KEV) and likeliest-exploited (FIRST EPSS) kernel CVEs the
scan found open, each one 6.1 stable commit as is, plus `CVE:` (what makes the
scan count it patched) and `Upstream-Status: Backport`:

| patch | CVE | list | file | stable |
|---|---|---|---|---|
| 0010 | CVE-2026-46300 | KEV | net/core/skbuff.c | 6.1.174 |
| 0011 | CVE-2026-53266 | KEV | net/bridge/netfilter/ebt_snat | 6.1.176 |
| 0012 | CVE-2026-53362 | KEV | net/ipv6/ip6_output.c | 6.1.177 |
| 0013 | CVE-2026-43499 | EPSS | kernel/locking/rtmutex.c | 6.1.175 |
| 0014 | CVE-2025-21759 | EPSS | net/ipv6/mcast.c | 6.1.189 |

When the SRCREV reaches a stable release that carries one, drop its patch: it
will no longer apply.

## boot.img: the DTB only

U-Boot loads the kernel from the slot, but sets *itself* up from the board DTB
in `boot` (`resource.img`). Without it, it falls back to a generic tree that
cannot read the OTP: no serial number, so every robot's USB gadget has the same
MACs (beta, 2026-11-10). A kernel in `boot` would only be a fallback that does
not match the slot's modules, so `boot.img` and `zboot.img` (which meta-rockchip
deploys as `boot.img`) are rebuilt with an empty kernel.

It must be reproducible: microduck-bundle refuses a bundle whose `boot.img`
differs from the card's. `no-mali400.cfg` exists for that too: the Mali-400
driver baked `date` into the Image.

The slot's DTB is also installed as `/boot/microduck.dtb`, one name for every
machine, so one bootcmd serves every board.

## Board patches

- **Motor bus, two halves.** `motorbus.cfg` turns `CONFIG_FIQ_DEBUGGER` off
  (frees the driver); `0002` enables `&uart2` and disables the `fiq_debugger`
  node (frees the hardware). With the fragment alone the board had neither
  `ttyFIQ0` nor `ttyS2` (2026-09-11). Both only with
  `MICRODUCK_MOTOR_UART = "1"`, or the console mode loses its console.
- **Zero 3W camera (`0003`).** The sensor and ISP drivers were already `=y`; the
  DTS was the whole gap (no `/dev/video*`, nothing in dmesg). It applies with or
  without `0002`; both orders are checked. `0001` still patches the Zero 3W DTS
  on a beta build, harmlessly.
- **Our own board DTS** (`MICRODUCK_BOARD_DTS`): a file, not a patch, because a
  board in bring-up is edited constantly and a `.dts` diffs better. Copied into
  the tree and added to the rockchip dts Makefile, so `KERNEL_DEVICETREE` and
  meta-rockchip's per-DTB `boot.img` pick it up. A list, because a variant's
  DTS includes another (face-board-v1 includes the beta's).
- **Face board V1.0 LEDs.** The AW2023 driver is Seeed's (is-qian/rockchip-kernel
  813bdd4), made to build on 6.1. The AW21009 one is ours: one LED per channel,
  so each keeps a `face:*` name (Seeed's port exposes one LED and vendor sysfs
  files). Only on that machine, so other boards' kernels stay byte-identical.
