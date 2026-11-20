#!/bin/sh
# One frame through mediad: fails if short, black or flat. The flashlight lights it
# (dim room, head down: mean luma 36 without, 74 with); there is no way to ask
# whether it was on, so it ends off. Prints one line (cukinia's JUnit drops newlines).
set -eu
f=$(mktemp)
trap 'rm -f "$f"; robotctl flashlight off > /dev/null 2>&1 || true' EXIT

robotctl flashlight on > /dev/null 2>&1 && sleep 1.5 || true # 1.5 s for the exposure

meta=$(robotctl frame --output "$f" 2>&1 >/dev/null) # geometry, as JSON on stderr
if [ -n "${MICRODUCK_TEST_ARTIFACTS:-}" ]; then
	cp "$f" "$MICRODUCK_TEST_ARTIFACTS/frame.uyvy"
	printf '%s\n' "$meta" > "$MICRODUCK_TEST_ARTIFACTS/frame.json"
fi
bytes=$(printf '%s' "$meta" | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
size=$(stat -c %s "$f")
printf 'frame: %s bytes, mediad says %s; ' "$size" "${bytes:-?}"
[ -n "$bytes" ] && [ "$bytes" -gt 0 ] && [ "$size" -eq "$bytes" ]

# UYVY: every second byte is luma, 16 (black) to 235.
od -An -v -tu1 -w2 "$f" | awk '
	{ s += $2; q += $2 * $2; n++ }
	END {
		mean = s / n; sd = sqrt(q / n - mean * mean)
		printf "luma mean %.0f, spread %.0f\n", mean, sd
		exit !(mean >= 40 && sd >= 8)
	}'
