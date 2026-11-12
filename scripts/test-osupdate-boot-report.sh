#!/bin/bash
# Test microduck-osupdate's boot-report: the line `duckctl os status` and the app
# show as last_result after an OS update or a switch.
#
# Why this exists: boot-report runs once per boot and decides what an update came
# to. A slot on trial that fails reboots by itself (microduck-slot-health), so its
# first boot is not the end of the story: reporting "did not pass" there, and
# forgetting the update, left a robot that had rolled back saying otherwise.
#
# Runs the real script against fake RAUC output (RAUC_JSON, which the script reads
# when set) and a fake fw_printenv, in a temporary state directory. Well under a
# second. TEST_SH picks the shell:
#
#   scripts/test-osupdate-boot-report.sh
#   TEST_SH=dash scripts/test-osupdate-boot-report.sh
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/meta-microduck/recipes-microduck/microduck-osupdate/files/microduck-osupdate

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# The U-Boot environment, one file per variable under $work/env.
cat > "$work/bin/fw_printenv" <<'EOF'
#!/bin/sh
[ "$1" = -n ] || exit 99
cat "$ENVDIR/$2" 2>/dev/null
EOF
chmod +x "$work/bin/fw_printenv"

pass=0; fail=0
STATE=$work/state ENVDIR=$work/env

# booted slot, its build, its boot_status, the other slot's build.
# boot_status as RAUC's U-Boot backend gives it: good while BOOT_ORDER names the slot
# and its BOOT_<slot>_LEFT is above zero, whether or not a boot of it passed. U-Boot
# takes one attempt before every boot, so a slot on trial reads good on its first two
# boots (0x2, 0x1) and bad on its last (0x0).
rauc() {
	other=B; [ "$1" = A ] || other=A
	RAUC_JSON=$(printf '{"compatible":"microduck-zero3","booted":"%s","slots":[{"rootfs.0":{"bootname":"%s","state":"inactive","boot_status":"good","slot_status":{"bundle":{"build":"%s"}}}},{"rootfs.1":{"bootname":"%s","state":"booted","boot_status":"%s","slot_status":{"bundle":{"build":"%s"}}}}]}' \
		"$1" "$other" "$4" "$1" "$3" "$2")
}
# BOOT_ORDER, BOOT_A_LEFT, BOOT_B_LEFT.
uboot() {
	rm -rf "$ENVDIR"; mkdir -p "$ENVDIR"
	echo "$1" > "$ENVDIR/BOOT_ORDER"; echo "$2" > "$ENVDIR/BOOT_A_LEFT"; echo "$3" > "$ENVDIR/BOOT_B_LEFT"
}
# An `os apply` of build 200 (version 1.2.0) from slot A, about to reboot into B.
applied() {
	rm -rf "$STATE"; mkdir -p "$STATE"
	printf 'VERSION=1.2.0\nBUILD=200\nFROM=A\n' > "$STATE/pending.env"
	echo rebooting > "$STATE/phase"
}
report() {
	PATH="$work/bin:$PATH" MICRODUCK_OSUPDATE_STATE=$STATE ENVDIR=$ENVDIR RAUC_JSON=$RAUC_JSON \
		${TEST_SH:-sh} "$script" boot-report >/dev/null 2>&1
}
check() {  # name, then: result=TEXT | result=none | pending=yes|no | phase=TEXT
	name=$1; shift; ok=1
	for want in "$@"; do
		case $want in
		result=none) [ ! -e "$STATE/result" ] || { ok=0; echo "     result: $(cat "$STATE/result")"; } ;;
		result=*) [ "$(cat "$STATE/result" 2>/dev/null)" = "${want#result=}" ] ||
			{ ok=0; echo "     result: $(cat "$STATE/result" 2>/dev/null), wanted ${want#result=}"; } ;;
		pending=yes) [ -f "$STATE/pending.env" ] || { ok=0; echo "     pending.env is gone"; } ;;
		pending=no) [ ! -f "$STATE/pending.env" ] || { ok=0; echo "     pending.env is still there"; } ;;
		phase=*) [ "$(cat "$STATE/phase" 2>/dev/null)" = "${want#phase=}" ] ||
			{ ok=0; echo "     phase: $(cat "$STATE/phase" 2>/dev/null)"; } ;;
		esac
	done
	if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}

applied; rauc B 200 good 100; uboot B 3 3
report
check "the new slot passed: updated" "result=updated to 1.2.0" pending=no phase=idle

applied; rauc B 200 good 100; uboot "B A" 3 0x2
report
check "the new slot failed on trial: no result yet, the update is kept" result=none pending=yes phase=idle
rauc B 200 good 100; uboot "B A" 3 0x1
report
check "  ... and failed again: still none" result=none pending=yes
rauc B 200 bad 100; uboot "B A" 3 0x0
report
check "  ... and a third time: still none" result=none pending=yes
rauc A 100 good 200; uboot "B A" 0x2 0x0
report
check "  ... then U-Boot went back to A: rolled back" \
	"result=rolled back: 1.2.0 did not come up, back on slot A" pending=no phase=idle

applied; rauc B 200 good 100; uboot "B A" 3 0x2
report
check "failed once on trial: no result yet" result=none pending=yes
rauc B 200 good 100; uboot B 3 3
report
check "  ... then passed: updated" "result=updated to 1.2.0" pending=no

applied; rauc B 200 bad 100; uboot "B A" 0 0x0
report
check "failed with the other slot spent (no going back): final" \
	"result=booted 1.2.0, but it did not pass the health check" pending=no

applied; rauc B 200 bad 100; uboot B 3 0x0
report
check "failed alone in BOOT_ORDER (not on trial): final" \
	"result=booted 1.2.0, but it did not pass the health check" pending=no

applied; rauc B 200 bad 100; rm -rf "$ENVDIR"; mkdir -p "$ENVDIR"
report
check "failed, U-Boot environment unreadable: final, nothing kept for ever" \
	"result=booted 1.2.0, but it did not pass the health check" pending=no

applied; printf 'VERSION=the flashed image\nBUILD=200\nFROM=A\nHOW=switched\n' > "$STATE/pending.env"
rauc B 200 good 100; uboot B 3 3
report
check "a switch that passed: switched" "result=switched to the flashed image" pending=no

rm -rf "$STATE"; mkdir -p "$STATE"; echo idle > "$STATE/phase"; rauc A 100 good 200; uboot A 3 3
report
check "an ordinary boot reports nothing" result=none

# A power cut during an apply, from slot A towards build 200: no pending.env, the
# phase it had reached, and the target it was applying.
cut() {
	rm -rf "$STATE"; mkdir -p "$STATE"
	printf 'VERSION=1.2.0\nBUILD=200\n' > "$STATE/target.env"
	echo "$1" > "$STATE/phase"
}
cut downloading; rauc A 100 good 150; uboot A 3 3
report
check "cut while downloading: interrupted" \
	"result=interrupted while downloading; apply again to carry on" pending=no phase=idle

cut installing; rauc A 100 good 150; uboot A 3 3
report
check "cut while RAUC was writing: interrupted" \
	"result=interrupted while installing; apply again to carry on" pending=no phase=idle

cut installing; rauc B 200 good 100; uboot B 3 3
report
check "cut after RAUC switched, the new slot passed: updated" "result=updated to 1.2.0" pending=no

cut installing; rauc B 200 good 100; uboot "B A" 3 0x2
report
check "cut after RAUC switched, the new slot failed on trial: kept" result=none pending=yes
rauc A 100 good 200; uboot "B A" 0x2 0x0
report
check "  ... then U-Boot went back to A: rolled back" \
	"result=rolled back: 1.2.0 did not come up, back on slot A" pending=no phase=idle

cut installing; rauc A 100 good 200; uboot A 3 3
report
check "cut after RAUC switched, the new slot never reached userspace: rolled back" \
	"result=rolled back: 1.2.0 did not come up, back on slot A" pending=no phase=idle

cut downloading; rauc A 100 good 150; uboot A 3 3
exec 8> "$STATE/lock"; flock 8
report
exec 8>&-
check "an apply running (the lock held): left alone" result=none phase=downloading

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
