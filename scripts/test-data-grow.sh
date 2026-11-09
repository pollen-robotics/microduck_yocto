#!/bin/bash
# Test microduck-data-grow's decisions, before a board.
#
# Why this exists: the script rewrites the partition table of a robot's eMMC on its
# first boot. Getting "is there room", "is data the last partition" or "already
# done" wrong costs a board or its data, so each case runs here against a fake
# /sys/class/block and stub sfdisk/partx/resizepart/blockdev/resize2fs that record
# what they were asked. The real tools were run on a beta board (2026-11-09).
#
#   scripts/test-data-grow.sh
#   TEST_SH=dash scripts/test-data-grow.sh
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/meta-microduck/recipes-core/microduck-data/files/microduck-data-grow
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
# The table on disk ($STUB/table_size) and the kernel's view (the fake sysfs size)
# are kept apart, as on the board: sfdisk -N grows the table to $STUB/new_size,
# partx -g reads the table, partx -u copies it into the kernel's view unless
# $STUB/kernel_refuses exists.
for t in resize2fs udevadm; do
	printf '#!/bin/sh\necho "%s $*" >> "$LOG"\n' "$t" > "$work/bin/$t"
done
cat > "$work/bin/sfdisk" <<'EOF'
#!/bin/sh
echo "sfdisk $*" >> "$LOG"
cat >/dev/null 2>&1 || true
case " $* " in *" -N "*) cp "$STUB/new_size" "$STUB/table_size" ;; esac
EOF
cat > "$work/bin/partx" <<'EOF'
#!/bin/sh
echo "partx $*" >> "$LOG"
case " $* " in
*" -u "*) [ -e "$STUB/kernel_refuses" ] || cp "$STUB/table_size" "$KSIZE" ;;
*) echo " $(cat "$STUB/table_size")" ;;
esac
EOF
printf '#!/bin/sh\ncat "$STUB/disk_sectors"\n' > "$work/bin/blockdev"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/findmnt"
chmod +x "$work/bin/"*

pass=0; fail=0
# disk SECTORS, then partitions as NAME:NUMBER:START:SIZE, data named "data".
board() {
	case_dir=$work/$1; shift; rm -rf "$case_dir"
	STUB=$case_dir/stub SYS=$case_dir/sys LOG=$case_dir/log
	mkdir -p "$STUB" "$SYS/mmcblk0" "$case_dir/dev/disk/by-partlabel"
	echo "$1" > "$STUB/disk_sectors"; shift
	for p in "$@"; do
		IFS=: read -r name num start size <<< "$p"
		dev=$SYS/mmcblk0/mmcblk0p$num
		mkdir -p "$dev"
		echo "$num" > "$dev/partition"; echo "$start" > "$dev/start"; echo "$size" > "$dev/size"
		ln -s "$dev" "$SYS/mmcblk0p$num"
		if [ "$name" = data ]; then
			ln -s "/dev/mmcblk0p$num" "$case_dir/dev/disk/by-partlabel/data"
			KSIZE=$dev/size; echo "$size" > "$STUB/table_size"
		fi
	done
	: > "$LOG"
}
run() {
	out=$(PATH="$work/bin:$PATH" STUB=$STUB LOG=$LOG KSIZE=${KSIZE:-/dev/null} DATA_GROW_SYS=$SYS \
		DATA_GROW_PART=$(readlink "$case_dir/dev/disk/by-partlabel/data" 2>/dev/null || echo /nonexistent) \
		${TEST_SH:-sh} "$script" 2>&1); got=$?
}
# readlink -f on /dev/mmcblk0pN is the identity on a machine without that disk.
check() {  # name, then expected (or !forbidden) substrings of the log; WANT_EXIT=1 for a failure
	name=$1; shift; ok=1
	[ "$got" = "${WANT_EXIT:-0}" ] || { ok=0; echo "     exit $got, wanted ${WANT_EXIT:-0}"; }
	for w in "$@"; do
		case $w in
		!*) grep -qF -- "${w#!}" "$LOG" && { ok=0; echo "     unexpected: ${w#!}"; } ;;
		*) grep -qF -- "$w" "$LOG" || { ok=0; echo "     missing: $w"; } ;;
		esac
	done
	if [ $ok = 1 ]; then pass=$((pass + 1)); echo "ok   $name"
	else fail=$((fail + 1)); echo "FAIL $name"; sed 's/^/     | /' "$LOG"; echo "$out" | sed 's/^/     > /'; fi
}

# The new layout on a 62.5 GB eMMC, data still at its image size.
board fresh 122159104 boot:4:32768:65536 rootfs_a:5:98304:8388608 rootfs_b:6:8486912:8388608 data:7:16875520:2097152
echo 105283551 > "$STUB/new_size"
run
check "fresh flash: table grown, kernel told, then the ext4" \
	"sfdisk --quiet --relocate gpt-bak-std /dev/mmcblk0" "-N 7 /dev/mmcblk0" \
	"partx -u -n 7 /dev/mmcblk0" "udevadm trigger" "resize2fs /dev/mmcblk0p7"
[ "$(cat "$KSIZE")" = 105283551 ] && { pass=$((pass + 1)); echo "ok     ... and the kernel sees the new size"; } ||
	{ fail=$((fail + 1)); echo "FAIL   ... the kernel still sees $(cat "$KSIZE")"; }

board done 122159104 boot:4:32768:65536 rootfs_a:5:98304:8388608 rootfs_b:6:8486912:8388608 data:7:16875520:105283551
run
check "already full size: the table is left alone, only resize2fs (a no-op)" \
	"resize2fs /dev/mmcblk0p7" "!sfdisk" "!partx -u"

# What a beta's first boot left behind (2026-11-09): the table grown, the kernel not.
board half 122159104 boot:4:32768:65536 rootfs_a:5:98304:8388608 rootfs_b:6:8486912:8388608 data:7:16875520:2097152
echo 105283551 > "$STUB/new_size"; echo 105283551 > "$STUB/table_size"
run
check "table grown on an earlier boot, kernel not: the kernel is told, the ext4 grown" \
	"partx -u -n 7 /dev/mmcblk0" "resize2fs /dev/mmcblk0p7"

board refused 122159104 boot:4:32768:65536 rootfs_a:5:98304:8388608 rootfs_b:6:8486912:8388608 data:7:16875520:2097152
echo 105283551 > "$STUB/new_size"; : > "$STUB/kernel_refuses"
WANT_EXIT=1 run
WANT_EXIT=1 check "the kernel keeps the old size: the service fails, no resize2fs" "partx -u" "!resize2fs"
case $out in *"the kernel still sees"*) pass=$((pass + 1)); echo "ok     ... and says why" ;;
*) fail=$((fail + 1)); echo "FAIL   ... and says why";; esac

board small 18874368 boot:4:32768:65536 rootfs_a:5:98304:8388608 rootfs_b:6:8486912:8388608 data:7:16875520:2097152
run
check "a card barely bigger than the image (under 1 MiB spare): left alone" "!sfdisk" "!partx -u" "resize2fs /dev/mmcblk0p7"

board not-last 122159104 rootfs_a:5:98304:8388608 data:6:8486912:2097152 other:7:10584064:2097152
run
check "data not the last partition: nothing touched at all" "!sfdisk" "!partx -u" "!resize2fs"
case $out in *"is not the last partition"*) pass=$((pass + 1)); echo "ok     ... and says why" ;;
*) fail=$((fail + 1)); echo "FAIL   ... and says why";; esac

board none 122159104 rootfs_a:5:98304:8388608
run
check "no data partition: exits quietly" "!sfdisk" "!resize2fs"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
