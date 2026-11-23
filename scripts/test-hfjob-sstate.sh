#!/bin/bash
# Test build-hfjob.sh's sstate seed + publish, without a job.
#
#   scripts/test-hfjob-sstate.sh
#
# Runs the real in-container body (extracted from build-hfjob.sh) six times in
# the kas image, against a tmpfs /cache and a fake `kas` that adds one sstate
# object per "job". Checks the archive protocol: a legacy sstate.tar pair is
# read and replaced, the pointer is followed, an archive superseded over 30 min
# ago goes, a corrupt one is refused, and a publisher that seeded from an older
# archive leaves the one a concurrent reader took from the pointer -- the race
# that cost 11 35-minute reseeds. A last job with SAVE_SSTATE=0 must read the
# cache and leave it alone.
set -u

if [ ! -e /body.sh ]; then
	cd "$(dirname "$0")/.."
	body=$(mktemp)
	trap 'rm -f "$body"' EXIT
	awk '/^IN_CONTAINER=\$\(cat <<"IN_CONTAINER"$/{f=1;next} /^IN_CONTAINER$/{f=0} f' scripts/build-hfjob.sh > "$body"
	exec docker run --rm --user root -v "$body":/body.sh:ro -v "$PWD/kas":/src/kas:ro \
		-v "$PWD/scripts/test-hfjob-sstate.sh":/test.sh:ro --tmpfs /cache \
		--entrypoint /bin/bash ghcr.io/siemens/kas/kas:5.4 /test.sh
fi

mkdir -p /tmp/bin
printf '#!/bin/sh\necho "$JOB_ID" > "$SSTATE_DIR/obj-$JOB_ID"\n' > /tmp/bin/kas
chmod +x /tmp/bin/kas
export PATH=/tmp/bin:$PATH KAS_CMD=build KAS_MACHINE=m KAS_TARGET=none HFJOB_BUCKET=b SAVE_SSTATE=1
fail=0
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
job() { # $1 = job id; a fresh $HOME each time, like a new container
	export JOB_ID=$1 HOME=/tmp/home-$1
	rm -rf "$HOME" && mkdir -p "$HOME"
	bash /body.sh > /tmp/log-$1 2>&1
}
archives() { ls /cache/sstate-*.tar 2>/dev/null | wc -l; }
current_has() { tar -tf "/cache/sstate-$(cat /cache/sstate.current).tar" | grep -q "obj-$1"; }

# 1. Legacy pair only: read as before, then replaced by the new layout.
mkdir -p /tmp/legacy && echo old > /tmp/legacy/obj-legacy
tar -cf /cache/sstate.tar -C /tmp/legacy .
sha256sum /cache/sstate.tar | cut -d' ' -f1 > /cache/sstate.tar.sha256
job j1
check 'grep -q "sha256 verified (/cache/sstate.tar)" /tmp/log-j1' "the legacy pair is verified and used"
check '[ -f /cache/sstate.current ] && [ ! -e /cache/sstate.tar ] && [ ! -e /cache/sstate.tar.sha256 ]' "publishing replaces it with a pointer"
check 'current_has legacy && current_has j1' "the archive holds the seed and the job's own objects"
check '[ "$(sha256sum /cache/sstate-$(cat /cache/sstate.current).tar | cut -d" " -f1)" = "$(cat /cache/sstate.current)" ]' "the archive is named by its content"

# 2. The pointer is followed; the archive the job seeded from is kept.
j1sum=$(cat /cache/sstate.current)
job j2
j2sum=$(cat /cache/sstate.current)
check 'grep -q "sha256 verified (/cache/sstate-$j1sum.tar)" /tmp/log-j2' "the next job seeds through the pointer"
check 'current_has j1 && current_has j2' "its archive holds both jobs' objects"
check '[ -f /cache/sstate-$j1sum.tar ] && [ "$(archives)" = 2 ]' "it keeps the archive it seeded from"

# 3. An archive superseded more than 30 min ago is dropped.
touch -d '-2 hour' /cache/sstate-$j1sum.tar && touch -d '-1 hour' /cache/sstate-$j2sum.tar
job j3
check '[ ! -e /cache/sstate-$j1sum.tar ] && [ "$(archives)" = 2 ]' "archives superseded long ago are dropped"

# 4. A corrupt archive is refused, never built on.
echo garbage >> "/cache/sstate-$(cat /cache/sstate.current).tar"
job j4
check 'grep -q "WARNING: /cache/sstate-.* != " /tmp/log-j4 && grep -q reseeding /tmp/log-j4' "a corrupt archive is refused"

# 5. The race seen on HF (#33g): P seeded from an older archive, Q published
# since, R is reading Q's. P's publish must not delete it. j2 plays P's seed, j4 Q.
older=$j2sum q=$(cat /cache/sstate.current)
echo "$older" > /cache/sstate.current
job j5
check 'grep -q "sha256 verified (/cache/sstate-$older.tar)" /tmp/log-j5 && [ -f /cache/sstate-$q.tar ]' "an archive newer than the publisher's seed survives its publish"

# 6. A branch job (SAVE_SSTATE=0) seeds from the cache but leaves it untouched.
before=$(cat /cache/sstate.current) n=$(archives)
SAVE_SSTATE=0 job j6
check 'grep -q "sha256 verified" /tmp/log-j6 && [ "$(cat /cache/sstate.current)" = "$before" ] && [ "$(archives)" = "$n" ]' "SAVE_SSTATE=0 reads the cache and publishes nothing"

[ "$fail" = 0 ] && echo "all passed" || echo "FAILED (logs: /tmp/log-j*)"
exit "$fail"
