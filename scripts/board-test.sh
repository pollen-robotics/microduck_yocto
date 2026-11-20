#!/bin/bash
# Run the image's functional tests (tests/cukinia) on a board, over ssh.
#
#   scripts/board-test.sh [--motion] <host> [user]
#
# user: root (dev image), or microduck with sudo (shipping image, USB-C).
# --motion also runs scripts/board-motion.py: the robot MOVES.
# Results and index.html land in ./board-test-<host>-<time>/; exits 1 on a failure.
# BOARD_SSH_OPTS is added to every ssh call.
set -euo pipefail

# shellcheck disable=SC2086,SC2029 # options split on purpose; callers expand locally
rsh() { ssh ${BOARD_SSH_OPTS:-} "$@"; }

motion=
if [ "${1:-}" = --motion ]; then
	motion=1
	shift
fi
host=${1:?usage: $0 [--motion] <host> [user]}
user=${2:-root}
here=$(cd "$(dirname "$0")/.." && pwd)

# The version meta-oe wrynose packages, pinned by hash; nothing goes into the image.
CUKINIA_VERSION=0.9.1
CUKINIA_SHA256=a4a5a2ddef979bf766fd5498444e4afabf537d8704a7eb9c17eaa316adacf99d
cukinia=${XDG_CACHE_HOME:-$HOME/.cache}/microduck/cukinia-$CUKINIA_VERSION
if ! echo "$CUKINIA_SHA256  $cukinia" | sha256sum -c --quiet > /dev/null 2>&1; then
	mkdir -p "$(dirname "$cukinia")"
	curl -fsSL -o "$cukinia.part" \
		"https://raw.githubusercontent.com/savoirfairelinux/cukinia/v$CUKINIA_VERSION/cukinia"
	echo "$CUKINIA_SHA256  $cukinia.part" | sha256sum -c --quiet
	mv "$cukinia.part" "$cukinia"
fi

remote=/tmp/microduck-tests
sudo=
[ "$user" = root ] || sudo="sudo"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -r "$here/tests/cukinia/." "$stage/"
install -m 0755 "$cukinia" "$stage/cukinia"

tar -C "$stage" -cf - . |
	rsh "$user@$host" "rm -rf $remote && mkdir $remote && tar -C $remote -xf -"
echo "running the tests on $host (about 30 s)..."
rc=0
rsh -t "$user@$host" "$sudo $remote/run.sh" || rc=$? # -t: sudo may ask for its password

out=board-test-$host-$(date +%Y%m%d-%H%M%S)
mkdir "$out"
rsh "$user@$host" "tar -C $remote/out -cf - . && rm -rf $remote" | tar -C "$out" -xmf -
# Live ToF frames: no Unix-socket client on the image, so ssh -W. ~4 s, since
# opening ssh over Wi-Fi can take 2. (timeout cannot run the rsh function.)
# shellcheck disable=SC2086
{ echo '{"jsonrpc":"2.0","id":1,"method":"tof.stream"}'; sleep 4; } |
	timeout 8 ssh ${BOARD_SSH_OPTS:-} -W /run/tofd/tof.sock "$user@$host" > "$out/tof.jsonl" 2>/dev/null || true
if [ -n "$motion" ]; then
	python3 "$here/scripts/board-motion.py" "$user@$host" "$out" || rc=1
fi
python3 "$here/scripts/board-report.py" "$out" || rc=1
exit $rc
