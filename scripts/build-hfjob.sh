#!/bin/sh
# Build on Hugging Face Jobs, billed to the pollen-robotics org.
#
#   scripts/build-hfjob.sh                                   # build the image
#   HFJOB_TARGET=linux-rockchip scripts/build-hfjob.sh       # one recipe
#   HFJOB_FLAVOR=cpu-basic scripts/build-hfjob.sh checkout   # layers+conf, no build
#   HFJOB_MACHINE=microduck-beta scripts/build-hfjob.sh      # the beta board
#   HFJOB_DAEMON_VERSION=0.16.1 scripts/build-hfjob.sh       # not the newest daemon
#   HFJOB_KAS_EXTRA=kas/cve.yml HFJOB_TARGET=microduck-image scripts/build-hfjob.sh
#                                                            # + CVE scan (kas/cve.yml)
#
# The first argument is the kas command, defaulting to `build`, the same shape
# build-local.sh uses. `checkout` is worth knowing about: it clones the layers and
# writes local.conf without compiling anything, so it validates this whole
# pipeline on cpu-basic for a fraction of a cent before cpu-performance bills by
# the minute.
#
# Why a job at all: a cold image build is hours on a workstation, and a job gets
# 32 cores and 247 GB with no -j cap.
#
# Billing is per minute of wall clock against the org balance, ~$1.90/h on
# cpu-performance. Estimated 2.5-4 h cold, 15-35 min once the bucket is warm.
# --timeout is a ceiling that stops the billing, not a reservation.
#
# The private microduck-daemon fetch needs a key, and there is no ssh-agent to
# forward into a job the way build-local.sh does. Pass one explicitly -- and
# prefer a read-only deploy key over your own, because it is held server-side
# (encrypted) for the life of the job:
#
#   HFJOB_SSH_KEY=~/.ssh/microduck_daemon_deploy scripts/build-hfjob.sh
#
# Without a key, anything fetching only public sources still builds. Start with
#
#   scripts/build-hfjob.sh linux-rockchip
#
# to fill the cache and measure the hardware before paying for a whole image.

set -eu

cd "$(dirname "$0")/.."

FLAVOR=${HFJOB_FLAVOR:-cpu-performance}
TIMEOUT=${HFJOB_TIMEOUT:-8h}
BUCKET=${HFJOB_BUCKET:-pollen-robotics/microduck-yocto-cache}
TARGET=${HFJOB_TARGET:-}
# Which board. Passed to kas as KAS_MACHINE, which overrides `machine:` in
# microduck.yml (kas/beta.yml is the same thing for a local build), and used
# below to find the deploy directory, which is named after it.
MACHINE=${HFJOB_MACHINE:-microduck-zero3}
KAS_CMD=${1:-build}
# Extra kas files composed after hfjob.yml, colon-separated, e.g. kas/cve.yml.
# Checked here: a typo would otherwise fail inside a job that is already billing.
KAS_EXTRA=${HFJOB_KAS_EXTRA:-}
for f in $(echo "$KAS_EXTRA" | tr ':' ' '); do
	case "$f" in
	kas/*) [ -f "$f" ] && continue ;;
	esac
	echo "$0: HFJOB_KAS_EXTRA: '$f' is not a file under kas/ (only kas/ is sent to the job)" >&2
	exit 1
done

# The daemon release (README.md, "Which daemon the image seeds"). Resolved here,
# so a release the image cannot seed is refused before the job bills anything.
# Its `daemon: ...` line on stderr is what CI copies into the run summary.
daemon=$(scripts/daemon-release.sh "${HFJOB_DAEMON_VERSION:-latest}")
# The bundle's RAUC version: the newest OS release (scripts/os-release.sh).
os_version=$(scripts/os-release.sh)

# The RAUC signing pair, needed only when the target is the bundle.
#
# Defaulted from KAS_BUILD_DIR so a shell that has sourced kas/local.env -- which
# is what README.md tells you to do before generating them -- needs no extra
# variable. Override either explicitly to sign with a different key.
RAUC_KEYDIR=${HFJOB_RAUC_KEYDIR:-${KAS_BUILD_DIR:-}/rauc-keys}
RAUC_KEY=${HFJOB_RAUC_KEY:-$RAUC_KEYDIR/development-1.key.pem}
RAUC_CERT=${HFJOB_RAUC_CERT:-$RAUC_KEYDIR/development-1.cert.pem}

# Fail here rather than 45 minutes into a paid job. bundle.bbclass only checks
# RAUC_KEY_FILE in do_bundle, which is the very last task, so a missing key
# currently costs a full image build before it says so.
case "$TARGET" in
*bundle*)
	for f in "$RAUC_KEY" "$RAUC_CERT"; do
		# -s, not -r: CI writes the pair from secrets, so a missing secret is an
		# empty file that -r would wave through.
		[ -s "$f" ] && [ -r "$f" ] && continue
		echo "$0: target '$TARGET' needs a signing pair and $f is empty or not readable." >&2
		echo "  Generate it once (README.md 'Signing keys')," >&2
		echo "  or point HFJOB_RAUC_KEYDIR at an existing one." >&2
		exit 1
	done
	;;
esac

# The build inputs are the local checkout, uncommitted changes included, so they
# travel as local-directory volumes: hf syncs them (incrementally)
# to the org's private jobs-artifacts bucket and mounts them read-only. Needs
# huggingface_hub >= 1.30.
#
# kas/ and our three layers are named explicitly rather than mounting the whole
# tree: kas checks the upstream layers out in-tree (see .gitignore), so a stray
# local checkout would otherwise upload gigabytes. Together they are ~2 MB.
#
# They are copied into a fresh directory first, so every job gets a bucket folder
# of its own. hf names the folder from the hostname and the directory's absolute
# path (huggingface_hub _jobs_api.py, _derive_job_volume_name), and syncs into it
# with delete=False. On GitHub the checkout path never changes, so every branch
# used to sync into the same folder and inherit whatever the others had left
# there. On 2026-10-05 a run of a branch based on main built the
# microduck-daemon_0.15.0.bb that a beta-board run had uploaded hours earlier,
# with main's crate list, and failed in do_compile (job 6ac3b2b3). A rename locally did the same
# thing in September (docs/agents/hf-jobs.md). The cost is one ~400K folder per
# job left in jobs-artifacts.
stage=$(mktemp -d "${TMPDIR:-/tmp}/hfjob-src.XXXXXX")
trap 'rm -rf "$stage"' EXIT
inputs="kas meta-microduck meta-microduck-bsp meta-microduck-distro"
cp -R $inputs "$stage"/
# The name becomes a label, which HF refuses unless it matches ^[a-zA-Z0-9_-]*$
# (run 40879162403 died on a '+'). The target may list several recipes, so
# anything else becomes one '-'. Recipes lose their microduck- prefix and the
# whole name stops at 63 characters, the usual limit for a label value: not
# confirmed for HF, and the default target is 64 without it.
name=$(printf '%s' "${TARGET:-image}" | sed 's/microduck-//g')
name=$(printf '%s' "microduck-${MACHINE#microduck-}-$name-$KAS_CMD" | tr -cs 'A-Za-z0-9_-' '-' | cut -c1-63)
set -- \
	--namespace pollen-robotics \
	--flavor "$FLAVOR" \
	--timeout "$TIMEOUT" \
	--name "$name" \
	--detach
for d in $inputs; do
	set -- "$@" -v "$stage/$d:/src/$d"
done
set -- "$@" \
	-v "hf://buckets/$BUCKET:/cache" \
	-e "HFJOB_BUCKET=$BUCKET" \
	-e "KAS_CMD=$KAS_CMD" \
	-e "KAS_MACHINE=$MACHINE"

# Appended conditionally, and each guarded: under `set -e` a bare
# `[ -n "$x" ] && set -- ...` would exit the script whenever x is empty.
if [ -n "$TARGET" ]; then
	set -- "$@" -e "KAS_TARGET=$TARGET"
fi
if [ -n "${HFJOB_TASK:-}" ]; then
	set -- "$@" -e "KAS_TASK=$HFJOB_TASK"
fi
if [ -n "$KAS_EXTRA" ]; then
	set -- "$@" -e "KAS_EXTRA=$KAS_EXTRA"
fi
for kv in $daemon MICRODUCK_OS_VERSION=$os_version; do
	set -- "$@" -e "$kv"
done
if [ -n "${HFJOB_SSH_KEY:-}" ]; then
	# base64, because $(cat key) strips the trailing newline that OpenSSH requires
	# on an ed25519 key -- which cost a build: kas picked the secret up, piped it to
	# `ssh-add -`, and got "Error loading key "(stdin)": error in libcrypto".
	set -- "$@" -s "SSH_PRIVATE_KEY_B64=$(base64 -w0 "$HFJOB_SSH_KEY")"
fi

# The signing pair, split deliberately: -s for the private key so hf treats it as
# a secret, -e for the certificate because it is public and showing up in the job
# description is useful rather than harmful.
#
# Sent only for a bundle target. There is no reason for a private key to reach a
# machine that is only building an image, and "we always pass it" is how a key
# ends up somewhere nobody remembers putting it.
case "$TARGET" in
*bundle*)
	set -- "$@" -s "RAUC_KEY_B64=$(base64 -w0 "$RAUC_KEY")"
	set -- "$@" -e "RAUC_CERT_B64=$(base64 -w0 "$RAUC_CERT")"
	;;
esac

# A quoted heredoc, not `-lc '...'`. With a single-quoted argument every apostrophe
# in the body below -- including one inside a prose comment -- silently terminates
# the string, and the remainder of the script becomes arguments to `hf` and then
# separate local commands. That is not hypothetical: this file carried nine of them
# at one point, which would have shipped a script truncated at the first comment
# that said "the uid of this image". <<"IN_CONTAINER" expands nothing and ends only
# on the terminator, so the body is free text and $VAR reaches the container intact.
IN_CONTAINER=$(cat <<"IN_CONTAINER"
set -eu

# /src is the read-only build input, and kas checks the upstream layers out beside
# meta-microduck, so work from a copy on the ephemeral disk -- under $HOME, because
# the container root is NOT writable by this image's uid 30000 and a literal /work
# dies at mkdir. $HOME, /tmp and /var/tmp are all the same 1.7 TB overlay. Plain
# -R, not -a: -a preserves ownership, which a non-root uid cannot do, and that
# would fail the job before bitbake ever started.
#
# -R still keeps the mode, and the mount serves every file read-only, so the copy
# is read-only too. Nothing wrote into the layer until update_crates, which then
# failed with "Permission denied: .../microduck-daemon-crates.inc" (job
# 6ac64022), hence the chmod.
mkdir -p "$HOME"/work && cp -R /src/. "$HOME"/work/ && chmod -R u+w "$HOME"/work
cd "$HOME"/work
. kas/hfjob.env
mkdir -p "$DL_DIR" "$SSTATE_DIR"

# The caches, measured 2026-10-05: copying the bucket's downloads/ and sstate/ in
# file by file took 53 minutes of a 64-minute job. The cost is per file, not per
# byte: sstate/ alone (16 GB, 17.4k files) still took 35 minutes. The mount reads
# one big file fast and many small ones slowly. So:
#
# - downloads/ (128 GB) is not copied. bitbake reads it on demand through
#   PREMIRRORS (kas/hfjob.yml), and a build reusing 99% of its tasks fetches
#   almost nothing.
# - sstate/ travels as ONE file, /cache/sstate.tar, unpacked at start and
#   rewritten by save(). The objects are already zstd-compressed, so the tar is
#   not compressed again.
#
# Reading sstate on demand too (SSTATE_MIRRORS) was tried, in job 6ac3abad: the
# existence check found 98% of objects through the mount, but setscene managed
# 588 of 3971 tasks in 24 minutes and then stopped moving.
#
# Everything worth keeping leaves through save(), and save() is wired to the fatal
# signals as well as EXIT. An EXIT trap alone does NOT run when the container is
# killed by --timeout or a cancel: bash dies on the signal without reaching it. That
# is the one path that would silently drop an image which had already been written.
#
# The artifacts go first because they are the irreplaceable part, and the caches
# after, because re-fetching 10 GB or rebuilding a toolchain is merely expensive.
saved=0
save() {
	if [ "$saved" = 1 ]; then
		return 0
	fi
	saved=1

	img="$KAS_BUILD_DIR"/tmp/deploy/images/"$KAS_MACHINE"
	out=/cache/deploy/"${JOB_ID:-nojobid}"
	if [ -d "$img" ]; then
		# Loud, not silent: a failed artifact copy is the whole problem this
		# function exists to prevent, so it must never scroll by as nothing.
		# Both in the condition, so set -e cannot abort save() before the
		# warning is printed and before the caches below are synced.
		# Everything except the plain .wic: 13 GB per build, mostly zeros, and
		# the .wic.zst + .wic.bmap beside it are what gets flashed
		# (microduck-image.bb says why the plain one is still built).
		copy_artifacts() {
			for f in "$img"/*; do
				case "$f" in *.wic) continue ;; esac
				cp -R "$f" "$out"/ || return 1
			done
		}
		if mkdir -p "$out" && copy_artifacts; then
			echo "artifacts: hf://buckets/$HFJOB_BUCKET/deploy/${JOB_ID:-nojobid}"
			ls -l "$out"
		else
			echo "WARNING: ARTIFACT COPY FAILED -- image built but not saved"
		fi
		# rm_work has already deleted the per-recipe work dirs, so tmp/log is
		# the only surviving record of what individual tasks did.
		if [ -d "$KAS_BUILD_DIR"/tmp/log ]; then
			cp -R "$KAS_BUILD_DIR"/tmp/log "$out"/bitbake-log || true
		fi
		# installed-package-sizes.txt is "<KiB>\tKiB\t<package>", largest first.
		bh="$KAS_BUILD_DIR"/buildhistory/images
		if [ -d "$bh" ]; then
			cp -R "$bh" "$out"/buildhistory || true
			find "$bh" -name installed-package-sizes.txt | while read -r f; do
				awk -v i="$(basename "$(dirname "$f")")" '{t+=$1} END{printf "buildhistory: %s: %d packages, %d KiB installed; largest:\n", i, NR, t}' "$f"
				head -n 10 "$f" | awk '{printf "buildhistory:   %8d KiB  %s\n", $1, $3}'
			done
		fi
	else
		echo "no deploy/images dir -- nothing to copy out"
	fi

	# Publish the caches a file at a time, writing beside the target and then
	# renaming. A rename is atomic, so a job killed mid-copy leaves a stray
	# .part file rather than a truncated sstate object -- and a truncated sstate
	# object is the dangerous kind of damage, because a *later* build reads it as
	# valid and fails somewhere unrelated.
	#
	# This is not theoretical. Two orphaned cpu-performance builds were cancelled
	# by hand on 2026-09-14 after a CI bug let their GitHub runs exit while the
	# jobs kept going; either could have been inside this loop at the time. The
	# deploy copy above needs no such care: it is per-job, nothing reads it until
	# the "artifacts:" line above says it finished, and a partial directory there
	# merely wastes space.
	#
	# Skipping names that already exist is safe and is what makes this affordable:
	# sstate and downloads are content-addressed, so a name that is present
	# already holds the same bytes. That is also why concurrent writers do not
	# corrupt each other -- only *interrupted* ones do.
	#
	# What came from the mirror is a symlink into /cache, so -type f skips it. A
	# git repo cloned from the mirror is not: the clone has a freshly named pack
	# holding the whole history, and publishing it would add another full copy of
	# the repo to the bucket (10 GB for the kernel's). So a git2 repo already in the
	# bucket is left alone. Commits fetched beyond it are refetched from upstream
	# next time, which is a small delta.
	publish() {
		from=$1
		to=$2
		[ -d "$from" ] || return 0
		mkdir -p "$to"
		find "$from" -type f | while read -r f; do
			rel=${f#"$from"/}
			dest=$to/$rel
			[ -e "$dest" ] && continue
			case "$rel" in git2/*/*)
				repo=${rel#git2/}
				[ -d "$to/git2/${repo%%/*}" ] && continue
				;;
			esac
			mkdir -p "$(dirname "$dest")"
			if cp "$f" "$dest.part" && mv -f "$dest.part" "$dest"; then
				continue
			fi
			# Leave nothing half-written behind, and say so. Silence here is how
			# a poisoned cache would reach the next build unnoticed.
			rm -f "$dest.part"
			echo "WARNING: could not publish $rel atomically"
		done
	}

	# No 2>/dev/null on these: suppressing the errors here is what made one run
	# of sstate evidence unreadable and cost an experiment.
	publish "$DL_DIR" /cache/downloads

	# The whole of SSTATE_DIR (seed plus what this build added), as one file,
	# written beside the target under this job's own name and then renamed.
	# Two jobs finishing together: the last rename wins and the other's new
	# objects are lost. They get rebuilt later; nothing is corrupted.
	#
	# Only once the seed completed. A job killed or failed mid-seed has a partial
	# SSTATE_DIR, and publishing it would replace the cache with a fragment.
	#
	# ponytail: the archive only grows (16 GB on 2026-10-05). Prune it when that
	# hurts, e.g. oe-core's scripts/sstate-cache-management.py
	# --remove-duplicated on an unpacked copy.
	#
	# Named by its own SHA-256 (sstate-<sum>.tar, computed in the same pass that
	# writes it) and never overwritten. Only then does sstate.current, a pointer
	# holding that sum, change -- one rename. A reader takes the pointer once and
	# opens the archive it names, so it always gets a matching pair. The old
	# sstate.tar + sstate.tar.sha256 were two renames; a job reading between
	# them, or while another job replaced the tar, saw a mismatch and fell back
	# to the 35-minute reseed (2026-10-06, 2026-10-15). pipefail in the command
	# substitution, or a failing tar would hide behind sha256sum's success.
	if [ "$seeded" = 1 ]; then
		part=/cache/sstate.tar.part-"${JOB_ID:-nojobid}"
		echo "sstate: publishing $(du -sh "$SSTATE_DIR" | cut -f1) at $(date -u +%T)"
		if sum=$(set -o pipefail; tar -cf - -C "$SSTATE_DIR" . | tee "$part" | sha256sum | cut -d' ' -f1) \
			&& mv -f "$part" /cache/sstate-"$sum".tar \
			&& printf '%s\n' "$sum" > /cache/sstate.current.part-"${JOB_ID:-nojobid}" \
			&& mv -f /cache/sstate.current.part-"${JOB_ID:-nojobid}" /cache/sstate.current; then
			echo "sstate: published at $(date -u +%T), sha256 $sum"
			# Drop superseded archives (and the pre-pointer pair), but keep the one
			# this job seeded from: another job started at the same time may still
			# be reading it.
			# shortcut: a job still reading an older archive than that loses it and
			# reseeds; keep the last N if jobs ever run three at a time.
			for old in /cache/sstate-*.tar /cache/sstate.tar /cache/sstate.tar.sha256; do
				case "$old" in
				/cache/sstate-"$sum".tar | /cache/sstate-"${seed_sum:-none}".tar) ;;
				*) rm -f "$old" ;;
				esac
			done
		else
			rm -f "$part" /cache/sstate.current.part-"${JOB_ID:-nojobid}"
			echo "WARNING: could not publish the sstate archive"
		fi
	else
		echo "sstate: seed did not complete, not publishing"
	fi
}

# Named handlers rather than trap 'save; exit 143' TERM -- see the heredoc note
# above; a quoted trap body would reintroduce the apostrophe hazard for no gain.
on_term() { save; exit 143; }
on_int()  { save; exit 130; }
on_hup()  { save; exit 129; }

# Only for `build`. `checkout` and `dump` fetch and compile nothing.
seeded=0
if [ "$KAS_CMD" = build ]; then
	trap on_term TERM
	trap on_int INT
	trap on_hup HUP
	trap save EXIT

	# After the traps, so a job killed mid-seed reaches save() with seeded=0 and
	# leaves the cache alone. Timestamps because these lines carry none of their
	# own, and the seed time is the number this whole arrangement is about.
	echo "sstate: seeding at $(date -u +%T)"

	# The archive is checked before the build uses it: unpacked and hashed in one
	# read (the read is the expensive part on this mount, 59 s for 17 GB), then
	# compared with the sha256 save() wrote.
	#
	# tee feeds the hasher through a fifo. Not >(sha256sum): bash 5.2 does not set
	# $! for that, so nothing could wait for the sum (tested in debian:bookworm).
	# fd 3 holds the fifo open read-write so neither open() can block, and closing
	# it is what ends the hasher's input. That holds even if tee never ran.
	#
	# The pointer is read once, so the archive and the sum it is checked against
	# always belong together (see save()). Before the first pointer exists, the
	# old sstate.tar + sstate.tar.sha256 pair is read as before; this job's
	# save() then publishes the new way and removes it.
	seed_from_archive() {
		if [ -f /cache/sstate.current ]; then
			seed_sum=$(cat /cache/sstate.current)
			archive=/cache/sstate-$seed_sum.tar
		elif [ -f /cache/sstate.tar.sha256 ]; then
			seed_sum=$(cat /cache/sstate.tar.sha256)
			archive=/cache/sstate.tar
		else
			return 1
		fi
		[ -f "$archive" ] || return 1
		fifo=$HOME/sstate.fifo
		rm -f "$fifo" && mkfifo "$fifo"
		exec 3<>"$fifo"
		# 3>&-: the hasher must not hold fd 3 itself, or its input never ends.
		sha256sum < "$fifo" > "$HOME/sstate.sum" 3>&- &
		hasher=$!
		rc=0
		(set -o pipefail; tee "$fifo" < "$archive" | tar -xf - -C "$SSTATE_DIR") || rc=$?
		exec 3>&-
		wait "$hasher" || rc=1
		rm -f "$fifo"
		[ "$rc" = 0 ] || return 1
		[ "$(cut -d' ' -f1 "$HOME/sstate.sum")" = "$seed_sum" ] && echo "sstate: sha256 verified ($archive)" && return 0
		echo "WARNING: $archive sha256 $(cut -d' ' -f1 "$HOME/sstate.sum") != $seed_sum"
		return 1
	}

	if seed_from_archive; then
		echo "sstate: archive unpacked"
	else
		# No archive yet, or one that is corrupt or would not unpack. Never build
		# on a half-trusted cache: start clean and reseed from the old per-file
		# /cache/sstate (~35 min). That leaves a complete set, so save() may
		# publish it, which also replaces a bad archive. With /cache/sstate gone
		# too, this is a cold build, which publishes a complete set as well.
		if [ -n "${archive:-}" ]; then
			echo "WARNING: not using $archive; reseeding from /cache/sstate"
			rm -rf "$SSTATE_DIR" && mkdir -p "$SSTATE_DIR"
		fi
		cp -Ru /cache/sstate/. "$SSTATE_DIR"/ || echo "WARNING: some of /cache/sstate did not copy"
	fi
	seeded=1
	echo "sstate: seeded=$seeded, $(du -sh "$SSTATE_DIR" | cut -f1) at $(date -u +%T)"
fi

# kas locates the url-less microduck_os repo by asking git for the work-tree root.
# With no repo here it falls back to the *config file* directory and then resolves
# the meta-microduck layer against kas/ rather than the tree root, so bblayers.conf
# names a path that does not exist:
#
#   INFO - Using /builder/work/kas as root for repository microduck_os
#
# git init is what makes this match a local git checkout.
git init -q .
git add -A
git -c user.email=hfjob@pollen-robotics.com -c user.name=hfjob commit -q -m snapshot

if [ -n "${SSH_PRIVATE_KEY_B64:-}" ]; then
	umask 077
	mkdir -p ~/.ssh
	# id_ed25519 is a filename ssh tries by default, so this works even if the
	# agent below is somehow not consulted.
	printf %s "$SSH_PRIVATE_KEY_B64" | base64 -d > ~/.ssh/id_ed25519
	# Guarantee the trailing newline. base64 round-trips it faithfully, but a key
	# that arrives without one is rejected by ssh-add with an opaque libcrypto
	# error rather than anything mentioning newlines. An if, not `test && echo`:
	# under set -e the latter exits the script whenever the test is false, which
	# here is the normal case.
	if [ -n "$(tail -c1 ~/.ssh/id_ed25519)" ]; then
		echo >> ~/.ssh/id_ed25519
	fi
	chmod 600 ~/.ssh/id_ed25519

	# known_hosts is not optional: ssh refuses before authenticating when it
	# cannot verify the host, which surfaces as the misleading "Could not read
	# from remote repository".
	ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null

	# An agent, not GIT_SSH_COMMAND. oe-core's BB_ENV_PASSTHROUGH_ADDITIONS carries
	# SSH_AUTH_SOCK into bitbake but NOT GIT_SSH_COMMAND, so setting the latter
	# looks load-bearing and reaches the fetcher never. This is the same mechanism
	# build-local.sh gets from kas-container --ssh-agent.
	eval "$(ssh-agent -s)" >/dev/null
	ssh-add ~/.ssh/id_ed25519

	# DO NOT expect this to work: SSH auth to GitHub does not succeed from a job.
	# The same key, byte-identical (399 bytes, matching fingerprint), offered with
	# IdentitiesOnly and no agent, authenticates from a laptop and is refused here:
	#
	#   Offering public key: /builder/.ssh/id_ed25519 ED25519 SHA256:2RTfYiDcEb...
	#   git@github.com: Permission denied (publickey).
	#
	# Not interception -- the container sees github.com's real published host key
	# (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU) on 140.82.114.3. Cause
	# unknown, and deliberately not chased further, because microduck_daemon is
	# now a *public* repo: bitbake's do_fetch fails on the ssh URL, falls through
	# to oe-core's default MIRRORS rewrite to https, and succeeds anonymously.
	#
	# So this whole block is currently unnecessary. It is kept because it is
	# correct, and if the repo goes private again it is the starting point -- but
	# expect to need an https token rather than a key, given the above. A warning,
	# not an exit: https already works, so refusing to build would be wrong.
	if git ls-remote git@github.com:pollen-robotics/microduck_daemon.git >/dev/null 2>&1; then
		echo "ssh: deploy key loaded, microduck_daemon reachable over ssh"
	else
		echo "WARNING: ssh auth to github failed; relying on the public https mirror"
	fi
fi

# The RAUC signing pair, written where microduck-bundle.bb looks for it:
# ${TOPDIR}/rauc-keys, and under kas TOPDIR is KAS_BUILD_DIR. Absent for an image
# build, which needs neither.
#
# umask before the mkdir, so the directory itself is not group-readable either --
# the job container is ours alone, but a key readable by anything that wanders
# into the image is a habit worth not forming.
if [ -n "${RAUC_KEY_B64:-}" ]; then
	umask 077
	mkdir -p "$KAS_BUILD_DIR"/rauc-keys
	printf %s "$RAUC_KEY_B64" | base64 -d > "$KAS_BUILD_DIR"/rauc-keys/development-1.key.pem
	chmod 600 "$KAS_BUILD_DIR"/rauc-keys/development-1.key.pem
	printf %s "${RAUC_CERT_B64:-}" | base64 -d > "$KAS_BUILD_DIR"/rauc-keys/development-1.cert.pem
	chmod 644 "$KAS_BUILD_DIR"/rauc-keys/development-1.cert.pem
	umask 022
	echo "rauc: signing pair installed in $KAS_BUILD_DIR/rauc-keys"
fi

# Do not let a non-zero exit skip the copy below. bitbake returns 1 merely because
# its error *counter* ended up non-zero, and a bb.error raised by a QA check bumps
# that counter without failing any task: the 2026-09-10 build ran all 7352 tasks,
# wrote the .wic, reported "all succeeded", and then set -e discarded 77 minutes of
# compute on the way out. Whether such an image is trustworthy is a judgement for
# whoever reads the log, so copy it out either way and return the real code at the
# end -- the exit status still fails the job, it just stops costing the artifacts.
rc=0
kas_files=kas/microduck.yml:kas/hfjob.yml${KAS_EXTRA:+:$KAS_EXTRA}

# Every daemon release brings its own Cargo.lock, so the crate list has to be
# regenerated from it first, or the build is missing whatever crates the release
# added. This writes microduck-daemon-crates.inc into this job's own copy of the
# layer; the build below parses the new one. For a release whose lock matches the
# committed list it rewrites the same file, and changes no task hash.
#
# Only for a target that builds the daemon: the step costs ~4.5 min even on a
# warm cache (job 6ac641f3). microduck-*, not the images alone, because
# do_build[rdeptask] builds RDEPENDS too, and microduck-board, -nfc, -face-leds,
# -tof-spidev and -data all RDEPEND on the daemon. The few microduck-* recipes
# that do not just pay the 4.5 min.
if [ "$KAS_CMD" = build ]; then
	case "${KAS_TARGET:-microduck-image}" in
	*microduck-*)
		echo "daemon: regenerating the crate list for $MICRODUCK_DAEMON_VERSION"
		kas shell "$kas_files" -c "bitbake -c update_crates microduck-daemon" || rc=$?
		;;
	esac
fi
if [ "$rc" = 0 ]; then
	kas "$KAS_CMD" "$kas_files" || rc=$?
fi

# No copy here: save() already ran it, or is about to via the EXIT trap. Doing it
# in both places is how the image gets lost -- the copy that matters is the one on
# the path that also survives a kill.
exit "$rc"
IN_CONTAINER
)

# `-c`, not `-lc`, and that one letter was a week of false ERRORs.
#
# A login shell sources ~/.bash_logout when it exits. The kas image is Debian, so
# /builder/.bash_logout is the stock one: when SHLVL is 1 -- which it is here,
# because gosu execs us directly -- it runs `clear_console -q`. There is no tty,
# so that fails. Without errexit the failure is swallowed; the script above runs
# under `set -eu`, so it becomes the shell's exit status, bash exits 1, and HF
# marks the job ERROR after every task succeeded. Every build from 2026-09-10 to
# 2026-09-18 reported this way, and wait-hfjob.sh grew a "judge on the log, not
# the status" rule to work around a cause nobody had found.
#
# Found by bisection with cpu-basic probes in the real image, once local
# reproductions kept passing (the laptop had SHLVL=4, so its .bash_logout guard never
# fires): `bash -lc 'set -eu; exit 0'` -> ERROR; `bash -c 'set -eu; exit 0'` ->
# COMPLETED, with kas resolving at /usr/local/bin on the image's default PATH. So
# nothing here needs the login environment, and dropping -l is the whole fix.
#
# Not exec'd: the EXIT trap above has to run to remove the staged copy. --detach
# returns once the job is created, after the inputs are uploaded.
hf jobs run "$@" ghcr.io/siemens/kas/kas:5.4 -- /bin/bash -c "$IN_CONTAINER"
