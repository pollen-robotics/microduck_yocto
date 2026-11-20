#!/bin/sh
# Play a soft 500 Hz tone; the face mic must hear 500 Hz well above its neighbours
# (Goertzel), so room noise does not pass. No tone generator on the image: printf.
# The card name is face-board-v1's.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

RATE=16000 TONE=500 # RATE/TONE whole: a repeated partial period clicks

# One period of S16_LE at a fifth of full scale, as printf octal escapes.
period=$(awk -v n=$((RATE / TONE)) 'BEGIN {
	for (k = 0; k < n; k++) {
		v = int(6000 * sin(2 * 3.14159265 * k / n)); if (v < 0) v += 65536
		printf "\\%03o\\%03o", v % 256, int(v / 256)
	}
}')
# shellcheck disable=SC2059 # the format IS the data
printf "$period" > "$work/tone.raw"
for _ in 1 2 3 4 5 6 7 8 9 10; do
	cat "$work/tone.raw" "$work/tone.raw" > "$work/t" && mv "$work/t" "$work/tone.raw"
done

arecord -q -D hw:CARD=facemic -f S16_LE -c 2 -r $RATE -d 3 "$work/rec.wav" &
sleep 0.5
aplay -q -t raw -f S16_LE -c 1 -r $RATE "$work/tone.raw"
wait $!
[ -z "${MICRODUCK_TEST_ARTIFACTS:-}" ] || cp "$work/rec.wav" "$MICRODUCK_TEST_ARTIFACTS/mic.wav"

# Goertzel power, left channel, at the tone and two neighbours.
od -An -v -td2 -j 44 "$work/rec.wav" | awk -v rate=$RATE -v tone=$TONE '
	function coeff(f) { return 2 * cos(2 * 3.14159265 * f / rate) }
	BEGIN { f[1] = tone; f[2] = tone * 0.7; f[3] = tone * 1.5; for (j = 1; j <= 3; j++) c[j] = coeff(f[j]) }
	{ for (i = 1; i <= NF; i++) if (n++ % 2 == 0) for (j = 1; j <= 3; j++) {
		s = $i + c[j] * s1[j] - s2[j]; s2[j] = s1[j]; s1[j] = s }
	}
	END {
		for (j = 1; j <= 3; j++) p[j] = s1[j]^2 + s2[j]^2 - c[j] * s1[j] * s2[j]
		ratio = p[1] / ((p[2] + p[3]) / 2 + 1)
		printf "mic: %d Hz is %.0fx its neighbours (%d and %d Hz)\n", tone, ratio, f[2], f[3]
		# measured: 2-4 million with the tone, 8 without
		exit !(ratio >= 1000)
	}'
