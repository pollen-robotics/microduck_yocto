# The Radxa Zero 3W stand-in (`microduck-zero3`) — what an agent needs to know

The Zero 3W runs the image until the custom PCB is the board people flash. Its
radio and its U-Boot each have traps worth knowing before you blame the image;
the beta board's are in `beta-board.md`.

## Which Zero 3W you have

The board shipped with two incompatible wifi modules. On a running board:

```sh
dmesg | grep -iE 'brcmf|aic8800'
```

`aic8800` is the SDIO AICSemi AIC8800DS2, which `microduck-zero3.conf` builds
for (`rk3566-radxa-zero-3w-aic8800ds2.dtb`, driver from
`meta-microduck-bsp/recipes-kernel/aic8800`). `brcmfmac` is the Broadcom
AP6212a1, which this image does not support.

## U-Boot is Rockchip downstream 2017.09

meta-rockchip's `u-boot-rockchip` is Rockchip's downstream U-Boot 2017.09, built
by `make.sh rk3568` with DRAM init from rkbin's TPL. Our only change is the RAUC
slot selection prepended to `bootcmd` (`meta-microduck-bsp/recipes-bsp/u-boot`).

Radxa's fork (`radxa/u-boot` `next-dev-v2024.10`) is, despite the branch name,
*also* 2017.09, and does carry `rk3566-radxa-zero3.dts` and
`radxa-zero3-rk3566_defconfig` — so it is the fallback if the generic rk3568
build cannot reach the kernel. It is not the default because meta-rockchip only
tests the Miniloader path and radxa's defconfig is SPL+ATF.

Two findings from reading those defconfigs, recorded in
`conf/machine/microduck-zero3.conf`:

- **No Rockchip defconfig sets `CONFIG_ENV_IS_IN_*`**, so out of the box this
  U-Boot has no persistent environment at all: the Kconfig choice falls to
  `ENV_IS_NOWHERE`, and `saveenv` silently does nothing. RAUC's `uboot` backend
  needs one, plus `fw_printenv`/`fw_setenv` and `/etc/fw_env.config`;
  `recipes-bsp/u-boot` provides all of it (`rauc.md`).
  This U-Boot also has Android/AVB A/B (`CONFIG_SPL_AB`, `CONFIG_AVB_LIBAVB_AB`),
  a different mechanism that must not be enabled alongside RAUC's.

  This bullet used to say RAUC needs `CONFIG_BOOTCOUNT_LIMIT` too. **It does
  not**, and that was never checked: `grep -ri bootcount` over RAUC's own
  documentation returns nothing. The retry counter is `BOOT_<slot>_LEFT`, a
  plain environment variable that the boot script we write decrements itself —
  and RAUC parses it as **hex** (`g_ascii_strtoull(..., 16)` in
  `src/bootloaders/uboot.c`). RAUC's own `test 0x${BOOT_A_LEFT} -gt 0` idiom is
  always false on this vendor U-Boot, though, so our script compares the counter
  as a string (`rauc.md`, stage 2b).
- **`CONFIG_DEBUG_UART_BASE=0xFE660000` is UART2**, the motor bus, at 1.5 Mbaud.
  U-Boot therefore prints onto the Dynamixel wires at power-on regardless of
  `MICRODUCK_MOTOR_UART`, which only silences Linux. Harmless now; on the custom
  PCB, put the debug UART elsewhere.

## WiFi/BT: AIC8800

The board is the SDIO AICSemi AIC8800DS2 variant, so `KERNEL_DEVICETREE` is pinned
to `rk3566-radxa-zero-3w-aic8800ds2.dtb` and the out-of-tree driver comes from
`meta-microduck-bsp/recipes-kernel/aic8800`.

Verified present in the rootfs (not merely in the manifest):

```
/usr/lib/modules/6.1.172-rockchip-standard/extra/aic8800_{bsp,btlpm,fdrv}.ko
/usr/lib/modules-load.d/aic8800_{bsp,btlpm,fdrv}.conf
/usr/lib/firmware/aic8800_fw/SDIO/{aic8800,aic8800D80,aic8800D80N,...}/
```

`/lib -> usr/lib` (usrmerge), so the `/lib/firmware/...` path the driver's
`fix-sdio-firmware-path.patch` sets does resolve.

## Bluetooth needs `hciattach`, not `btattach`

The BT side is **HCI over uart1** — `/dev/ttyS1` at 1500000 baud. (Not to be
confused with uart2 / `/dev/ttyS2`, which is the Dynamixel bus.) `aic8800_btlpm`
is only an rfkill power switch: it registers a platform driver and nothing else,
no character device and no HCI transport, so something in userspace has to
attach the controller. `aic8800-bt` ships `aic8800-bt-attach.service` to do it,
enabled by default.

**Use `hciattach`. `btattach` does not work on this chip, and its failure looks
like dead hardware.** `btattach` creates `hci0` and transmits, but never
receives a single byte — TX 4, RX 0, `HCI_Reset` timing out with `-110` —
identically at 1500000 and 115200, with and without flow control. The working
command is:

```sh
hciattach -n -s 1500000 /dev/ttyS1 any 1500000 flow
```

`-s` sets the port speed *before* the HCI line discipline attaches; `btattach`
attaches the discipline first. That is the explanation for the difference and it
fits every measurement, but it was established by testing the two tools, not by
reading their internals — what is certain is which command works.

**rfkill has to be cleared twice.** Once before the attach, for the chip-level
kill that is soft-blocked at boot; and again *after*, because BlueZ registers a
second rfkill node for `hci0` itself when the adapter appears, and that one is
born blocked. Skip the second and `hciconfig hci0 up` fails with `Operation not
possible due to RF-kill (132)`. The first clear cannot cover a node that does
not exist yet.

Working result, from a cold boot:

```
hci0:  BD Address: 50:37:CD:16:5A:3D   HCI Version: 5.4 (0xd)
       UP RUNNING   RX bytes:1460 events:89
bluetoothctl show -> Powered: yes
```

**To debug it, use the vendor's own tool.** `aic8800-bt-test` (dev image) ships
AICSemi's `bt_test`, which bypasses the Linux Bluetooth stack and talks to the
chip directly:

```sh
bt_test -s uart 1500000 /dev/ttyS1     # server, holds the transport
bt_test -c 01 03 0c 00                 # client, sends HCI_Reset
```

A healthy chip answers `04 0E 04 05 03 0C 00` — Command Complete, opcode 0x0C03,
status 0. That one result is what separated "the radio is broken" from "our
tooling cannot talk to a working radio", after a day spent on power rails, reset
GPIOs and device-tree nodes. Its `-s wlan wlan0` mode fails with
`ioctl[TX_PARA] -1`, which rules out HCI-over-SDIO: the transport really is the
UART.

Not verified: that `btd` can advertise through the adapter. `btd` is not built
yet, and the LE checks available from a shell conflict with `bluetoothd` holding
the adapter.

## Gamepad pairing: an AIC8800 workaround, tagged `remove-with-real-radio`

An Xbox pad will not bond reliably through this radio without help, and the help
lives in `microduck_daemon`'s `scripts/setup-board.sh` — driven by
`provision-board.sh`, the Armbian path, which never runs against a Yocto board.
So the half that is safe everywhere is applied by a recipe here, and the half
that is not is left to whoever meets it.

**Shipped in the image.** `microduck-daemon` writes `/var/lib/robot/weird-ble`,
which is what `provision-board.sh --pause-btd-on-pair` leaves. `robotctl pad
pair` reads only whether that file exists; when it does, it stops `btd` for the
pairing window, power-cycles the adapter, pairs and starts `btd` again. Measured
upstream on `50:37:CD:16:1D:90`, 2026-08-19: with `btd` advertising a **new**
bond dies ~800 µs after Encryption Change with `Remote User Terminated (0x13)`;
with `btd` paused it bonds and holds, 45/45 samples. Every earlier failure blamed
on the aic8800 driver build had `btd` advertising — that was the uncontrolled
variable. An existing bond is unaffected, so a paired pad connects and drives
with everything running. It costs a pairing window and nothing else, so it is on
by default; `sudo rm /var/lib/robot/weird-ble` opts out.

**Not shipped: `Privacy = device`**, the `--weird-ble` half. Some units cannot
bond under BlueZ's default `Privacy = off` at all, even with `btd` paused, and
want it. But on a unit that did *not* need it the pad bonds and then flaps with
`PIN or Key Missing (0x06)` — 46 times in 45 seconds on the same board — never
creating an input device. That failure looks like success at first, which is the
worst shape of it, and roughly half of ten Zero 3W units measured upstream fall
in each camp with nothing to tell them apart. Upstream dropped it as a default
for that reason, and this image follows: a board that will not bond fails
loudly, which is the cheaper failure to diagnose. Apply it by hand:

```sh
sudo sed -i -E 's|^#? *Privacy *=.*|Privacy = device|' /etc/bluetooth/main.conf
```

```sh
sudo reboot
```

That regex is checked against bluez 5.86's own `main.conf`: it rewrites exactly
one line, `#Privacy = off` at 98 under `[General]`, and the `Privacy Mode` prose
at 91 and 95 does not false-match. Swap `device` for `off` to reverse it. Reboot
rather than `systemctl restart bluetooth` — on this board a restart leaves the
kernel holding `hci0` and `bluetoothd` reporting "No default controller
available" until a reboot.

**Clear both halves of the bond after any change to `Privacy`, or it will not
work.** `Privacy` changes the address the stored keys were derived against, so
every existing bond stops matching and flaps with `PIN or Key Missing` until it
is re-made — including the one you are trying to fix. On the robot:

```sh
sudo robotctl pad forget <mac>
```

And on the pad: an Xbox pad keeps **one** host bond, and a half-completed attempt
leaves it holding a key this board no longer has, which fails in exactly the way
a broken board does. Holding it in pairing mode does not reliably release that
slot — pair it to a laptop once and remove it there. Then pair again.

Both halves are workarounds for the AIC8800, which is not the radio that ships.
When the real one lands, the marker, this section and `BtdPaused` in `robotctl`
all go — grep the tag to find them. `microduck_daemon`'s
`docs/robot/pair-a-gamepad.md` has the full account.

> Under A/B updates these opt-outs stop sticking: `/var` and `/etc` both live
> inside the rootfs slot, so a bundle overwrites a hand edit, and an edit made on
> one slot is not on the other. Tracked on #3.

