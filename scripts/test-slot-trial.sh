#!/bin/bash
# Test microduck-slot-trial: when a slot's trial ends, and what is remembered.
#
# Why this exists: the script decides whether U-Boot may ever leave a slot on its own.
# Wrong one way, a robot whose battery is pulled three times early in boot reverts to
# its other OS (it did, 2026-11-04); wrong the other way, an update that never comes up
# has nothing to fall back to, or `switch` refuses a slot that works. Each case runs
# against a fake command line, U-Boot environment and record, with rauc and the
# fw_* tools stubbed. The rauc JSON is the shape the beta board printed.
#
# Runs anywhere with bash, in well under a second. TEST_SH picks the shell the script
# under test runs in; dash is the stricter POSIX check:
#
#   scripts/test-slot-trial.sh
#   TEST_SH=dash scripts/test-slot-trial.sh
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/meta-microduck/recipes-microduck/microduck-slot-health/files/microduck-slot-trial

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
# A missing $STUB/rauc is a rauc that fails.
cat > "$work/bin/rauc" <<'EOF'
#!/bin/sh
[ "$*" = "status --detailed --output-format=json" ] || { echo "rauc called as: $*"; exit 99; }
cat "$STUB/rauc" 2>/dev/null
EOF
# The environment is one file per variable; only -n NAME is ever asked.
cat > "$work/bin/fw_printenv" <<'EOF'
#!/bin/sh
[ "$1" = -n ] || { echo "fw_printenv called as: $*"; exit 99; }
cat "$STUB/env/$2" 2>/dev/null || { echo "## Error: \"$2\" not defined" >&2; exit 1; }
EOF
cat > "$work/bin/fw_setenv" <<'EOF'
#!/bin/sh
[ "$#" = 2 ] || { echo "fw_setenv called as: $*"; exit 99; }
printf '%s\n' "$2" > "$STUB/env/$1"; echo "$1" >> "$STUB/writes"
EOF
chmod +x "$work/bin/"*

pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1"; echo "$last" | sed 's/^/     | /'; fi; }

run() {
	last=$(PATH="$work/bin:$PATH" STUB=$STUB SLOT_TRIAL_CMDLINE=$STUB/cmdline SLOT_TRIAL_GOOD=$GOOD \
		${TEST_SH:-sh} "$script" 2>&1)
	code=$?
}

# fresh NAME BOOTED ORDER
fresh() {
	STUB=$work/$1; GOOD=$STUB/data/good
	rm -rf "$STUB"; mkdir -p "$STUB/env"
	echo "root=PARTLABEL=rootfs_x rauc.slot=$2 rw rootwait console=ttyFIQ0" > "$STUB/cmdline"
	printf '%s\n' "$3" > "$STUB/env/BOOT_ORDER"
	booted=$2; a_ts=; b_ts=; a_status=bad; b_status=bad
}
# The JSON for the current a_ts/b_ts/*_status, booted slot first, as on the board.
rauc_json() {
	one() {  # name state status ts
		inst=; [ -z "$4" ] || inst=",\"installed\":{\"timestamp\":\"$4\",\"count\":1}"
		n=0; [ "$1" = A ] || n=1
		printf '{"rootfs.%s":{"class":"rootfs","bootname":"%s","state":"%s","boot_status":"%s","slot_status":{"bundle":{"compatible":null}%s}}}' "$n" "$1" "$2" "$3" "$inst"
	}
	if [ "$booted" = A ]; then
		s1=$(one A booted "$a_status" "$a_ts"); s2=$(one B inactive "$b_status" "$b_ts")
	else
		s1=$(one B booted "$b_status" "$b_ts"); s2=$(one A inactive "$a_status" "$a_ts")
	fi
	printf '{"compatible":"microduck-beta","booted":"%s","slots":[%s,%s]}\n' "$booted" "$s1" "$s2" > "$STUB/rauc"
}
order() { cat "$STUB/env/BOOT_ORDER"; }

# A fresh card: A flashed and good, B flashed but never booted and not in the order.
fresh flashed A "A"; a_status=good; rauc_json
run
check "fresh card: exits 0" '[ $code = 0 ]'
check "fresh card: order stays A, and is not rewritten" '[ "$(order)" = A ] && [ ! -f "$STUB/writes" ]'
check "fresh card: only A@ is known good (B never booted)" '[ "$(cat "$GOOD")" = "A@" ]'

# The 2026-11-04 board: B installed, then switched to A, which passed. Order "A B".
fresh after-switch A "A B"; b_ts=2026-10-30T13:25:07Z; a_status=good; b_status=good; rauc_json
run
check "switched-to A that passed: order collapses to A" '[ "$(order)" = A ]'
check "B, which RAUC still called good, is remembered" 'grep -qx "B@2026-10-30T13:25:07Z" "$GOOD" && grep -qx "A@" "$GOOD"'
# Then the case that hurt: A passes again on later boots; nothing changes.
a_status=good; b_status=bad; rauc_json
run
check "a later good boot of A writes no environment" '[ "$(wc -l < "$STUB/writes" | tr -d " ")" = 1 ]'
check "and B stays known good after RAUC starts calling it bad" 'grep -qx "B@2026-10-30T13:25:07Z" "$GOOD"'

# An update: from "A", RAUC installs into B and makes it primary: "B A". B passes.
fresh update-passes B "B A"; a_status=good; b_status=good; b_ts=2026-11-05T09:00:00Z; rauc_json
run
check "a new OS on trial that passes ends its trial: order B" '[ "$(order)" = B ]'
check "both OSes known good" '[ "$(sort "$GOOD" | tr "\n" " ")" = "A@ B@2026-11-05T09:00:00Z " ]'

# An update that failed: B ran out of attempts, U-Boot fell back to A, A passes.
fresh update-failed A "B A"; a_status=good; b_status=bad; b_ts=2026-11-05T09:00:00Z; rauc_json
run
check "after a failed trial, the good slot is left alone in the order" '[ "$(order)" = A ]'
check "the OS that failed its trial is not known good" '! grep -q "^B@" "$GOOD"'

# A slot rewritten by an install forgets its old OS: a stale id never vouches for it.
fresh reinstalled A "A"; a_status=good; b_ts=2026-11-05T09:00:00Z; rauc_json
mkdir -p "$(dirname "$GOOD")"; printf 'A@\nB@2026-10-30T13:25:07Z\n' > "$GOOD"
run
check "a rewritten slot's old OS is dropped from the record" '[ "$(cat "$GOOD")" = "A@" ]'

# Nothing to go on: change nothing.
fresh no-slot A "A B"; a_status=good; b_status=good; rauc_json
echo "root=PARTLABEL=rootfs_a rw" > "$STUB/cmdline"
run
check "no rauc.slot= on the command line: exit 0, order untouched" '[ $code = 0 ] && [ "$(order)" = "A B" ] && [ ! -f "$GOOD" ]'

fresh rauc-fails B "B A"
run
check "rauc status failing: non-zero, order untouched" '[ $code != 0 ] && [ "$(order)" = "B A" ]'

fresh no-order B "B A"; b_status=good; rauc_json; rm "$STUB/env/BOOT_ORDER"
run
check "no BOOT_ORDER in the environment: set to the booted slot" '[ $code = 0 ] && [ "$(order)" = B ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
