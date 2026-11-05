#!/bin/bash
# Test microduck-slot-health's verdict, before a board.
#
# Why this exists: the script decides whether RAUC keeps an update. Too strict and a
# board with a flaky radio rejects every OS update; too loose and a kernel that lost
# its wifi driver is kept on a robot nobody can reach. Both are cheap to get wrong and
# expensive to find on hardware, so each case the script distinguishes is run here
# against a fake /sys, /lib/modules and record, with robot-boot-check, uname, rauc and
# sleep stubbed. The sleep stub moves the fake uptime on instead of waiting, so the
# radio wait runs to its end without taking any time.
#
# Runs anywhere with bash, in well under a second. TEST_SH picks the shell the script
# under test runs in; dash is the stricter POSIX check:
#
#   scripts/test-slot-health.sh
#   TEST_SH=dash scripts/test-slot-health.sh
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/meta-microduck/recipes-microduck/microduck-slot-health/files/microduck-slot-health

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The stubs read what each case sets in these files.
mkdir -p "$work/bin"
# The daemon's verdict is its exit status, and only --dry-run may be asked: anything
# else would let the OS's gate hand a release to robot-rescue.
cat > "$work/bin/robot-boot-check" <<'EOF'
#!/bin/sh
[ "$*" = --dry-run ] || { echo "robot-boot-check called as: $*"; exit 99; }
echo "robot-boot-check: stub verdict $(cat "$STUB/bootcheck")"
exit "$(cat "$STUB/bootcheck")"
EOF
# Advances the fake uptime by its argument, and brings wifi up once the uptime
# reaches $STUB/wifi-at, when a case sets one.
cat > "$work/bin/sleep" <<'EOF'
#!/bin/sh
up=$(( $(cut -d. -f1 "$STUB/uptime") + $1 ))
echo "$up.00" > "$STUB/uptime"
[ ! -f "$STUB/wifi-at" ] || [ "$up" -lt "$(cat "$STUB/wifi-at")" ] || mkdir -p "$SYSROOT/class/net/wlan0"
EOF
cat > "$work/bin/uname" <<'EOF'
#!/bin/sh
cat "$STUB/kernel"
EOF
# A missing $STUB/rauc is a rauc that fails.
cat > "$work/bin/rauc" <<'EOF'
#!/bin/sh
cat "$STUB/rauc" 2>/dev/null
EOF
# The U-Boot environment, one file per variable under $STUB/env; a missing file is
# a variable fw_printenv does not have, which it reports by failing.
cat > "$work/bin/fw_printenv" <<'EOF'
#!/bin/sh
[ "$1" = -n ] || { echo "fw_printenv called as: $*"; exit 99; }
cat "$STUB/env/$2" 2>/dev/null
EOF
# microduck-osupdate: only `status` may be asked -- `check` and `apply` reach the
# network, and the health check must pass offline. Prints $STUB/osupdate; a missing
# file is a status that fails.
cat > "$work/bin/microduck-osupdate" <<'EOF'
#!/bin/sh
[ "$*" = status ] || { echo "microduck-osupdate called as: $*" >> "$STUB/forbidden"; exit 99; }
cat "$STUB/osupdate" 2>/dev/null
EOF
# Nothing may fetch anything.
cat > "$work/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$STUB/forbidden"; exit 7
EOF
# `is-active --quiet UNIT` fails for a unit listed in $STUB/inactive. Anything else
# is recorded, so a case can tell whether the board would reboot.
cat > "$work/bin/systemctl" <<'EOF'
#!/bin/sh
if [ "$1" = is-active ]; then
	[ "$2" = --quiet ] || { echo "systemctl called as: $*"; exit 99; }
	! grep -qx "$3" "$STUB/inactive" 2>/dev/null
	exit
fi
echo "$*" >> "$STUB/systemctl"
EOF
chmod +x "$work/bin/"*

pass=0; fail=0

# run NAME EXPECT(0|1) -- with the case's state already in $STUB, $SYSROOT, $MODS, $RECORD
run() {
	name=$1; want=$2
	out=$(PATH="$work/bin:$PATH" STUB=$STUB SYSROOT=$SYSROOT SLOT_HEALTH_UPTIME=$STUB/uptime \
		SLOT_HEALTH_SYS=$SYSROOT SLOT_HEALTH_MODULES=$MODS SLOT_HEALTH_RECORD=$RECORD \
		SLOT_HEALTH_BOOT_CHECK=$BOOT_CHECK SLOT_HEALTH_CMDLINE=$STUB/cmdline \
		SLOT_HEALTH_DATA=$DATA SLOT_HEALTH_MOUNTS=$STUB/mounts SLOT_HEALTH_TAINTED=$STUB/tainted \
		SLOT_HEALTH_DEV=$DEVDIR SLOT_HEALTH_OSUPDATE=$OSUPDATE \
		SLOT_HEALTH_KEYRING=$STUB/keyring.pem SLOT_HEALTH_CA_BUNDLE=$STUB/ca-certificates.crt \
		${TEST_SH:-sh} "$script" 2>&1)
	got=$?
	if [ "$got" = "$want" ]; then
		pass=$((pass + 1)); echo "ok   $name"
	else
		fail=$((fail + 1)); echo "FAIL $name (exit $got, wanted $want)"
		echo "$out" | sed 's/^/     | /'
	fi
	last=$out
}

# A fresh board: daemons up, the slot's kernel, wifi and Bluetooth, slot A as flashed.
fresh() {
	case_dir=$work/$1; rm -rf "$case_dir"; mkdir -p "$case_dir"
	STUB=$case_dir/stub SYSROOT=$case_dir/sys MODS=$case_dir/modules RECORD=$case_dir/data/radios
	mkdir -p "$STUB" "$SYSROOT/class/net" "$SYSROOT/class/bluetooth" "$MODS/6.1.99"
	echo 999.00 > "$STUB/uptime"
	echo 0 > "$STUB/bootcheck"; BOOT_CHECK=$work/bin/robot-boot-check
	echo 6.1.99 > "$STUB/kernel"
	slot A ""
	radios wifi bluetooth
	uboot A A 3 3
	# The data partition mounted read-write, a clean kernel, every unit active, and
	# the motor bus, a camera and a sound card present.
	DATA=$case_dir/datapart DEVDIR=$case_dir/dev
	mkdir -p "$DATA" "$DEVDIR/snd"
	printf '/dev/root / ext4 rw,relatime 0 0\n/dev/mmcblk1p6 %s ext4 rw,relatime 0 0\n' "$DATA" > "$STUB/mounts"
	echo 0 > "$STUB/tainted"
	: > "$DEVDIR/ttyS2"; : > "$DEVDIR/video0"; : > "$DEVDIR/snd/pcmC0D0p"
	# The update path: osupdate's status as the script prints it, a keyring with a
	# certificate, a CA bundle.
	OSUPDATE=$work/bin/microduck-osupdate
	echo '{"machine":"microduck-zero3","channel":"dev","production":false,"slot":"A","installed_build":"20261105161953","available":null,"other":null,"builds":[],"phase":"idle","progress":0,"message":"","last_result":""}' > "$STUB/osupdate"
	printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$STUB/keyring.pem"
	echo "# ca bundle" > "$STUB/ca-certificates.crt"
}
# expect_in TEXT NAME: the last run's output says TEXT.
expect_in() {
	case $last in *"$1"*) pass=$((pass + 1)); echo "ok   $2" ;;
	*) fail=$((fail + 1)); echo "FAIL $2"; echo "$last" | sed 's/^/     | /' ;; esac
}
# booted slot (rauc.slot= on the command line), BOOT_ORDER, BOOT_A_LEFT, BOOT_B_LEFT.
# A flashed card: "A A 3 3". Just after an install into B: "B 'B A' 3 3".
uboot() {
	echo "root=PARTLABEL=rootfs_x rauc.slot=$1 rootwait" > "$STUB/cmdline"
	rm -rf "$STUB/env"; mkdir -p "$STUB/env"
	echo "$2" > "$STUB/env/BOOT_ORDER"
	echo "$3" > "$STUB/env/BOOT_A_LEFT"
	echo "$4" > "$STUB/env/BOOT_B_LEFT"
	echo "setenv bootargs ...; booti \${kernel_addr_r} - \${fdt_addr_r}" > "$STUB/env/bootcmd"
	rm -f "$STUB/systemctl"
}
# expect_reboot yes|no NAME
expect_reboot() {
	if [ -f "$STUB/systemctl" ]; then got=yes; else got=no; fi
	if [ "$got" = "$1" ]; then pass=$((pass + 1)); echo "ok   $2"
	else fail=$((fail + 1)); echo "FAIL $2 (reboot asked: $got)"; echo "$last" | sed 's/^/     | /'; fi
}
# bootname, RAUC install timestamp ("" for a flashed slot). Shaped like rauc status
# on the board: the other slot first, with a timestamp of its own, so the script has
# to split the slots to pick the booted one.
slot() {
	if [ -n "$2" ]; then installed=",\"installed\":{\"timestamp\":\"$2\",\"count\":1}"; else installed=; fi
	other=B; [ "$1" = A ] || other=A
	printf '{"booted":"%s","slots":[{"rootfs.1":{"bootname":"%s","state":"inactive","slot_status":{"installed":{"timestamp":"1999-01-01T00:00:00Z","count":1}}}},{"rootfs.0":{"bootname":"%s","state":"booted","slot_status":{"bundle":{"build":"1"}%s}}}]}\n' \
		"$1" "$other" "$1" "$installed" > "$STUB/rauc"
}
radios() {
	rm -rf "$SYSROOT/class/net/"* "$SYSROOT/class/bluetooth/"*
	for r in "$@"; do
		case $r in
		wifi) mkdir -p "$SYSROOT/class/net/wlan0" ;;
		bluetooth) mkdir -p "$SYSROOT/class/bluetooth/hci0" ;;
		esac
	done
	mkdir -p "$SYSROOT/class/net/lo"
}

fresh first-boot
run "first boot with no record passes" 0
grep -qx 'A@ wifi bluetooth' "$RECORD" ||
	{ fail=$((fail + 1)); echo "FAIL first boot records its OS and radios"; }

fresh no-radios-ever
radios
run "a board that never had a radio passes (nothing to lose)" 0

fresh daemon
echo 3 > "$STUB/bootcheck"
run "a release the boot check says did not come up fails the slot" 1
case $last in *"robot-boot-check --dry-run exited 3"*) ;; *) fail=$((fail + 1)); echo "FAIL the daemon failure says why";; esac
case $last in *"stub verdict 3"*) ;; *) fail=$((fail + 1)); echo "FAIL the boot check's own words reach the journal";; esac

fresh check-errors
echo 1 > "$STUB/bootcheck"
run "a boot check that could not answer fails the slot" 1

fresh no-check
BOOT_CHECK=$work/nowhere/robot-boot-check
run "no boot check to ask fails the slot" 1

fresh kernel
rm -rf "$MODS/6.1.99"; mkdir -p "$MODS/6.1.120"
run "a kernel without its modules fails (U-Boot's fallback kernel)" 1
case $last in *"not the slot's own kernel"*) ;; *) fail=$((fail + 1)); echo "FAIL the kernel failure says why";; esac

fresh update-keeps-radios
run "flashed A passes" 0
slot B "2026-10-28T10:00:00Z"
run "an update to B with both radios passes" 0
[ "$(tail -n 1 "$RECORD")" = 'B@2026-10-28T10:00:00Z wifi bluetooth' ] ||
	{ fail=$((fail + 1)); echo "FAIL a passing update becomes the latest line"; }

fresh update-loses-wifi
run "flashed A passes" 0
slot B "2026-10-28T10:00:00Z"; radios bluetooth
run "an update to B that lost wifi fails" 1
case $last in *"wifi(present under A@, the latest OS that passed"*) ;; *) fail=$((fail + 1)); echo "FAIL the wifi failure says why";; esac
[ "$(cat "$RECORD")" = 'A@ wifi bluetooth' ] ||
	{ fail=$((fail + 1)); echo "FAIL a failed boot leaves the record alone"; }
slot A ""; radios wifi bluetooth
run "the rollback to A passes" 0

fresh update-loses-bt
run "flashed A passes" 0
slot B "2026-10-28T10:00:00Z"; radios wifi
run "an update to B that lost Bluetooth fails" 1

fresh hardware-dies
run "flashed A passes" 0
radios bluetooth
run "the same OS losing wifi passes: hardware, not an update" 0
case $last in *"warning: wifi"*) ;; *) fail=$((fail + 1)); echo "FAIL the same-OS loss is logged";; esac
grep -qx 'A@ bluetooth' "$RECORD" ||
	{ fail=$((fail + 1)); echo "FAIL the record follows the hardware down"; }
slot B "2026-10-28T10:00:00Z"
run "so the next update is not blocked by the dead chip" 0

fresh beta-without-bt
radios wifi
run "a beta board with no Bluetooth yet passes" 0
slot B "2026-10-28T10:00:00Z"
run "and its update is held only to wifi" 0

fresh radio-gained
radios wifi
run "A with wifi only passes" 0
slot B "2026-10-28T10:00:00Z"; radios wifi bluetooth
run "an update that brings Bluetooth up passes" 0
grep -qx 'B@2026-10-28T10:00:00Z wifi bluetooth' "$RECORD" ||
	{ fail=$((fail + 1)); echo "FAIL a gained radio raises the record"; }
slot A ""; radios wifi
run "a rollback to A, which passed without Bluetooth, passes" 0
slot B "2026-10-29T09:00:00Z"; radios
run "and the next update is held to A's radios, the latest that passed" 1

fresh rauc-fails
radios wifi
run "A with wifi only passes" 0
rm "$STUB/rauc"; radios
run "a boot where rauc status fails fails the slot: no update could replace it" 1
expect_in "rauc(rauc status named no booted slot" "  ... and says why"
[ "$(cat "$RECORD")" = 'A@ wifi' ] ||
	{ fail=$((fail + 1)); echo "FAIL a boot with no slot name leaves the record alone"; }

fresh reinstall
run "flashed A passes" 0
slot B "2026-10-28T10:00:00Z"
run "update to B passes" 0
slot B "2026-10-29T09:00:00Z"; radios bluetooth
run "a second update into the same slot that lost wifi still fails" 1

fresh late-wifi
run "flashed A passes" 0
slot B "2026-10-28T10:00:00Z"; radios bluetooth
echo 20.00 > "$STUB/uptime"; echo 40 > "$STUB/wifi-at"
run "an update whose wifi comes up at 40 s is waited for, and passes" 0
case $(cut -d. -f1 "$STUB/uptime") in 40) ;; *) fail=$((fail + 1)); echo "FAIL the wait stops once the radio is up (uptime $(cat "$STUB/uptime"))";; esac

fresh never-wifi
run "flashed A passes" 0
slot B "2026-10-28T10:00:00Z"; radios bluetooth
echo 20.00 > "$STUB/uptime"
run "an update whose wifi never comes up fails at 60 s" 1
case $(cut -d. -f1 "$STUB/uptime") in 60) ;; *) fail=$((fail + 1)); echo "FAIL the wait ends at the deadline (uptime $(cat "$STUB/uptime"))";; esac

fresh same-os-waits-for-nothing
run "flashed A passes" 0
radios bluetooth
echo 20.00 > "$STUB/uptime"
run "the same OS missing wifi early passes without waiting" 0
case $(cut -d. -f1 "$STUB/uptime") in 20) ;; *) fail=$((fail + 1)); echo "FAIL a radio this OS is not held to is not waited for";; esac

# Rebooting a failed slot: only the one on trial, and only towards a slot that can
# still boot.
fresh flashed-fails
echo 3 > "$STUB/bootcheck"
run "a flashed card whose daemons fail fails the slot" 1
expect_reboot no "  ... and is not rebooted: BOOT_ORDER names it alone"

fresh trial-fails
slot B "2026-10-28T10:00:00Z"; uboot B "B A" 3 0x2
echo 3 > "$STUB/bootcheck"
run "an update on trial whose daemons fail fails the slot" 1
expect_reboot yes "  ... and is rebooted, to spend its attempts"
grep -qx 'reboot --no-block' "$STUB/systemctl" ||
	{ fail=$((fail + 1)); echo "FAIL the reboot does not block the boot transaction"; }

fresh trial-loses-wifi
run "flashed A passes" 0
slot B "2026-10-28T10:00:00Z"; radios bluetooth; uboot B "B A" 3 3
run "an update on trial that lost wifi fails" 1
expect_reboot yes "  ... and is rebooted too"

fresh trial-passes
slot B "2026-10-28T10:00:00Z"; uboot B "B A" 3 0x2
run "an update on trial that is healthy passes" 0
expect_reboot no "  ... and is not rebooted"

fresh fallback-fails
slot A ""; uboot A "B A" 3 0x0
echo 3 > "$STUB/bootcheck"
run "the fallback slot after a failed trial, failing too, fails" 1
expect_reboot no "  ... and is not rebooted: it is not first in BOOT_ORDER"

fresh trial-other-spent
slot B "2026-10-28T10:00:00Z"; uboot B "B A" 0 0x2
echo 3 > "$STUB/bootcheck"
run "a trial whose other slot has no attempts left fails" 1
expect_reboot no "  ... and is not rebooted: U-Boot would reset both and boot it again"

fresh passed-then-fails
slot B "2026-10-28T10:00:00Z"; uboot B B 3 0x2
echo 3 > "$STUB/bootcheck"
run "an OS that already passed (alone in BOOT_ORDER) failing fails" 1
expect_reboot no "  ... and is not rebooted: it would loop on itself"

fresh no-env
slot B "2026-10-28T10:00:00Z"; uboot B "B A" 3 3; rm "$STUB/env/BOOT_ORDER"
echo 3 > "$STUB/bootcheck"
run "an unreadable U-Boot environment" 1
expect_reboot no "  ... means no reboot"

fresh no-cmdline-slot
slot B "2026-10-28T10:00:00Z"; uboot B "B A" 3 3; echo "root=/dev/mmcblk0p4" > "$STUB/cmdline"
echo 3 > "$STUB/bootcheck"
run "no rauc.slot= on the command line" 1
expect_reboot no "  ... means no reboot"

# The data partition.
fresh data-unmounted
printf '/dev/root / ext4 rw,relatime 0 0\n' > "$STUB/mounts"
run "the data partition not mounted fails the slot" 1
expect_in "data(" "  ... and says why"

fresh data-ro
printf '/dev/root / ext4 rw 0 0\n/dev/mmcblk1p6 %s ext4 ro,relatime 0 0\n' "$DATA" > "$STUB/mounts"
run "the data partition mounted read-only fails the slot" 1
expect_in "is mounted read-only" "  ... and says why"

fresh data-remounted
printf '/dev/mmcblk1p6 %s ext4 ro 0 0\n/dev/mmcblk1p6 %s ext4 rw 0 0\n' "$DATA" "$DATA" > "$STUB/mounts"
run "the last mount on the data partition is the one that counts" 0

fresh data-unwritable
: > "$DATA/slot-health"   # a file where the directory should be: unwritable even as root
run "a data partition nothing can be written to fails the slot" 1
expect_in "cannot write to" "  ... and says why"
[ ! -e "$DATA/slot-health/.probe" ] || { fail=$((fail + 1)); echo "FAIL the probe file is left behind"; }

fresh data-probe-cleaned
run "a healthy data partition passes" 0
[ ! -e "$DATA/slot-health/.probe" ] && { pass=$((pass + 1)); echo "ok     ... and the probe file is removed"; } ||
	{ fail=$((fail + 1)); echo "FAIL the probe file is removed"; }

# The kernel's taint.
fresh oops
echo 128 > "$STUB/tainted"
run "a kernel that oopsed during boot fails the slot" 1
expect_in "oopsed during this boot" "  ... and says why"

fresh oops-and-more
echo 4737 > "$STUB/tainted"   # D (128) with W (512), O (4096) and P (1)
run "an oops among other taints still fails" 1

fresh warn-only
echo 4609 > "$STUB/tainted"   # W, O and P, no D: what the vendor BSP leaves on every boot
run "warnings and out-of-tree modules alone pass" 0

fresh taint-garbage
echo nonsense > "$STUB/tainted"
run "an unreadable taint reads as clean" 0

# The OS services.
fresh nm-down
echo NetworkManager.service > "$STUB/inactive"
run "NetworkManager not running fails the slot" 1
expect_in "NetworkManager.service(not active)" "  ... and names it"

fresh bt-down
echo bluetooth.service > "$STUB/inactive"
run "bluetooth.service not running fails the slot" 1

fresh trial-data-fails
slot B "2026-10-28T10:00:00Z"; uboot B "B A" 3 3
printf '/dev/root / ext4 rw 0 0\n' > "$STUB/mounts"
run "an update on trial without its data partition fails" 1
expect_reboot yes "  ... and is rebooted like any other failure on trial"

# The next OS update, offline.
fresh os-status-ok
run "a board whose update path is intact passes" 0
[ ! -s "$STUB/forbidden" ] && { pass=$((pass + 1)); echo "ok     ... and nothing reached for the network"; } ||
	{ fail=$((fail + 1)); echo "FAIL the check stays offline:"; sed 's/^/     | /' "$STUB/forbidden"; }

fresh no-osupdate
OSUPDATE=$work/nowhere/microduck-osupdate
run "no microduck-osupdate fails the slot" 1
expect_in "osupdate(no " "  ... and says why"

fresh osupdate-fails
rm "$STUB/osupdate"
run "microduck-osupdate status failing fails the slot" 1
expect_in "status failed or named no machine" "  ... and says why"

fresh osupdate-no-machine
sed -i 's/"machine":"microduck-zero3"/"machine":""/' "$STUB/osupdate"
run "a status naming no machine fails the slot" 1

fresh osupdate-not-json
echo "Usage: microduck-osupdate status|check|apply" > "$STUB/osupdate"
run "a status that is not its JSON fails the slot" 1

fresh keyring-empty
: > "$STUB/keyring.pem"
run "an empty RAUC keyring fails the slot" 1
expect_in "keyring(no certificate" "  ... and says why"

fresh keyring-missing
rm "$STUB/keyring.pem"
run "a missing RAUC keyring fails the slot" 1

fresh env-unreadable
rm "$STUB/env/bootcmd"
run "an unreadable U-Boot environment fails the slot" 1
expect_in "uboot-env(" "  ... and says why"

fresh no-ca
rm "$STUB/ca-certificates.crt"
run "no CA bundle fails the slot" 1
expect_in "ca-bundle(" "  ... and says why"

fresh no-timesyncd
echo systemd-timesyncd.service > "$STUB/inactive"
run "timesyncd not running fails the slot" 1
expect_in "systemd-timesyncd.service(not active)" "  ... and names it"

# Hardware that may be unplugged: reported, never failed.
fresh no-devices
rm -f "$DEVDIR/ttyS2" "$DEVDIR/video0" "$DEVDIR/snd/pcmC0D0p"
run "no motor bus, camera or sound card still passes" 0
expect_in "warning: no motor bus" "  ... the motor bus is reported"
expect_in "warning: no camera" "  ... the camera is reported"
expect_in "warning: no sound card" "  ... the sound card is reported"

fresh all-devices
run "a board with everything plugged in" 0
case $last in *"warning: no "*) fail=$((fail + 1)); echo "FAIL   ... reports nothing missing";; *) pass=$((pass + 1)); echo "ok     ... reports nothing missing";; esac

fresh unwritable
mkdir -p "$(dirname "$RECORD")"; chmod 0555 "$(dirname "$RECORD")"
run "an unwritable record does not fail the slot" 0
chmod 0755 "$(dirname "$RECORD")"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
