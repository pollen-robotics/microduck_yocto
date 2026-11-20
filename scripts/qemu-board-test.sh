#!/bin/bash
# Boot a build's bundle (dev or shipping) under QEMU and run the board tests on it
# (system suite only).
#
#   scripts/qemu-board-test.sh <microduck-bundle-*.raucb>
#
# Needs qemu-system-arm, squashfs-tools, e2fsprogs, fdisk; no root. ~40 s on x86.
# Exits 1 if a test fails, 2 if the image never answers ssh.
set -euo pipefail

bundle=$(realpath "${1:?usage: $0 <microduck-bundle-*.raucb>}")
here=$(cd "$(dirname "$0")/.." && pwd)
PORT=2222
BOOT_TIMEOUT=600

work=$(mktemp -d)
qemu=
# shellcheck disable=SC2329 # run by the trap
cleanup() {
	[ -z "$qemu" ] || kill "$qemu" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

image=$(unsquashfs -l "$bundle" | sed -n 's|^squashfs-root/\(.*\.rootfs\.ext4\)$|\1|p' | head -1)
[ -n "$image" ] || { echo "no *.rootfs.ext4 in $bundle" >&2; exit 2; }
# The shipping image refuses root and serves ssh on USB-C only: log in as microduck,
# and have its own unit open ssh on every interface (test-only, on the cmdline).
user=root extra=
case "$image" in
*-dev-*) ;;
*)
	user=microduck extra=" systemd.wants=microduck-ssh-wifi.service"
	printf '#!/bin/sh\necho microduck\n' > "$work/askpass" && chmod +x "$work/askpass"
	export SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force BOARD_SUDO_PASS=microduck
	;;
esac
unsquashfs -q -d "$work/b" "$bundle" "$image"
mv "$work/b/$image" "$work/rootfs.ext4"

# debugfs needs no root. /boot/Image is a symlink, which it dumps empty: take the file.
kernel=$(/sbin/debugfs -R 'ls -p /boot' "$work/rootfs.ext4" 2>/dev/null |
	awk -F/ '$3 ~ /^100/ && $6 ~ /^Image/ { print $6; exit }')
[ -n "$kernel" ] || { echo "no /boot/Image* in $image" >&2; exit 2; }
/sbin/debugfs -R "dump /boot/$kernel $work/Image" "$work/rootfs.ext4" 2>/dev/null

# Build stamp: nothing was RAUC-installed in the VM, so compare the bundle with the
# rootfs here (stamp.sh does it on a board).
bundle_build=$(unsquashfs -cat "$bundle" manifest.raucm | sed -n 's/^build=//p')
os_build=$(/sbin/debugfs -R 'cat /usr/lib/os-release' "$work/rootfs.ext4" 2>/dev/null |
	sed -n 's/^BUILD_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')
stamp=FAIL
[ -z "$bundle_build" ] || [ "$bundle_build" != "$os_build" ] || stamp=PASS
stamp_out="bundle manifest build ${bundle_build:-?}, rootfs os-release BUILD_ID ${os_build:-?}"

# A board's layout (microduck-ab.wks.in): updaterd and configd need the data partition.
/sbin/debugfs -R "rdump /var/lib/robot $work" "$work/rootfs.ext4" 2>/dev/null
/sbin/mke2fs -q -t ext4 -L data -d "$work/robot" "$work/data.ext4" 256M
# mke2fs -d keeps our uid; on the image these files are root's.
(cd "$work/robot" && find . -mindepth 1 | sed 's|^\.||') |
	awk '{ print "sif " $0 " uid 0"; print "sif " $0 " gid 0" }
		END { print "sif / uid 0"; print "sif / gid 0" }' > "$work/owners.cmd"
/sbin/debugfs -w -f "$work/owners.cmd" "$work/data.ext4" > /dev/null 2>&1

mib() { echo $(( ($(stat -c %s "$1") + 1048575) / 1048576 )); }
root_mib=$(mib "$work/rootfs.ext4")
data_mib=$(mib "$work/data.ext4")
disk=$work/disk.img
truncate -s $((1 + root_mib + 16 + data_mib + 1))M "$disk"
/sbin/sfdisk --quiet "$disk" <<EOF
label: gpt
start=1MiB, size=${root_mib}MiB, name=rootfs_a
size=16MiB, name=rootfs_b
size=${data_mib}MiB, name=data
EOF
dd if="$work/rootfs.ext4" of="$disk" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$work/data.ext4" of="$disk" bs=1M seek=$((1 + root_mib + 16)) conv=notrunc status=none
rm -f "$work/rootfs.ext4" "$work/data.ext4"

# rockchip_drm_init oopses on virt (an SMC to Rockchip's TF-A); test-only.
echo "booting $image under QEMU (~30 s without KVM)..."
qemu-system-aarch64 -M virt -cpu cortex-a55 -smp 4 -m 2048 -display none \
	-kernel "$work/Image" \
	-append "root=/dev/vda1 ro console=ttyAMA0 initcall_blacklist=rockchip_drm_init$extra" \
	-drive file="$disk",format=raw,if=none,id=hd -device virtio-blk-pci,drive=hd \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device virtio-net-pci,netdev=n0 \
	-serial file:"$work/console.log" &
qemu=$!

# A throwaway VM on loopback, new host key every boot.
export BOARD_SSH_OPTS="-p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
vm() { ssh $BOARD_SSH_OPTS -o ConnectTimeout=5 "$user@127.0.0.1" "$@"; }

waited=0
until vm true 2>/dev/null; do
	kill -0 "$qemu" 2>/dev/null || { echo "QEMU exited; console:" >&2; tail -20 "$work/console.log" >&2; exit 2; }
	[ "$waited" -lt "$BOOT_TIMEOUT" ] || { echo "no ssh after ${BOOT_TIMEOUT}s; console:" >&2; tail -20 "$work/console.log" >&2; exit 2; }
	sleep 10
	waited=$((waited + 10))
done
echo "ssh answered after ~${waited}s; waiting for the tested daemons..."
# Startup never completes in a VM (device jobs for absent hardware wait 90 s), so
# wait for the daemons cukinia.conf checks instead. Keep the two lists in step.
for _ in $(seq 60); do
	vm 'systemctl is-active updaterd configd btd NetworkManager' | grep -qvx active || break
	sleep 2
done

rc=0
touch "$work/started"
"$here/scripts/board-test.sh" 127.0.0.1 "$user" || rc=$?

# This run's folder only: an older one must not get this run's results.
out=$(find . -maxdepth 1 -name 'board-test-127.0.0.1-*' -newer "$work/started" | sort | tail -1)
if [ -n "$out" ]; then
	cp "$work/console.log" "$out/qemu-console.log"
	printf '[{"name": "Bundle build is the rootfs os-release BUILD_ID", "status": "%s", "output": "%s"}]\n' \
		"$stamp" "$stamp_out" > "$out/build.json"
	python3 "$here/scripts/board-report.py" "$out" > /dev/null || rc=1
else
	rc=1
fi
echo "[$stamp] build stamp: $stamp_out"
[ "$stamp" = PASS ] || rc=1
exit $rc
