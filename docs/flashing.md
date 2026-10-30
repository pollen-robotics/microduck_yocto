# Flashing a microduck in the factory

How to write the microduck OS onto a robot's eMMC for the first time, from a
Linux PC. The procedure is for the microduck main board with the **V1.0 face
board** (machine `microduck-face-board-v1`). After this first flash the robot
updates itself over the network, so this is done once per robot.

## What you need

- A Linux PC (Debian or Ubuntu) with:
  ```sh
  sudo apt install rkdeveloptool zstd
  ```
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

## Check the robot booted

About 30 seconds after power-on:

- **Face LED**: the green LED double-blinks (a heartbeat), and the fan is off
  or slow. *LED off and fan at full speed* means it did not boot: power-cycle
  it once more.
- **Over the same USB-C cable**: the robot appears as a network link, with the
  robot at `192.168.42.1`. The PC gets an address automatically (on some
  desktops you have to enable the new wired connection).
  ```sh
  ssh microduck@192.168.42.1        # password: microduck
  cat /etc/os-release               # the release you flashed
  robotctl health
  ```
  There is also a serial console on the same cable, `/dev/ttyACM0` on the PC,
  with the same login.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `ld` lists nothing | Charge-only cable, robot not powered (USB-C alone is not enough), or the button was released too early. Try again from step 2. |
| `ld` lists nothing and the Recovery button does nothing | Short test point **TP64 (eMMC_D0) to TP4 (GND)** while powering on: this forces Maskrom. |
| `db` succeeds but `rfi` fails | The DRAM did not start. Power-cycle and retry once; if it persists, set the board aside: [`agents/beta-board.md`](agents/beta-board.md), "A board stuck in maskrom", has the recovery. |
| `wl` stops part way | Cable or USB port. Start again from step 2; the write can be repeated as often as needed. |
| LED off, fan at full speed after flashing | Boot hang. Power-cycle (power off, then on). |
