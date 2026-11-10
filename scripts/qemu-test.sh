#!/bin/bash
# Boot the image under qemu, log in on the serial console, run a handful of
# checks, then power off. Output lands in qemu-test.log.
#
# stdin is a FIFO so we can wait for the login prompt to actually appear before
# typing -- input sent before agetty is listening is simply lost.
#
# initcall_blacklist=rockchip_drm_init is required: rockchip_drm_init asks
# Rockchip's TF-A for the DRAM map over a vendor SIP SMC (x0=0x82000009), which is
# an undefined instruction on qemu virt (no EL3, no Rockchip firmware). The oops
# lands in kernel_init and kills init. Test-only -- the shipping kernel needs
# Rockchip DRM.
set -u
cd "$(dirname "$0")"

LOG=qemu-test.log
FIFO=$(mktemp -u /tmp/qemu-in.XXXXXX)
mkfifo "$FIFO"

rm -f "$LOG"
timeout 600 qemu-system-aarch64 \
	-M virt -cpu cortex-a55 -smp 4 -m 2048 -nographic \
	-kernel Image \
	-append "root=/dev/vda rw console=ttyAMA0 initcall_blacklist=rockchip_drm_init" \
	-drive file=rootfs.ext4,format=raw,if=none,id=hd \
	-device virtio-blk-pci,drive=hd \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	< "$FIFO" > "$LOG" 2>&1 &
QPID=$!

# Hold the FIFO open for the lifetime of the run.
exec 3> "$FIFO"

wait_for() {
	local pat=$1 limit=${2:-400} n=0
	until grep -aq "$pat" "$LOG" 2>/dev/null; do
		sleep 3
		n=$((n + 3))
		if [ $n -ge "$limit" ]; then echo "TIMEOUT waiting for: $pat"; return 1; fi
		kill -0 $QPID 2>/dev/null || { echo "qemu exited early"; return 1; }
	done
}

say() { printf '%s\n' "$1" >&3; sleep "${2:-4}"; }

wait_for "login:" || { kill $QPID 2>/dev/null; exit 1; }
say root 6

say 'echo MARK-BEGIN'
# --wait blocks until startup actually completes. Without it the answers below are
# sampled mid-boot: the first run of this script reported is-system-running
# "starting" and network-online.target "inactive" purely because it asked too
# early, which is misleading rather than merely useless.
say 'systemctl is-system-running --wait' 90
say 'systemctl --no-pager --failed'
say 'systemctl is-active NetworkManager wpa_supplicant dbus'
say 'systemctl is-enabled NetworkManager'
say 'systemctl is-active network-online.target'
say 'nmcli -t -f DEVICE,TYPE,STATE device'
say 'lsmod | grep aic'
say 'ls /lib/firmware/aic8800_fw/SDIO'
# network-online.target is inert until some unit Wants it, and nothing in the image
# does yet -- but updaterd.service will (Wants=/After=). So check it CAN be
# satisfied: NetworkManager-wait-online hanging is a known failure mode that would
# stall the updater on real hardware.
say 'systemctl start network-online.target; echo rc=$?' 45
say 'systemctl is-active network-online.target NetworkManager-wait-online.service'

# Guards against services creeping back in. poky enables rpcbind (DISTRO_FEATURES
# nfs), avahi-daemon (zeroconf), dnsmasq (NetworkManager PACKAGECONFIG) and
# busybox-syslog (VIRTUAL-RUNTIME_base-utils-syslog) by default; none belong on a
# robot.
say 'ls /etc/systemd/system/multi-user.target.wants/'

# cfg80211 falls back to restrictive built-in regulatory rules without this.
say 'ls /lib/firmware/regulatory.db'

say 'timedatectl | head -n 3'

# The daemon. updaterd is fully exercisable here -- unix socket, SO_PEERCRED, JSON-RPC.
# robotd is expected to FAIL under qemu: it opens /dev/ttyS2 for the Dynamixel bus and
# there is no such device, so Restart=always will have it retrying. That is the correct
# behaviour, not a regression.
say 'getent group robot'
say 'robotctl --version; updaterd --version'
say 'systemctl is-active updaterd robotd'
say 'ls -l /run/updaterd.sock /run/robotd.sock 2>&1'
say 'robotctl update status 2>&1 | head -n 12' 6
say 'journalctl -u robotd --no-pager -n 4 2>&1 | tail -n 4'

# M5: the Rockchip codec plugins. Under qemu they can only *register* -- there is no
# /dev/mpp_service, so encoding will fail. Registering still proves the plugin links
# against rockchip-mpp and loads, which is the part that could break at build time.
# Actual 1080p encode throughput has to be measured on the board.
say 'gst-inspect-1.0 --version 2>&1 | head -n 2'
# Name the elements rather than counting them: a count told us the plugin loads but
# not which elements exist, and `mpph264enc` turned out not to be registered -- the
# Rockchip plugin enumerates codecs from MPP at runtime, which needs a device.
say 'gst-inspect-1.0 2>/dev/null | grep -iE "rockchip|mpp"' 8
say 'gst-inspect-1.0 rockchipmpp 2>&1 | head -n 18' 8
say 'ls /dev/mpp_service /dev/rga 2>&1'

# Every GStreamer plugin mediad loads must register, or mediad fails at runtime
# with "no element ..." and the build never notices: the image installs these by
# name (packagegroup-microduck-media), not the whole plugin sets. Plugin names,
# so the list reads like that packagegroup's measurement: keep the two in step.
# A missing one prints GST-MISSING and fails this script.
GST_PLUGINS="app coreelements debugutilsbad dtls nice rockchipmpp rsrtp rswebrtc rtp rtpmanager sctp srtp video4linux2 videoconvertscale videofilter videoparsersbad videorate videotestsrc webrtc"
say "for p in $GST_PLUGINS; do gst-inspect-1.0 \$p >/dev/null 2>&1 || echo GST-MISSING \$p; done; echo GST-CHECKED" 20

# ONNX Runtime: ort dlopens the unversioned name, so that symlink must exist in the
# runtime package. robotd works without it and only fails to walk.
say 'ls -l /usr/lib/libonnxruntime.so*'
say 'echo MARK-END'
say poweroff 10

wait_for "reboot: Power down" 120 || true
kill $QPID 2>/dev/null
exec 3>&-
rm -f "$FIFO"
echo "=== done, $(wc -l < "$LOG") lines ==="

# Output lines only: the echoed command contains the words too, but as
# `GST-MISSING $p`, never followed by a plugin name.
if grep -aqE '(^|\r)GST-MISSING [a-z0-9]' "$LOG"; then
	echo "FAIL: GStreamer plugins mediad needs are missing:"
	grep -aoE 'GST-MISSING [a-z0-9]+' "$LOG" | sort -u
	exit 1
fi
grep -aqE '(^|\r)GST-CHECKED' "$LOG" || { echo "FAIL: the GStreamer plugin check never ran"; exit 1; }
