# microduck_os

The operating system for **microduck**, a small bipedal robot by
[Pollen Robotics](https://www.pollen-robotics.com/): a Yocto image for the
Rockchip RK3566, built on the Rockchip vendor BSP (kernel 6.1) and
[kas](https://kas.readthedocs.io/).

It boots straight into the robot's software, the daemons from
[`pollen-robotics/microduck`](https://github.com/pollen-robotics/microduck),
and updates itself with signed A/B bundles that roll back on their own when a
new slot does not come up healthy.

| Board | Machine | Status |
|---|---|---|
| Radxa Zero 3W (stand-in for the robot's board) | `microduck-zero3` | boots, updates, rolls back; flashed as an SD card |
| microduck beta board (Seeed, first spin of the custom PCB) | `microduck-beta` | runs, open items in [`docs/agents/beta-board.md`](docs/agents/beta-board.md); flashed over USB-C to eMMC |
| beta board with the V1.0 face board | `microduck-face-board-v1` | what the factory flashes; same as the beta but for the face; flashed over USB-C to eMMC |

## What is in the image

- **The robot's daemons**: `robotd` (the 50 Hz Dynamixel control loop),
  `updaterd`, `mediad` (camera over WebRTC), `btd`, plus the policy set `robotd`
  walks with, seeded at build time.
- **A/B OS updates with [RAUC](https://rauc.io/)**: kernel, device tree and root
  filesystem update together into the inactive slot; U-Boot falls back to the
  other slot if the new one does not pass its health check. User data lives on
  its own partition and survives every update.
- **OS updates from a published channel**: `microduck-osupdate` checks a public
  bucket for new builds, installs a chosen one, or switches back to the other
  slot. There is a page for it on the robot at `http://<robot>:8090`.
- **The board support**: radio drivers and Bluetooth attach for both boards,
  the camera ISP tuning for the beta board, hardware video encoding (MPP), and
  the motor bus on UART2.

Two images are built from the same recipes:

- **`microduck-image-dev`** (the default) adds password-less root login over ssh
  and debugging tools (`strace`, `tcpdump`, `evtest`, GStreamer tracers…). It
  only ever adds to the shipping image, so what is verified on it holds for both.
- **`microduck-image`** is the shipping image, with no root login.

## Get an image

Each [release](https://github.com/pollen-robotics/microduck_yocto/releases) is
built from its tag for every board and carries the card image (`.wic.zst`, its
`.bmap` and checksum), the update bundle (`.raucb`), the package manifest, and
for the beta main boards `<machine>-loader.bin`, which `rkdeveloptool` needs.
`gh release download <tag>` fetches them. Every push to `main` also builds the
Zero 3W and publishes its bundle to the `dev` update channel.

**Zero 3W**, onto a 16 GB or larger SD card (needs `bmap-tools`; `bmaptool`
reads the `.zst` directly and writes only the blocks in use):

```sh
sudo bmaptool copy --bmap microduck-image-microduck-zero3.rootfs-*.wic.bmap \
  microduck-image-microduck-zero3.rootfs-*.wic.zst /dev/sdX
```

**Beta and face-board-v1 boards**: [`docs/flashing.md`](docs/flashing.md) is the
step-by-step for writing the eMMC with `rkdeveloptool`, written for the factory.
A board stuck in maskrom is in [`docs/agents/beta-board.md`](docs/agents/beta-board.md).

Then give the robot wifi over Bluetooth (`duckctl wifi connect`, from the daemon
repo). No RTC is fitted, so nothing that uses TLS works until the clock has
synced over the network.

## Update a running robot

From the page at `http://<robot>:8090`, or on the robot:

```sh
microduck-osupdate check           # newest build on the channel, and the list of builds
microduck-osupdate apply [BUILD]   # download, verify, install into the other slot, reboot
microduck-osupdate switch          # boot the other slot as it is (rollback, no download)
microduck-osupdate status
```

Or install a bundle by hand:

```sh
rauc install microduck-bundle-*.raucb    # writes the inactive slot and makes it primary
reboot
rauc status mark-bad booted && reboot    # roll back to the other slot
```

A slot is marked good only once `microduck-slot-health.service` passes: the core
daemons must have come up, as the daemon's own `robot-boot-check --dry-run` judges
it (about 25 s after boot on a healthy one), the running kernel must
be the slot's own (its modules are there), and a new OS must not have lost a radio
the latest OS that passed had (wifi, Bluetooth). Missing hardware does not fail a
boot on its own: a radio that disappears under an OS that already passed here (the
same boot again, or a rollback) is logged and forgiven, so a board with a dead or
not-yet-working chip can still update and roll back. `scripts/test-slot-health.sh`
runs every case. An unhealthy slot is left unmarked rather than rebooted; each later
reboot into it uses up one of its attempts, and when they run out U-Boot boots the
other slot.

**A slot with no network looks exactly like one that did not boot.** Check over
Bluetooth (`duckctl scan`, `duckctl health`) before concluding it failed.

## Build

The image is built with kas, and needs a few hundred GB of disk and several hours
the first time; afterwards the shared-state cache makes rebuilds a matter of
minutes.

### Locally

You need Docker and [`kas-container`](https://kas.readthedocs.io/en/latest/userguide/kas-container.html)
on your `PATH`. Put your build paths in `kas/local.env` (git-ignored):

```sh
export KAS_BUILD_DIR=/srv/yocto/build
export DL_DIR=/srv/yocto/downloads
export SSTATE_DIR=/srv/yocto/sstate
```

then

```sh
scripts/build-local.sh                                   # the dev image, Zero 3W
scripts/build-local.sh build --target microduck-image    # the shipping image
scripts/build-local.sh shell                             # a bitbake shell
KAS_FILES=kas/microduck.yml:kas/beta.yml scripts/build-local.sh   # the beta board
```

The daemon recipe fetches its repository over SSH, so the build needs an
`ssh-agent` holding a key registered with GitHub, and `KAS_SSH_DIR` pointing at a
directory with a `known_hosts` that trusts github.com.

Paths are environment variables rather than `local.conf` entries because
`kas-container` bind-mounts `KAS_BUILD_DIR`, `DL_DIR` and `SSTATE_DIR` into the
container; a path in `local.conf` would name a host directory the container
cannot see. `kas/microduck.yml` itself has no absolute paths and pins every
layer to a commit, so a build is reproducible on any host.

### On Hugging Face Jobs

The team builds on [Hugging Face Jobs](https://huggingface.co/docs/huggingface_hub/guides/jobs)
with a persistent cache in a storage bucket, and so does CI:

```sh
scripts/build-hfjob.sh                                  # the dev image
HFJOB_TARGET=microduck-bundle scripts/build-hfjob.sh    # image + signed update bundle
HFJOB_MACHINE=microduck-beta scripts/build-hfjob.sh     # the beta board
```

The header of `scripts/build-hfjob.sh` lists every option, and
[`docs/agents/hf-jobs.md`](docs/agents/hf-jobs.md) covers the cache and the
traps. The `build-image` workflow runs it on every push to `main`, on every
published release, and on demand.

### Which daemon the image seeds

The newest `microduck` daemon release, unless the build names another. The
recipe carries no version of its own: `scripts/daemon-release.sh` looks the
release up, and the build scripts pass its version and commit in and regenerate
the crate list for it.

```sh
DAEMON_VERSION=0.16.1 scripts/build-local.sh
HFJOB_DAEMON_VERSION=0.16.1 scripts/build-hfjob.sh
```

The `build-image` workflow has the same choice as its `daemon_version` input.
A plain `kas build kas/microduck.yml` sets neither, so the daemon recipe skips
itself and the image does not build.

### Signing keys

Bundles are signed, and a robot installs only bundles signed by a key its CA
trusts. There are two CAs in `meta-microduck/recipes-core/rauc/files/`:
`ca-dev.cert.pem`, trusted by the dev image only, and `ca-prod.cert.pem`,
trusted by both. The private keys are never in this repository or the image. CI
signs every build with the development pair from its `RAUC_DEV_KEY` /
`RAUC_DEV_CERT` secrets; only the `promote-os` workflow holds the production
pair, and it re-signs a tested `candidate` build for `stable`
(`docs/agents/rauc.md`, "Two CAs"). To sign your own dev builds, make a CA and
key once, into the build directory:

```sh
. kas/local.env
mkdir -p "$KAS_BUILD_DIR/rauc-keys" && cd "$KAS_BUILD_DIR/rauc-keys"
curl -sfLO https://raw.githubusercontent.com/rauc/meta-rauc/wrynose/scripts/openssl-ca.sh
chmod +x openssl-ca.sh && ./openssl-ca.sh                # edit ORG=/CA= at the top first
cp openssl-ca/dev/development-1.cert.pem .
cp openssl-ca/dev/private/development-1.key.pem .
chmod 600 development-1.key.pem
```

and replace `ca-dev.cert.pem` with `openssl-ca/dev/ca.cert.pem`. A robot flashed
with one CA refuses bundles signed under another.

## Repository layout

```
kas/microduck.yml        layer pins and build configuration; no host paths
kas/beta.yml             compose last to build the beta board
kas/hfjob.yml, hfjob.env the HF Jobs build
kas/cve.yml              compose for a CVE scan
meta-microduck/          the robot's software: images, daemons, policies, RAUC
                         bundle and config, OS updates, data partition, media
meta-microduck-bsp/      the boards: machine confs, kernel, U-Boot, radio
                         drivers, camera tuning, partition layout
meta-microduck-distro/   the distro: init, network stack, what runs by default
scripts/                 build, publish and test scripts
docs/flashing.md         flashing a robot's eMMC, for the factory
docs/agents/             deep notes, each a list of things that bite
```

The upstream layers are `openembedded-core`, `bitbake`, `meta-yocto`,
`meta-openembedded`, `meta-rockchip` and `meta-rauc`, all on Yocto 6.0
**wrynose** (LTS to April 2030). There is no `poky` repo: it has no wrynose
branch, so the three repos it combines are checked out separately.

The partition layout is `meta-microduck-bsp/files/wic/microduck-ab.wks.in`. Its
first 16 MiB follow Rockchip's documented table, because vendor code writes to
fixed offsets there without reading the GPT:

| # | label | offset | size | contents |
|---|---|---|---|---|
| — | *(idblock)* | 32 KiB | 3552 KiB | loader; the boot ROM reads sector 64 |
| 1 | `v_storage` | 3.5 MiB | 256 KiB | Rockchip vendor storage: MAC, serial |
| 2 | `uboot_env` | 0x3F8000 | 32 KiB | U-Boot environment: slot order and retry counters |
| 3 | `uboot` | 8 MiB | 4 MiB | `uboot.img` |
| 4 | `boot` | 16 MiB | 32 MiB | fallback kernel and device tree |
| 5 | `boot_b` | 48 MiB | 32 MiB | reserved |
| 6 | `rootfs_a` | 80 MiB | 2 GiB | slot A, kernel included |
| 7 | `rootfs_b` | 2128 MiB | 2 GiB | slot B |
| 8 | `data` | 4176 MiB | 8 GiB | `/var/lib/robot`: policies, sounds, config, wifi |

[`docs/agents/rauc.md`](docs/agents/rauc.md) has the update design and its
traps.

## Hardware notes

- **UART2 is contested.** It is both the RK3566 debug console and the bus
  `robotd` drives the 15 Dynamixel servos and the IMU on, and they cannot share
  it: a getty reads servo replies before `robotd` does, and kernel messages
  corrupt them. `MICRODUCK_MOTOR_UART` in
  `meta-microduck-bsp/conf/machine/include/microduck-common.inc` gives it to the
  motors (the default). U-Boot still prints on it at power-on.
- **No RTC.** Time comes from the network, and TLS fails until it has.
- **Zero 3W radio.** The AIC8800's Bluetooth needs `hciattach`, never
  `btattach`, and gamepad pairing needs a workaround; both are in
  [`docs/agents/zero3-board.md`](docs/agents/zero3-board.md).

## Developing software for the image

You do not need a Yocto tree to work on the robot's software:

1. **Pure Rust** (`robotd`, `updaterd`, `robotctl`): the daemon repo
   cross-compiles on its own (`cargo board`); copy the binaries to the robot.
2. **Linking native libraries** (`mediad` against GStreamer and MPP): build the
   SDK once with `bitbake microduck-image -c populate_sdk`, install it, and
   `source` its `environment-setup-*` script; cargo, meson and cmake then link
   against the real target libraries.
3. **Changing a recipe in the image**: `devtool modify <recipe>`,
   `devtool build`, `devtool deploy-target <recipe> root@<robot>`.

Some things can be tested without a board. A container from the rootfs tarball
(`zstd -dc ...rootfs.tar.zst | docker import - microduck-rootfs`, with
`qemu-aarch64` binfmt) checks that binaries link and run. The kernel carries a
`qemu-virt.cfg` fragment, so the exact kernel and rootfs that ship also boot
under `qemu-system-aarch64 -M virt -cpu max`, which catches systemd ordering and
network bring-up problems. U-Boot, the device tree, the radios and the motor bus
need hardware.

## Contributing

Read [`AGENTS.md`](AGENTS.md) first: it is the working notes for this repository,
for people and coding agents alike, and lists the upstream assumptions that have
already cost a build. Before opening a pull request:

- bitbake parses and the target builds;
- `oelint-adv` is clean (CI runs it; the command is in `AGENTS.md`);
- after touching the partition layout, `scripts/check-wks-layout.py` says
  `layout ok`;
- after touching U-Boot's boot script, `scripts/test-uboot-bootcmd.sh` passes.

Report security issues privately, as [`SECURITY.md`](SECURITY.md) describes.

## License

The metadata in this repository (recipes, configuration, scripts, docs) is
licensed under Apache-2.0, like the `microduck` daemon; see `LICENSE`. Patches
carry the licence of the project they patch. The software the recipes build
keeps its own licence, which each recipe declares in `LICENSE`.
