#!/usr/bin/env python3
"""Check meta-microduck-bsp/files/wic/microduck-ab.wks.in for overlapping partitions.

wic catches an overlap too, but only ~50 minutes into a build. The A/B layout is
the one place where a silently shifted offset is not a cosmetic bug: a bundle
built against one layout would write over the wrong partition of another.

    python3 scripts/check-wks-layout.py

Artifact sizes below are measured, not assumed -- from the deploy directory of
the image running on the board. Re-measure and update when an artifact grows;
that is the whole point of the reservation being explicit.
"""
import re
import sys
from pathlib import Path

WKS = Path(__file__).resolve().parent.parent / "meta-microduck-bsp/files/wic/microduck-ab.wks.in"

# name -> measured bytes of the artifact that must fit (2026-09-17).
#
# Keyed by the wks --part-name, so this list moves whenever a partition is
# renamed. The kernel is not here: it lives in each rootfs slot's /boot.
ARTIFACTS = {
    "idblock": 313344,     # idblock.img
    "uboot": 4 << 20,      # uboot.img, exactly 4 MiB
    "boot": 206848,        # boot.img: header + resource with the DTB U-Boot reads, no kernel (2026-11-10)
}

UNITS = {"s": 512, "S": 512, "K": 1024, "k": 1024, "M": 1 << 20, "G": 1 << 30}

LAYER = WKS.parent.parent.parent
ENV_CFG = LAYER / "recipes-bsp/u-boot/files/rauc-env.cfg"
FW_ENV = LAYER / "recipes-bsp/u-boot/files/fw_env.config"
BOOTCMD_PATCH = LAYER / "recipes-bsp/u-boot/files/0001-evb_rk3568-select-the-RAUC-slot-before-Rockchip-s-boot.patch"

# Byte offsets that vendor code writes to WITHOUT reading the partition table, so
# the partition carrying that name has to start exactly there. Not wic-checkable:
# wic only knows about overlaps between its own partitions.
#
# uboot_env is filled in from rauc-env.cfg at runtime, so the wks, the U-Boot
# config and fw_env.config are checked against each other rather than each
# against a number copied into this file. That triple used to be held together by
# comments saying "these must agree".
FIXED = {
    "v_storage": 7168 * 512,  # EMMC_VENDOR_PART_OFFSET, arch/arm/mach-rockchip/vendor.c:30
    "uboot": 16384 * 512,     # the loader's default U-Boot position, 8 MiB
}


def kconfig(path, key):
    """Value of `key=...` in a Kconfig fragment, or None."""
    for line in path.read_text().splitlines():
        if line.startswith(key + "="):
            return int(line.split("=", 1)[1], 0)
    return None


def to_bytes(text, default_unit):
    """wic's sizetype(): a bare number takes the argument's default unit."""
    if text[-1] in UNITS:
        return int(text[:-1]) * UNITS[text[-1]]
    return int(text) * UNITS[default_unit]


def main():
    parts, errors, guids = [], [], {}
    for line in WKS.read_text().splitlines():
        line = line.strip()
        if line.endswith("\\"):
            # wic reads the .wks one line at a time and shlex.splits it; there is
            # no continuation handling, so a wrapped `part` line is a syntax error
            # that only shows up at do_image_wic.
            errors.append(f"line continuation, which wic does not support: {line}")
            continue
        # meta-rockchip's do_fixup_wks greps every line for "[^=]*\.img" and deletes
        # the lines holding "file=<word>" for each word of a match that is not a
        # deployed file. In a comment, "every boot ... boot.img" deleted the boot
        # partition line (2026-11-10).
        if line.startswith("#") and ".img" in line:
            errors.append(f"a comment naming an image file; do_fixup_wks would act on it: {line}")
            continue
        if not line.startswith("part"):
            continue
        name = re.search(r"--part-name (\S+)", line)
        if name:
            name = name.group(1)
        elif "--no-table" in line:
            name = "idblock"  # no GPT entry, so no --part-name to read
        else:
            errors.append(f"unnamed partition with a table entry: {line}")
            continue

        size = re.search(r"--fixed-size (\S+)", line)
        if not size:
            errors.append(f"{name}: no --fixed-size; its size would follow its source")
            continue
        size = to_bytes(size.group(1), "M")

        offset = re.search(r"--offset (\S+)", line)
        align = re.search(r"--align (\S+)", line)
        if offset:
            start = to_bytes(offset.group(1), "K")
        elif align:
            start = to_bytes(align.group(1), "K")  # first partition: aligned == placed
        else:
            errors.append(f"{name}: neither --offset nor --align; placement is implicit")
            continue
        parts.append((name, start, size))
        guid = re.search(r"--uuid (\S+)", line)
        if guid:
            guids[name] = guid.group(1).lower()

    for name, start, size in parts:
        fits = ARTIFACTS.get(name)
        if fits is not None and fits > size:
            errors.append(f"{name}: artifact {fits} B does not fit reserved {size} B")

    # The environment: one region, reached three ways. U-Boot writes the raw byte
    # offset CONFIG_ENV_OFFSET on the whole device (env_blk.c never reads the
    # GPT); fw_setenv opens the uboot_env partition and writes at the offset in
    # fw_env.config. Both must land on the same bytes, and all three sizes agree.
    byname = {n: (s, z) for n, s, z in parts}
    env_off = kconfig(ENV_CFG, "CONFIG_ENV_OFFSET")
    env_size = kconfig(ENV_CFG, "CONFIG_ENV_SIZE")
    if env_off is None or env_size is None:
        errors.append(f"{ENV_CFG.name}: CONFIG_ENV_OFFSET/CONFIG_ENV_SIZE not found")
    else:
        FIXED["uboot_env"] = env_off
        fw = [l.split() for l in FW_ENV.read_text().splitlines()
              if l.strip() and not l.lstrip().startswith("#")]
        if len(fw) != 1 or fw[0][0] != "/dev/disk/by-partlabel/uboot_env":
            errors.append(f"{FW_ENV.name}: expected one line on by-partlabel/uboot_env, got {fw}")
        else:
            fw_off, fw_size = int(fw[0][1], 0), int(fw[0][2], 0)
            if fw_off != 0:
                errors.append(f"{FW_ENV.name}: offset {fw_off:#x} within the partition, "
                              "but U-Boot writes at the partition's start")
            if fw_size != env_size:
                errors.append(f"{FW_ENV.name}: size {fw_size:#x} != CONFIG_ENV_SIZE {env_size:#x}")
        if "uboot_env" in byname and byname["uboot_env"][1] != env_size:
            errors.append(f"uboot_env is {byname['uboot_env'][1]:#x} B, "
                          f"CONFIG_ENV_SIZE is {env_size:#x}")

    # U-Boot's boot script finds each slot's partition by its GPT partition GUID
    # (`part uuid`; this tree has no `part number`), so the GUIDs here and in the
    # script must match, and be literal: a ${VAR} is expanded by bitbake, where this
    # check cannot follow it.
    patch = BOOTCMD_PATCH.read_text()
    for name, macro in (("rootfs_a", "MICRODUCK_ROOTFS_A_GUID"), ("rootfs_b", "MICRODUCK_ROOTFS_B_GUID")):
        m = re.search(r'#define ' + macro + r' "([0-9a-fA-F-]{36})"', patch)
        if not m:
            errors.append(f"{BOOTCMD_PATCH.name}: no {macro}")
        elif name not in guids:
            errors.append(f"{name}: no literal --uuid in the wks, but the boot script finds it by GUID")
        elif guids[name] != m.group(1).lower():
            errors.append(f"{name} has GUID {guids[name]} in the wks, but the boot script "
                          f"looks for {m.group(1)}")
    names = [n for n, _, _ in parts]
    # Vendor U-Boot reads its own DTB from the partition named exactly `boot` at init:
    # without it a fresh flash has no serial-number and a random Wi-Fi MAC.
    if "boot" not in names:
        errors.append("boot: missing -- vendor U-Boot reads its own DTB from it at init")
    # microduck-data-grow grows data to the end of the disk only if it is the last one.
    if names and names[-1] != "data":
        errors.append(f"data must be the last partition (microduck-data-grow), not {names[-1]}")

    for name, want in FIXED.items():
        if name not in byname:
            errors.append(f"{name}: missing -- vendor code writes at {want:#x} regardless")
        elif byname[name][0] != want:
            errors.append(f"{name} starts at {byname[name][0]:#x}, must be {want:#x}: "
                          "vendor code writes there without reading the GPT")

    for (an, astart, asize), (bn, bstart, _) in zip(parts, parts[1:]):
        if astart + asize > bstart:
            errors.append(
                f"{an} ends at {astart + asize} B, past the start of {bn} at {bstart} B"
            )
        if bstart < astart:
            errors.append(f"{bn} at {bstart} B is before {an} at {astart} B")

    for name, start, size in parts:
        head = ARTIFACTS.get(name)
        used = f"  ({head} B used)" if head else ""
        print(f"{name:10s} {start:>12,} .. {start + size:>12,} B  ({size >> 20} MiB){used}")
    total = parts[-1][1] + parts[-1][2]
    print(f"total {total:,} B = {total / (1 << 30):.2f} GiB")

    if errors:
        print("\n".join("ERROR: " + e for e in errors), file=sys.stderr)
        return 1
    print("layout ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
