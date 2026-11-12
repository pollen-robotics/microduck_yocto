#!/bin/bash
# Test microduck-ssh-access's sshd.socket drop-ins under a real systemd, before a board.
#
# Why this exists: these few lines decide who can reach ssh on a robot, and the
# first version stalled every boot. BindToDevice=usb0 made sshd.socket wait for
# usb0, which appears only after basic.target, which waited for the socket: a
# 90 s device timeout, then no ssh at all. Only a running systemd shows that.
#
# Runs the recipe's own files in a Debian container with systemd as PID 1. Its
# /sys is read-only, so systemd disables device units there and the stall itself
# cannot happen: the test checks its cause instead, sshd.socket being ordered
# before sockets.target. The USB path itself still needs a board. sshd is a
# stub: what is tested is who listens. About a minute on the first run.
#
# Never --privileged: that hands the container the host's /dev, and its gettys
# then take over the host's VTs -- it killed a GNOME session on 2026-11-09.
# Instead: a private cgroup namespace, CAP_SYS_ADMIN to remount that namespace's
# cgroup2 read-write for systemd, no host devices, and the gettys masked anyway.
#
#   scripts/test-ssh-access.sh
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
files=$here/meta-microduck/recipes-microduck/microduck-ssh-access/files
name=ssh-access-test-$$
work=$(mktemp -d)
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

cp "$files"/* "$work"/
# oe-core's sshd.socket (recipes-connectivity/openssh), minus its key generation.
cat > "$work/sshd.socket" <<'EOF'
[Unit]
Conflicts=sshd.service

[Socket]
ListenStream=22
Accept=yes

[Install]
WantedBy=sockets.target
EOF
printf '[Service]\nExecStart=/usr/bin/cat\nStandardInput=socket\n' > "$work/sshd@.service"
# Laid out as the package installs it: microduck-ssh-access_1.0.bb's do_install.
cat > "$work/Dockerfile" <<'EOF'
FROM debian:trixie
RUN apt-get -qq update && apt-get -qq install -y --no-install-recommends systemd iproute2 >/dev/null
COPY sshd.socket sshd@.service microduck-ssh-wifi.path microduck-ssh-wifi.service /usr/lib/systemd/system/
COPY 10-usb-only.conf /usr/lib/systemd/system/sshd.socket.d/
COPY 30-wifi-until-reboot.conf /usr/share/microduck-ssh-access/
RUN mkdir /usr/lib/systemd/system/sys-subsystem-net-devices-usb0.device.wants \
 && ln -s ../sshd.socket /usr/lib/systemd/system/sys-subsystem-net-devices-usb0.device.wants/sshd.socket \
 && systemctl enable sshd.socket microduck-ssh-wifi.path \
 && systemctl mask getty.target console-getty.service
ENTRYPOINT ["/bin/sh", "-c", "mount -o remount,rw /sys/fs/cgroup && exec /usr/lib/systemd/systemd"]
EOF
docker build -q -t ssh-access-test "$work" >/dev/null

failed=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }
in_box() { docker exec "$name" "$@"; }
listening() { in_box ss -ltnH 'sport = :22' | awk '{print $4}' | tr '\n' ' '; }

# Boots the container (extra docker args first) and waits for multi-user.target.
boot() {
	docker rm -f "$name" >/dev/null 2>&1 || true
	docker run -d --name "$name" --cgroupns=private --cap-add SYS_ADMIN \
		--security-opt apparmor=unconfined --tmpfs /run --tmpfs /run/lock \
		"$@" ssh-access-test >/dev/null
	for _ in $(seq 30); do
		[ "$(in_box systemctl is-active multi-user.target 2>/dev/null)" = active ] && return 0
		sleep 1
	done
	in_box systemctl list-jobs --no-pager || true
	return 1
}

echo "-- shipping: 10-usb-only.conf"
if boot; then ok "boot reaches multi-user.target without usb0"; else fail "boot stalls without usb0 (jobs above)"; fi
case " $(in_box systemctl show -p Before --value sshd.socket) " in
*' sockets.target '*) fail "sshd.socket is ordered before sockets.target: on a robot, boot waits for usb0" ;;
*) ok "sshd.socket does not hold up sockets.target" ;;
esac
got=$(listening)
if [ -z "$got" ]; then ok "nothing listens on :22 before the request"; else fail "listening before the request: $got"; fi

in_box touch /run/microduck-ssh-wifi
for _ in $(seq 10); do [ -n "$(listening)" ] && break; sleep 1; done
got=$(listening)
case "$got" in
*'*:22'*) ok "every interface after the request ($got)" ;;
*) fail "after the request, listening on: '${got}', want *:22" ;;
esac
runs=$(in_box journalctl -u microduck-ssh-wifi.service --no-pager | grep -c Starting || true)
if [ "$runs" = 1 ]; then ok "the request ran once"; else fail "the request ran $runs times, want 1"; fi

echo "-- dev: the image's 20-dev-any-interface.conf"
boot -v "$files/30-wifi-until-reboot.conf:/etc/systemd/system/sshd.socket.d/20-dev-any-interface.conf:ro" \
	|| fail "dev boot stalls"
got=$(listening)
case "$got" in
*'*:22'*) ok "every interface from boot ($got)" ;;
*) fail "dev listening on: '${got}', want *:22" ;;
esac

exit "$failed"
