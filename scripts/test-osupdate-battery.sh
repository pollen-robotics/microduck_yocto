#!/bin/sh
# Test microduck-osupdate's battery gate against fixed `robotctl health --json`
# output, before a board: which readings refuse an update and which do not.
#
#   sh scripts/test-osupdate-battery.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../meta-microduck/recipes-microduck/microduck-osupdate/files/microduck-osupdate
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Just the function, out of the script, which otherwise wants a board.
sed -n '/^battery_ok() {/,/^}/p' "$script" > "$tmp/fn"
[ -s "$tmp/fn" ] || { echo "battery_ok not found in $script"; exit 1; }
. "$tmp/fn"
MIN_BATTERY_PCT=30
PATH=$tmp:$PATH

# health JSON shaped like robotctl's (serde_json pretty), battery block given as $1.
fake() {
	printf '#!/bin/sh\ncat <<EOF\n{\n  "robot": {\n    "healthy": true,\n    "battery": %s,\n    "motors": null\n  }\n}\nEOF\n' "$1" > "$tmp/robotctl"
	chmod +x "$tmp/robotctl"
}
fails=0
expect() {  # ok|refused  description  battery-json
	fake "$3"
	if battery_ok; then got=ok; else got=refused; fi
	if [ "$got" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2: $got (pct '$BATTERY_PCT')"; fails=1; fi
}

expect ok      "full pack"                 '{
      "volts": 8.1,
      "percent": 93.75
    }'
expect refused "low pack"                  '{
      "volts": 6.9,
      "percent": 18.75
    }'
expect ok      "exactly the threshold"     '{
      "volts": 7.08,
      "percent": 30.0
    }'
expect refused "a hair above empty, in exponent form" '{
      "volts": 6.6000001,
      "percent": 6.25e-6
    }'
expect ok      "no reading (servos off)"   'null'
expect ok      "5 V bench supply reads 0%" '{
      "volts": 5.02,
      "percent": 0.0
    }'
rm -f "$tmp/robotctl"
expect ok      "no robotctl at all"        'unused'
exit $fails
