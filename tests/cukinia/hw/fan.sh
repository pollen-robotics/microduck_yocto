#!/bin/sh
# Fan at full duty must read > 0 rpm. Its thermal zone is disabled meanwhile, or
# the governor pulls the duty back within ~1 s; all is restored on exit.
set -eu

fan=
for h in /sys/class/hwmon/hwmon*; do
	[ "$(cat "$h/name")" = pwmfan ] && fan=$h
done
[ -n "$fan" ] || { echo "no pwmfan hwmon"; exit 1; }

tz=
for c in /sys/class/thermal/thermal_zone*/cdev*; do
	[ "$(cat "$c/type" 2>/dev/null)" = pwm-fan ] && tz=$(dirname "$c")
done
[ -n "$tz" ] || { echo "no thermal zone drives pwm-fan"; exit 1; }

mode=$(cat "$tz/mode")
enable=$(cat "$fan/pwm1_enable")
pwm=$(cat "$fan/pwm1")
restore() {
	echo "$pwm" > "$fan/pwm1"
	echo "$enable" > "$fan/pwm1_enable"
	echo "$mode" > "$tz/mode"
}
trap restore EXIT
trap 'exit 1' INT TERM

echo disabled > "$tz/mode"
echo 1 > "$fan/pwm1_enable"
echo 255 > "$fan/pwm1"
sleep 2

rpm=0
for _ in 1 2 3; do
	v=$(cat "$fan/fan1_input")
	[ "$v" -gt "$rpm" ] && rpm=$v
	sleep 1
done
echo "fan: $rpm rpm at full duty ($tz)"
[ "$rpm" -gt 0 ]
