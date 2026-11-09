# Flashing a microduck in the factory

How to write the microduck OS onto a robot's eMMC for the first time, from a
Linux PC or a Mac. The procedure is for the microduck main board with the **V1.0 face
board** (machine `microduck-face-board-v1`). After this first flash the robot
updates itself over the network, so this is done once per robot.

## Quick reference

[`scripts/flash-emmc.sh`](#with-the-script) does everything below. Put the
robot in flashing mode (hold Recovery while powering it on), then:

Flash the latest release (the shipping image):

```sh
scripts/flash-emmc.sh release microduck-face-board-v1
```

Flash the latest dev build of `main` (the dev image, with root login and debug
tools):

```sh
scripts/flash-emmc.sh dev microduck-face-board-v1
```

For the beta board, use `microduck-beta` in place of `microduck-face-board-v1`.
Each run shows the build it picked and asks before writing.

| To | Run |
|---|---|
| See which build would be flashed, without writing | `scripts/flash-emmc.sh latest dev microduck-beta` |
| Flash a given release | `scripts/flash-emmc.sh microduck-os-v1.0.1 microduck-beta` |
| Flash without the confirmation question | `FLASH_EMMC_YES=1 scripts/flash-emmc.sh release microduck-beta` |
| Rewrite only the bootloader of a board stuck in maskrom | `scripts/flash-emmc.sh recover dev microduck-beta` |
| Back up a whole eMMC (about an hour) | `scripts/flash-emmc.sh dump backup.img microduck-beta` |
| Free the disk space the downloads take (asks first) | `scripts/flash-emmc.sh clean` |
| All options | `scripts/flash-emmc.sh --help` |

`dev` and `recover` read the build cache bucket, so they need the Hugging Face
CLI (`hf`), logged in. Power-cycle the robot after a flash; do not use
`rkdeveloptool rd`.

## What you need

- A Linux PC (Debian or Ubuntu) with:
  ```sh
  sudo apt install rkdeveloptool zstd
  ```
  or a Mac: see [On a Mac](#on-a-mac).
- A USB-C **data** cable. A charge-only cable shows nothing in `lsusb`.
- The robot's battery, or a bench supply on the battery input. USB-C alone
  does not start the board.
- Access to the main board's **Recovery button**: it is not reachable from
  outside the case, so flash before closing it.

## Once per release: get and prepare the files

Releases are at <https://github.com/pollen-robotics/microduck_yocto/releases>.
From the release you are told to flash, download these three files (the date
in the image name changes with each release):

- `microduck-face-board-v1-loader.bin`
- `microduck-image-microduck-face-board-v1.rootfs-<date>.wic.zst`
- `microduck-image-microduck-face-board-v1.rootfs-<date>.wic.zst.sha256sum`

With the GitHub CLI, for release `v1.0.1`:

```sh
gh release download microduck-os-v1.0.1 -R pollen-robotics/microduck_yocto \
  -p 'microduck-face-board-v1-loader.bin' \
  -p 'microduck-image-microduck-face-board-v1.*.wic.zst*'
```

Check the download and decompress it once:

```sh
sha256sum -c microduck-image-microduck-face-board-v1.rootfs-*.wic.zst.sha256sum   # must say OK
zstd -d microduck-image-microduck-face-board-v1.rootfs-*.wic.zst
```

This gives a `.wic` of about 12 GiB. That file is what gets written to every
robot.

**Use the face-board-v1 files only.** The release also carries `microduck-beta`
and `microduck-zero3` files. They are for other boards, and on this board the
face LEDs will not work.

## For each robot

1. **Connect** the robot's USB-C to the PC, with the robot powered off.
2. **Enter flashing mode.** Hold the **Recovery button** (next to the USB-C),
   power the robot on, and release the button after 2 seconds. Then:
   ```sh
   sudo rkdeveloptool ld
   ```
   should list one device, `Maskrom` or `Loader`. A board with an empty eMMC
   is in `Maskrom` without the button.
3. **Maskrom only: start the loader.**
   ```sh
   sudo rkdeveloptool db microduck-face-board-v1-loader.bin
   ```
   Skip this step if `ld` said `Loader`.
4. **Check the board answers**, before writing anything:
   ```sh
   sudo rkdeveloptool rfi
   ```
   It prints the eMMC's information, including its size. If it fails, see
   "Troubleshooting".
5. **Write the image.** This takes several minutes: the whole 12 GiB goes over
   USB 2, empty space included.
   ```sh
   sudo rkdeveloptool wl 0 microduck-image-microduck-face-board-v1.rootfs-*.wic
   ```
   Wait for `Write LBA from file (100%)`.
6. **Power-cycle**: switch the power off, then on. **Do not use
   `rkdeveloptool rd`** (reset): after a reset the board often hangs at boot
   until its power is removed. A real power-off does not have this problem.

## On a Mac

The procedure is the same. What differs:

- **Install** with [Homebrew](https://brew.sh):
  ```sh
  brew install gh zstd pierre-rouanet/tools/rkdeveloptool
  ```
- **No `sudo`** in front of `rkdeveloptool`.
- **Click Allow** when macOS asks whether to let the accessory connect. It asks
  when the robot enters flashing mode, and again after `db`, because the
  loader comes back as a new USB device. Until you click, `ld` lists nothing.
- **Checksum**: `shasum -a 256 -c` instead of `sha256sum -c`.
- **Serial console**: `/dev/cu.usbmodem*` instead of `/dev/ttyACM0`, for
  example `screen /dev/cu.usbmodem* 115200`.
- **Network**: the robot shows up in System Settings > Network as a new
  interface and gets its address on its own; `ssh microduck@192.168.42.1`
  works the same.

### With the script

`scripts/flash-emmc.sh` does the whole procedure above, on a Mac or on Linux:
it downloads the release once, checks the checksum and the loader's DRAM
init, decompresses the image, waits for the robot, runs `db` if it is in
Maskrom, then `rfi` and `wl`.

```sh
scripts/flash-emmc.sh microduck-os-v1.0.1
```

Without a tag it takes the latest release. Before downloading anything it
shows the release and image it is about to write and asks for confirmation
(`FLASH_EMMC_YES=1` skips the question). The files stay in
`~/.cache/microduck-flash/<tag>` (set `FLASH_DIR` for another place), so for
the next robot just run it again and put the robot in flashing mode. Power-cycling at the end is still up to you.

It flashes the face board V1.0 unless told otherwise; for the beta board, name
the board after the release (or after `release`, for the latest one):

```sh
scripts/flash-emmc.sh release microduck-beta
```

For development, `dev` instead of a tag flashes the dev image of `main`'s
newest CI build, from the build cache bucket (needs the Hugging Face CLI,
logged in). `scripts/flash-emmc.sh latest dev microduck-beta` prints which
build that is without writing anything, and `scripts/flash-emmc.sh --help`
lists the rest: `recover` for a board stuck in maskrom, `dump` to back up a
whole eMMC.

## Check the robot booted

About 30 seconds after power-on:

- **Face LED**: the status LED is green (double-blinking while the robot
  starts, then blinking or solid), and the fan is off or slow. *LED off and
  fan at full speed* means it did not boot: power-cycle it once more.
- **Over the same USB-C cable**: the robot appears as a network link, with the
  robot at `192.168.42.1`. The PC gets an address automatically (on some
  desktops you have to enable the new wired connection).
  ```sh
  ssh microduck@192.168.42.1        # password: microduck
  cat /etc/os-release               # the release you flashed
  robotctl health
  ```
  There is also a serial console on the same cable, `/dev/ttyACM0` on the PC,
  with the same login. The shipping image answers ssh only on this cable; the
  dev image also does over wifi.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ld` lists nothing | Charge-only cable, robot not powered (USB-C alone is not enough), or the button was released too early. Try again from step 2. |
| `ld` lists nothing and the Recovery button does nothing | Short test point **TP64 (eMMC_D0) to TP4 (GND)** while powering on: this forces Maskrom. |
| `db` succeeds but `rfi` fails | The DRAM did not start. Power-cycle and retry once; if it persists, set the board aside: [`agents/beta-board.md`](agents/beta-board.md), "A board stuck in maskrom", has the recovery. |
| `wl` stops part way | Cable or USB port. Start again from step 2; the write can be repeated as often as needed. |
| LED off, fan at full speed after flashing | Boot hang. Power-cycle (power off, then on). |
