# A/B updates with RAUC — what an agent needs to know

Where it stands; `README.md` has the overview, and this is the list of things
that will bite you.

| stage | what | state |
|---|---|---|
| 1 | RAUC userspace, signed verity bundles, install to the inactive slot | verified on hardware 2026-09-18 |
| — | `data` partition at `/var/lib/robot`, wifi profiles on it | verified on hardware 2026-09-21 / 2026-09-29 |
| 2a | writable U-Boot environment, `fw_setenv` from Linux | verified on hardware 2026-09-25 |
| — | first 16 MiB moved to Rockchip's layout | verified on hardware 2026-09-25 |
| 2b | U-Boot picks the slot, `bootloader=uboot` | verified on hardware 2026-09-29: A→B, boot B, rollback to A |
| — | kernel and DTB in the slot | verified on hardware (Zero 3W): kernel update and rollback |
| — | OS updates from a published channel (`microduck-osupdate`) | verified on hardware (Zero 3W): install from the list, switch back |
| 3 | move the daemon hooks' OS work into the image; `updaterd` keeps the daemon binaries | not started |

The bundle wraps the dev image (`RAUC_SLOT_rootfs` in
`recipes-core/bundles/microduck-bundle.bb`); switch it to `microduck-image`
before shipping. U-Boot itself is not in a slot.

## The partition table is load-bearing, and one name is not ours

`meta-microduck-bsp/files/wic/microduck-ab.wks.in`. Every partition has an explicit
`--offset` and `--fixed-size`, so wic fails rather than shifting anything. A
bundle built against one layout writing into another is the failure this prevents.

**The kernel partition is named `boot`, not `boot_a`, and you cannot rename it.**
Vendor U-Boot finds the kernel by GPT partition name — its environment carries
`name=boot,size=32M,bootable` and `bootcmd=boot_android ...;boot_fit;bootrkp;run
distro_bootcmd;`. Called `boot_a`, the card flashes perfectly, RKNS is at sector
64, a valid `ANDROID!` image sits in the slot, and the board never loads a kernel:
no wifi, no BLE, looks dead. `boot_b` is reserved at its offset for stage 2, which
is where renaming the pair belongs — beside the `boot.scr` that can choose.

## The kernel is in the slot (2026-10-16)

Each rootfs carries `/boot/Image` and `/boot/microduck.dtb` (a symlink to the
machine's DTB, so one bootcmd serves both boards). After picking the slot,
U-Boot's script `ext4load`s both from that slot's partition and `booti`s them;
only when they are missing does it fall through to Rockchip's chain and the
`boot` partition, which stays as that fallback. So a bundle carries the kernel,
DTB and modules together, and a kernel or toolchain change is an ordinary update
instead of a reflash. Traps:

- **By number, not label.** `ext4load` takes `mmc <dev>:<part>`, and this U-Boot
  has no `part number`: rootfs_a is 6 and rootfs_b 7. `check-wks-layout.py`
  compares those with the boot script, so a reordered wks fails in 0.1 s.
- **The bundle hook checks the bootcmd U-Boot will run**, from `fw_printenv`, not
  the U-Boot binary: a saved environment keeps its bootcmd, and a card that kept
  an old environment would boot the `boot` partition's kernel against the slot's
  new modules. It refuses with "reflash it".
- **`booti` still gets Rockchip's DTB fix-ups and the `/chosen/bootargs` merge**:
  they live in `image_setup_libfdt()`, the generic path, not in `bootrkp`. What
  goes are the `androidboot.*` arguments, which nothing here reads. Check
  `/proc/cmdline` on hardware anyway after touching this.
- `scripts/test-uboot-bootcmd.sh` covers it with a real ext4 card image (symlinks
  included) and a stubbed `booti`.

**`uboot_env` is written at flash time** (#24): the wks rawcopies
`u-boot-initial-env.bin` (oe-core's `UBOOT_INITIAL_ENV_BINARY`, 32 KiB) into it.
It used to be a hole, which `bmaptool` never writes, so a reflashed card kept the
previous card's environment: its `BOOT_ORDER`, and its saved bootcmd.

`scripts/check-wks-layout.py` catches overlaps, unplaced partitions, line
continuations and artifacts that no longer fit, in 0.1 s. Run it before any
build that touches the wks. It is keyed by `--part-name`, so it moves with renames.

`--fixed-size` on idblock is a **bound, not a size**. idblock has no GPT entry,
so wic cannot detect it overlapping anything, and `uboot_env` starts 32 KiB past
the bound. Do not remove it because "nothing reads its length".

## Where RAUC's files are on wrynose

`system.conf` and the keyring install to **`/usr/lib/rauc/`**, not `/etc/rauc/`.
meta-rauc moved them in wrynose; most RAUC docs and the upstream `rk-rauc-demo`
still say `/etc`. The keyring `path=` in system.conf must be absolute.

Config adaptations go in `rauc-conf.bbappend`, not `rauc_%.bbappend`.

## Two things the machine conf used to get wrong about RAUC

- **RAUC does not need `CONFIG_BOOTCOUNT_LIMIT`.** `grep -ri bootcount` over
  RAUC's own docs returns nothing. The retry counter is `BOOT_<slot>_LEFT`, a
  plain env variable our own boot script decrements. What the `uboot` backend
  genuinely needs is a writable environment (`CONFIG_ENV_IS_IN_*`),
  `CONFIG_CMD_SETEXPR`, and `fw_printenv`/`fw_setenv` + `/etc/fw_env.config`.
- **`BOOT_<slot>_LEFT` is hex.** `g_ascii_strtoull(..., 16)` in
  `src/bootloaders/uboot.c`. The stage 2 boot script must say `0x${BOOT_A_LEFT}`.
  A bare `test ${BOOT_A_LEFT} -gt 0` is wrong from 10 upward and for A–F.

Still true from that note: Rockchip's `CONFIG_SPL_AB`/`CONFIG_AVB_LIBAVB_AB` is a
*different, conflicting* A/B mechanism. Do not enable both.

## Stage 2: how the kernel cmdline is actually built, and the trap in it

Read before touching bootargs. All of this is vendor U-Boot 2017.09 at the SRCREV
meta-rockchip pins, read at that exact ref.

**The env var `bootargs` is the single accumulator, and the DT does not win by
being the DT — it wins by being merged last.** Three sources fold into one var:

1. `boot.img`'s header cmdline is appended to env `bootargs`
   (`common/image-android.c:241-259`).
2. `boot_android` assembles its cmdline starting from env `bootargs` as chunk 0
   (`common/android_bootloader.c:403-405`), then writes the result back with
   `env_update` (`:1370-1371`).
3. The DTB's `/chosen/bootargs` is read out and merged *into the env var*
   (`arch/arm/mach-rockchip/board.c:1300-1333`), and the final env value is what
   `board_fdt_chosen_bootargs()` returns as the kernel's cmdline (`:1372-1376`).

So a boot script setting `bootargs` **does** reach the kernel. That is the good
news and it means one `boot.img` can serve both slots.

**The trap: `env_update()` replaces a same-key argument, it does not append.**
`cmd/nvedit.c:406-535` tokenises both strings on spaces, splits each on `=`, and
on a matching key calls `env_replace` (`:511-513`). So if the DTB's
`/chosen/bootargs` carries a `root=` — ours does — it **silently overwrites the
`root=` a boot script set**, with no error from either side. The guard that strips
the DT's `root=` (`board.c:1328`) is compiled only under `CONFIG_ANDROID_AB`,
which `rk3568_defconfig` does not set. This is why "set bootargs in boot.scr" is
not on its own a design.

Three ways out, and the second is ours because it deletes code rather than adding
a mechanism:

1. Set env `android_rootdev` instead — a purpose-built hook that becomes `root=`
   (`android_bootloader.c:432-445`). Still loses to a DT `root=`.
2. **Strip `root=` from the chosen-node patch**, keeping `rw rootwait
   console=ttyFIQ0 console=tty0`. Then the env's `root=` is the only one. Note
   `console=tty0` is load-bearing when `MICRODUCK_MOTOR_UART = "1"`.
3. Enable `CONFIG_ANDROID_AB` for the filter — pulls in Rockchip's *conflicting*
   AVB A/B machinery. No.

Two more facts that shape the rest of stage 2:

- **The kernel partition name is an exact `strcmp` against the literal `"boot"`**
  (`include/android_image.h:14`, `disk/part.c:727`), with no env override. The
  suffix-append path needs `CONFIG_ANDROID_AB`, which is off. So `boot_b` is inert
  — safe to leave reserved — and there is no runtime way to point this U-Boot at
  it. Kernel A/B needs a different mechanism than rootfs A/B, and is not stage 2.
- `bootcmd` is `boot_android ${devtype} ${devnum};boot_fit;bootrkp;run
  distro_bootcmd;` (`include/configs/rockchip-common.h:172-176`). `distro_bootcmd`
  — and therefore any `boot.scr` autodiscovery — runs **last**, only if all three
  earlier arms fail. A `boot.scr` that must be authoritative needs
  `CONFIG_BOOTCOMMAND` changed, not just a file dropped on a partition.

## `bootloader=noop` is deliberate, and two outputs look wrong because of it

The board has no boot-time slot selection: `root=` is compiled into the DTB
inside `boot.img`. So `noop` is the honest backend, and it produces:

- `noop bootloader: ignore setting slot rootfs.1 as primary` on install — success,
  not failure. RAUC did everything it owns and stopped where the board's
  capability ends.
- `boot status: bad` on **both** slots in `rauc status`. `noop` cannot answer,
  RAUC's default for unknown is bad. Becomes real under `bootloader=uboot`.
  Consequence: `rauc install` may need `--target-slot rootfs.1` explicitly,
  because it will not auto-pick when every slot reads bad.

## Build the bundle, not the image

`HFJOB_TARGET=microduck-bundle` builds the bundle **and** the image it wraps,
because `RAUC_SLOT_rootfs` is a dependency. On this branch that is
`microduck-image-dev`, so card and bundle are the same thing. It was briefly
`microduck-image` (prod), which built a card with no password-less root that came
up, answered ping, and could not be logged into. Flip it back to prod when stage 2
can boot slot B and "does a prod rootfs come up" becomes the question.

`RAUC_SLOT_rootfs[fstype] = "ext4"` is required: `bundle.bbclass` defaults to
the first entry of `IMAGE_FSTYPES`, which is oe-core's `tar.zst` here.

## The signing key

Lives at `$KAS_BUILD_DIR/rauc-keys/development-1.{key,cert}.pem`, generated once
with meta-rauc's `scripts/openssl-ca.sh` (README.md has the commands). **Never in
this repo, never in the image.** Only the public CAs (`ca-dev.cert.pem`,
`ca-prod.cert.pem`) are committed.

`scripts/build-hfjob.sh` sends the pair to the job **only for a bundle target**,
the key as `-s` (secret), the cert as `-e`. It refuses locally in 0.1 s if either
is unreadable, because `bundle.bbclass` only checks the key in `do_bundle` —
task 7561 of 7568 — so without the guard a missing key costs a full image build.

That key has been on HF's compute. It is a development key forever; the production
key is a different key under its own CA (below).

## Two CAs

| CA | Signs | Trusted by |
|---|---|---|
| `ca-dev.cert.pem` (meta-rauc's script, valid from 1970) | every CI bundle, in the HF job | the dev image only (`rauc-conf-dev-ca`) |
| `ca-prod.cert.pem` (2026-10-29 to 2046) | released builds only, never in a build job | both images |

RAUC reads one keyring file, `/usr/lib/rauc/keyring.pem`. `rauc-conf` installs the
production CA there; `rauc-conf-dev-ca`, in `microduck-image-dev` alone, appends
the dev CA in its postinst at `do_rootfs`. So a robot running `microduck-image`
refuses every dev-signed bundle in RAUC itself, whatever a channel file says.
The CA's private key is kept offline; only a signing certificate it issued
(`prod-signing-1`, to 2031) is ever used.

`microduck-osupdate` picks its channel from the keyring: `dev` if
`/usr/lib/rauc/ca-dev.cert.pem` exists, `stable` if not. On such a production
board it also refuses a build older than the installed one, because the channel
manifests are unsigned; going back there is `switch`, to the other slot.

Traps:

- **The production certificates start on 2026-10-29**, unlike the dev CA's 1970.
  RAUC checks validity against the clock, and the board has no RTC: an install
  before time sync fails as "not yet valid". osupdate fetches over HTTPS, which
  already needs the time; an offline `rauc install` from a USB stick does not.
- **A board flashed before this keyring trusts the dev CA only**, so it refuses a
  production-signed bundle. One dev-signed bundle from after it moves the board
  over: the slot it writes carries the new keyring.

## Promoting a build to stable

1. Every CI build makes two bundles in one job: `microduck-bundle` (dev image) to
   `dev` and `microduck-bundle-shipping` (shipping image) to `candidate`; from a
   branch, `dev-<branch>` and `candidate-<branch>`. Both are dev-signed.
2. A dev board installs a candidate to test it. **The slot it lands in runs the
   shipping image, so it trusts the production CA only** and follows `stable`:
   from there it takes no dev or candidate build. Go back with `switch` (the
   other slot), not with a download.
3. `promote-os.yml` (Actions → promote-os → Run workflow, `production`
   environment) releases one commit for every board: a `patch`/`minor`/`major`
   bump, and a commit (empty = the commit of the Zero 3W's newest candidate).
   Each board takes its newest candidate built from that commit; a board without
   one fails the run before anything is signed. There are no release candidates;
   candidate builds tested on dev boards play that part. It re-signs the bundles
   with the production key and publishes each to its board's `stable`. `rauc
   resign` changes the signature only, so the build ids and payloads are the
   tested ones. The version is the highest `microduck-os-v<X.Y.Z>` release bumped
   (from 0.0.0), shared by every board, and it is what robots show ("updated to
   1.0.0"). The bundle's own RAUC version (`PV` in `microduck-bundle.bb`, seen only
   by `rauc info`) is the newest release when it was built (`scripts/os-release.sh`); dev and candidate builds show `<that release>+<build>`. The one GitHub release,
   `microduck-os-v<X.Y.Z>` titled `v<X.Y.Z>`, is tagged at the commit and carries
   each board's re-signed bundle (`microduck-os-v<X.Y.Z>-<board>.raucb`) plus its
   shipping card (`.wic.zst`, `.bmap`) from the same job. The cards come from
   `deploy/<job>/`, pruned after 14 days, so a commit older than that has to be
   rebuilt first. A re-run after a failure reuses its release's version, found by
   the sentence "Stable OS build <build> for" in the notes: keep those lines when
   editing them.
   GitHub releases made by hand (`build-image.yml`'s `release` path) carry the
   dev image and dev bundle only.
4. The release's notes are drafted by OpenCode (`scripts/release_notes/`, skill
   `.opencode/skills/microduck-os-release-notes/`, ported from reachy_mini): the
   PRs merged since the previous `microduck-os-v*` release (the newest other
   release for the first one) up to the release's commit. A validator checks the
   draft names exactly those PRs and loops the model on the difference. If the
   model fails, or is not configured, the release gets plain notes; it never holds
   a promotion back. Edit the notes on GitHub afterwards; a re-run keeps them.
   Setup, the same as reachy_mini's: secret `RELEASE_NOTES_HF_TOKEN` (an HF token
   with Inference Providers), variables `RELEASE_NOTES_MODEL`
   (`huggingface/zai-org/GLM-5.3`) and `OPENCODE_VERSION` (`1.19.4`). Preview locally:
   `GITHUB_TOKEN=$(gh auth token) RELEASE_NOTES_MODEL=... python -m
   scripts.release_notes.generate_release_notes --since v0.1.0 --head main
   --version microduck-os-preview-zero3 --title "preview"`
   (needs `pip install PyGithub` and opencode logged in to huggingface).
   Only PRs count: a commit pushed straight to main is not in the notes, and a
   `#<number>` that is not one of the release's PRs (an issue) gets its line
   removed by the validator. Link issues by full URL.

To move a board flashed before the two CAs straight to a release, install that
build from `candidate` *before* promoting it: afterwards its list entry points
at the production-signed bundle, which the old keyring refuses.

Traps:

- **The two bundles of one run share `DATETIME`.** `microduck-bundle-shipping.bb`
  takes `DATETIME` + 1 s as its build id; everything that keys on build ids
  (osupdate's "already running", `builds/<build>.env`) would collide otherwise.
- **The signing certificate expires in 2031.** After that, stable's bundle stops
  verifying. Before then, issue `prod-signing-2` from the CA (kept offline),
  replace `RAUC_PROD_KEY`/`RAUC_PROD_CERT`, and re-promote the current stable build.
- `production` allows `main` only, so `promote-os.yml` can only run once merged.

## User data survives; know exactly what that means

`data` is ext4, 8 GiB, mounted at `/var/lib/robot` by `recipes-core/microduck-data/`.
That is where the daemon already keeps everything a user adds — `POLICY_LIBRARY`,
the sound bank, `StateDirectory=robot/*` — so **no daemon change was needed**,
and that was checked: the policy installer's `fs::rename` calls stay inside the
library root, so nothing crosses a filesystem boundary.

- Survives: daemon updates (never touched it) and RAUC slot switches (neither
  slot touches it).
- Does **not** survive: a reflash of the whole `.wic`, which zeros that region.
  Do not describe it as if it did.
- **Anything outside it is per-slot**, and an install writes a whole fresh slot.
  BlueZ's bonds in `/var/lib/bluetooth` were: every OTA unpaired the gamepad
  (measured 2026-10-30: both slots' trees dated from their own install, no pad
  in either). `var-lib-bluetooth.mount` now bind-mounts them from
  `/var/lib/robot/bluetooth`, the way the journal and the wifi profiles moved.
- **A failed mount cascades, and this cost a board its updater.** The daemon
  units carry `StateDirectory=robot/config` and `robot/updater`; systemd turns
  those into an implicit `RequiresMountsFor=/var/lib/robot/...`, i.e. a
  `Requires=` on `var-lib-robot.mount`. When that mount *failed* (unformatted
  partition), `configd` and `updaterd` never started — "Dependency failed for
  Robot config service (wifi, identity)". `WantedBy` on the mount did nothing
  for this; only a *skipped* unit satisfies `Requires=`. Hence
  `ConditionPathExists=/dev/disk/by-label/data`: udev creates `by-label/<x>`
  only when blkid finds a filesystem labelled `<x>`, so one path answers both
  "is there a partition" and "is it formatted", and a blank one degrades to the
  rootfs directories with all daemons up. Verified live on the failing board.
- A `.mount` unit, not a wic `--mountpoint`: the latter writes `/etc/fstab`, and
  a missing partition there is an emergency shell.
- `data-directory=/var/lib/robot/rauc` in system.conf puts RAUC's own bookkeeping
  there too. Without it RAUC keeps per-slot status that a slot rewrite erases.

`/opt/robot/daemon` stays **on the rootfs** on purpose: it is core, replaced by
the image, reseeded on flash. A slot switch reverts the daemon to the image's
seed and `updaterd` converges it again — test that deliberately once stage 2 exists.

**A RAUC-written slot's filesystem is the image's size, not the slot's.** `rauc
install` writes the bundle's ext4 raw into the 2 GiB slot. The image is ~740 MB with
~90 MB free, so after one daemon release (~51 MB, and updaterd keeps `golden` and
`current`), the next update failed preflight (`DiskSpace`, 2026-10-02). Only a
flashed slot A got 2 GiB, from wic's `--fixed-size`. The root line of fstab
carries `x-systemd.growfs` (`recipes-core/base-files`). systemd-fstab-generator
turns that into `systemd-growfs-root.service`, which grows `/` online at boot; on
the board it took 69 ms. Do not "fix" this with `IMAGE_ROOTFS_SIZE`: every bundle
would then carry 2 GiB.

## What is not done

- `boot_b` is reserved and empty; the kernel's A/B is the slots' `/boot` (above).
- **A fresh card is pinned to slot A** (since 2026-10-06, temporarily): U-Boot
  seeds `BOOT_ORDER="A"`, not `"A B"`, so B is only booted when a RAUC install
  puts it first. When A's attempts run out, both counters reset and the board
  resets onto A. Bring-up kept landing on B after a few quick reboots. To pin a
  running board: `fw_setenv BOOT_ORDER A`. Since `uboot_env` is written at flash
  time (#24), every flashing tool now gives a fresh card the default order.
- **A fresh card fills `rootfs_b` with the same rootfs as A** (since
  2026-10-06). Before that it was empty, and U-Boot's script still falls back
  to B once `BOOT_A_LEFT` reaches 0, booting the shared kernel onto nothing: a
  panic, and on the beta board a solid face LED and full fan, every boot until
  B's attempts ran out too. Three reboots before rauc-mark-good runs are
  enough to get there.
- Nothing can select a slot at boot yet. **Stage 2a is verified on hardware
  (2026-09-25)**: a writable U-Boot environment
  (`recipes-bsp/u-boot/files/rauc-env.cfg`) plus `/etc/fw_env.config` and
  U-Boot's default env as `/etc/u-boot-initial-env`, both installed by oe-core's
  `u-boot.inc` into `u-boot-rockchip-env`; `fw_printenv`/`fw_setenv` arrive via
  meta-rauc's own RDEPENDS. The proof is that **U-Boot reads what Linux
  writes**, not merely that Linux reads back its own write: `fw_setenv bootargs
  microduck.envprobe=1`, reboot, and the token led `/proc/cmdline`. `bootargs` is
  the accumulator U-Boot builds the kernel cmdline from, so only a U-Boot that
  loaded our region could have put it there. (Verified at the old 0x80000 offset;
  the layout has since moved it to Rockchip's 0x3F8000 — see the next item — so
  the next flash re-runs this same probe.) A probe variable also
  survived, the board booted normally, 0 failed units.
  Build-time evidence, for when this is suspected: the deployed `uboot-*.bin`
  gains `setexpr` (0 → 8 occurrences) and `ENV_BLK` (0 → 2) against a pre-2a
  build. The `bb.note` from the `do_configure` postfunc is *not* in the job log —
  it goes to the per-recipe log that `rm_work` deletes — so its absence means
  nothing.
  **The default-env file is load-bearing, and the first image lacked it.** A
  fresh card's env region is zeros, so the CRC fails; without
  `/etc/u-boot-initial-env`, `fw_setenv X 1` writes an environment holding only
  `X`, with a valid CRC, and U-Boot then imports that in place of its defaults —
  no `bootcmd`, board stuck at an invisible prompt. It was copied onto the test
  board by hand before any write; the image now ships it (not yet rebuilt).
  Stage 2b's first flash (build `6ab677a0`, 2026-09-25) **did not boot**, and
  the card said why without a console. U-Boot had saved the environment, so it
  ran the script, but with `BOOT_A_LEFT=3 BOOT_B_LEFT=3` and no `rauc_slot`:
  the give-up branch, on every boot, followed by `reset`. The kernel never
  mounted `rootfs_a`. Cause: `test 0x${BOOT_A_LEFT} -gt 0`, RAUC's own idiom, is
  always false on this U-Boot. `test` calls `simple_strtol(..., 10)`, and the
  vendor's `lib/strto.c` honours that base, so `0x3` parses as 0. Mainline's
  parser switches to hex on `0x` regardless, which is why the idiom works
  elsewhere and why the mainline sandbox passed. Fixed by comparing the
  counter as a string against `"0"`. The sandbox now builds with the vendor's
  `strto.c`, and with it reproduced the board failure exactly (8 of 9 cases)
  before passing the fix (9 of 9). The failed card also proved U-Boot's own
  `saveenv` works.
  Stage 2b is **verified on hardware (2026-09-29, build `6ab69578`)**: A→B via
  `rauc install`, a boot from B, user data intact across the switch, and
  rollback to A after `rauc status mark-bad booted`, with no power-cycle.
  **One thing that switch exposed, and it looks exactly like a failed boot:** a
  slot with no wifi profile. NetworkManager kept profiles in the rootfs, so B
  came up healthy and unreachable, and it took two power-cycles and Bluetooth
  provisioning to tell the two apart. Profiles now live on the data partition
  (`recipes-core/microduck-data`), verified on hardware the same day: a switch
  to a slot with no profile of its own came back on wifi by itself, 21 s into
  boot. When a slot "does not boot", check over BLE
  (`duckctl scan`, `duckctl health`) before concluding it did not.
  Stage 2b was first **written and sandbox-tested (2026-09-25)**: the U-Boot header patch that prepends slot selection to
  `bootcmd`, the chosen node without `root=`, and `bootloader=uboot`. Before
  editing the script, run `scripts/test-uboot-bootcmd.sh <v2017.09 sandbox>`.
  The header of that script explains why a mainline sandbox is a faithful stand-in
  and how to build one. Two facts it established that are easy to get wrong:
  `CONFIG_SYS_CBSIZE` (1024) does **not** limit `bootcmd`, since a 4000-character
  script ran to the end; and `saveenv` cannot be tested there, because the
  sandbox has no env storage. It is proven on hardware instead: the card that
  failed to boot carried an environment U-Boot itself had saved.
  The fallback is `radxa/u-boot next-dev-v2024.10`, which boots via extlinux
  (see `conf/machine/microduck-zero3.conf`).
- **Fixed and verified on hardware 2026-09-25: U-Boot was corrupting its own
  primary copy on first boot.** Rockchip "vendor storage" (MAC address, serial number)
  lives at a fixed `EMMC_VENDOR_PART_OFFSET = 1024 * 7` sectors = **3.5 MiB
  absolute**, 128 sectors = 64 KiB (`arch/arm/mach-rockchip/vendor.c:30-35`).
  The old layout, copied from JeffyCN's generic wks, put `uboot` at 2–6 MiB, so
  that window was 1.5 MiB into `uboot.img` — two identical 2 MiB FIT copies,
  hence inside the **primary**. Measured on the board: a freshly flashed card
  differed from the `.wic` in exactly that 64 KiB and nowhere else, after the
  first boot generated a MAC and wrote it back (`board.c` `need_write`). It still
  booted, inferred from the backup copy (no console to see it).
  The fix is to stop improvising the first 16 MiB: they now follow Rockchip's
  table (opensource.rock-chips.com/wiki_Partitions, as transcribed by upstream
  Yocto meta-rockchip) — `v_storage` reserved at sector 7168, `uboot_env` at
  8128 = `0x3F8000` (the vendor default, so the offset override is no longer
  working around anything), `uboot` at 8 MiB (the loader's default, and still
  named `uboot`, so both by-name and by-sector lookup find it). Everything after
  shifts down 10 MiB. `scripts/check-wks-layout.py` now asserts those three fixed
  offsets and cross-checks the wks, `rauc-env.cfg` and `fw_env.config`, which
  previously agreed only because comments said they must.
  Verified on the flashed card (build `6ab6290c`): after first boot *and* after a
  second reboot, the `uboot` partition hashes identically to the `.wic`'s
  8–12 MiB region (`179013ba…`), and `v_storage` holds U-Boot's data, so the
  MAC went where it belongs. The environment probe passed again at `0x3F8000`:
  `microduck.envprobe=1` led `/proc/cmdline` after reboot. This time
  `/etc/u-boot-initial-env` came from the image, so the first `fw_setenv` saved
  the 43 defaults plus the probe with nothing copied by hand. 0 failed units.
- The `data` partition is **done, both paths on hardware**. Blank partition:
  mount skipped, every daemon up (2026-09-18, incomplete-download card). Correctly
  flashed card, first boot, no hand-formatting (2026-09-21): wic's own `mkfs`
  produced `by-label/data`, `var-lib-robot.mount` came up (`/dev/mmcblk1p7 ext4
  7.7G`), `StateDirectory=` created `config/` and `updater/` on the empty
  filesystem, all five daemons active, zero failed units, no RAUC
  data-directory warning. Note that image was built from `c15f752`, *before* the
  Condition fix in `e8130b0` — which is fine, a correct flash never takes the
  degraded path — but it means **no image containing `e8130b0` has been built**.
  The next `HFJOB_TARGET=microduck-bundle` run picks it up; nothing to test, the
  condition is already proven live as a runtime drop-in.
- `updater-design.md` in the daemon repo (`:46`) still records A/B as rejected
  ("would be over-engineering"). Its premise — "the OS is static" — expired the
  week the camera DTS and three GStreamer patches each needed a reflash. Update
  it rather than leave it contradicting the code.
