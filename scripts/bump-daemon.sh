#!/bin/sh
# Pin the image to a microduck_daemon release. A bump is a commit.
#
#   scripts/bump-daemon.sh            # the newest stable release
#   scripts/bump-daemon.sh 0.16.1     # that release
#
# Renames microduck-daemon_<ver>.bb to the release's version, sets its
# SRCREV_daemon, and rewrites microduck-daemon-crates.inc from the release's
# Cargo.lock files, then leaves the diff for you to commit (README.md, "Which
# daemon the image seeds"). Version and commit come from the release's
# manifest.json, never the tag or main; the recipe says why.
set -eu
cd "$(dirname "$0")/.."

want=${1:-latest}
releases=https://github.com/pollen-robotics/microduck_daemon/releases
case "$want" in
latest) url=$releases/latest/download/manifest.json ;;
*) url=$releases/download/daemon-v${want#v}/manifest.json ;;
esac
manifest=$(curl -fsSL "$url") || {
	echo "$0: no daemon release manifest at $url" >&2
	exit 1
}
read -r version srcrev <<EOF
$(printf '%s' "$manifest" | python3 -c 'import json, sys; m = json.load(sys.stdin); print(m["version"], m["source_revision"])')
EOF
# A failing $(...) inside a heredoc trips neither set -e nor read, so an
# unparseable manifest would otherwise print empty values and exit 0.
[ -n "$version" ] && [ -n "$srcrev" ] || {
	echo "$0: no version/source_revision in $url" >&2
	exit 1
}

# The image seeds one policy set (microduck-policies_<v>.bb), and a release names
# the one it needs in scripts/seed-policies.sh. A mismatch builds fine and gives a
# robot that reports unhealthy and rolls back every update (the
# microduck-policies recipe has the story), so refuse it before anything builds.
needs=$(curl -fsSL "https://raw.githubusercontent.com/pollen-robotics/microduck_daemon/$srcrev/scripts/seed-policies.sh" \
	| sed -n 's/^POLICY_VERSION="\${POLICY_VERSION:-\([^}]*\)}"$/\1/p') || needs=
seeds=$(ls meta-microduck/recipes-microduck/microduck-policies/ | sed -n 's/^microduck-policies_\(.*\)\.bb$/\1/p')
if [ -z "$needs" ]; then
	echo "$0: WARNING: could not read POLICY_VERSION from daemon $version; not checking the policy set" >&2
elif [ "$needs" != "$seeds" ]; then
	echo "$0: daemon $version needs policy set $needs, the image seeds $seeds." >&2
	echo "  Bump microduck-policies, or name another daemon release." >&2
	exit 1
fi

# The same for the NPU runtime and the duck detector model, which the release pins
# in its Cargo.toml. These mismatches fail quietly instead: a runtime older than
# its model fails rknn_init, and mediad falls back to the CPU model -- measured at
# 128% of one core against 8.7% on the NPU, beside robotd's 50 Hz loop.
cargo=$(curl -fsSL "https://raw.githubusercontent.com/pollen-robotics/microduck_daemon/$srcrev/Cargo.toml") || cargo=
pin() { printf '%s\n' "$cargo" | awk -F'"' -v s="[workspace.metadata.$1]" -v k="$2" '/^\[/{in_s=($0==s)} in_s && $1 ~ "^"k" *= *$"{print $2; exit}'; }
recipe() { ls "$1" | sed -n "s/^$2_\(.*\)\.bb\$/\1/p"; }
check_pin() { # <what> <daemon's pin> <the image's> <recipe to bump>
	if [ -z "$2" ]; then
		echo "$0: WARNING: could not read the $1 pin from daemon $version; not checking it" >&2
	elif [ "$2" != "$3" ]; then
		echo "$0: daemon $version pins $1 $2, the image ships $3." >&2
		echo "  Bump $4, or name another daemon release." >&2
		exit 1
	fi
}
check_pin "NPU runtime" "$(pin rknpu runtime)" \
	"v$(recipe meta-microduck-bsp/recipes-bsp/librknnrt librknnrt)" librknnrt
check_pin "duck detector" "$(pin detector version)" \
	"duck-$(recipe meta-microduck/recipes-microduck/microduck-detector microduck-detector)" microduck-detector


dir=meta-microduck/recipes-microduck/microduck-daemon
old=$(ls "$dir"/microduck-daemon_*.bb)
new=$dir/microduck-daemon_$version.bb
[ "$old" = "$new" ] || git mv "$old" "$new"
sed -i "s/^SRCREV_daemon = \".*\"\$/SRCREV_daemon = \"$srcrev\"/" "$new"
grep -q "^SRCREV_daemon = \"$srcrev\"\$" "$new" || {
	echo "$0: no SRCREV_daemon line in $new to set" >&2
	exit 1
}

# What `bitbake -c update_crates microduck-daemon` writes (oe-core's
# cargo-update-recipe-crates.bbclass), without a 4.5-minute parse and fetch: one
# block per Cargo.lock, crates.io entries only. bmi088, the one git dependency,
# is SRCREV_bmi088 in the recipe and is not listed here.
locks=$(curl -fsSL "https://api.github.com/repos/pollen-robotics/microduck_daemon/git/trees/$srcrev?recursive=1" \
	| python3 -c 'import json, sys; print(" ".join(sorted((e["path"] for e in json.load(sys.stdin)["tree"] if e["path"].endswith("Cargo.lock")), key=lambda p: (p.count("/"), p))))')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for l in $locks; do
	mkdir -p "$tmp/$(dirname "$l")"
	curl -fsSL "https://raw.githubusercontent.com/pollen-robotics/microduck_daemon/$srcrev/$l" -o "$tmp/$l"
done
# The release's bmi088 commit must be SRCREV_bmi088, or do_compile fails ~50 min in.
lock_bmi088=$(cd "$tmp" && cat $locks | sed -n 's|^source = "git+https://github.com/pollen-robotics/bmi088-rs[^#]*#\([0-9a-f]*\)"$|\1|p' | sort -u)
pinned_bmi088=$(sed -n 's/^SRCREV_bmi088 = "\(.*\)"$/\1/p' "$new")
if [ -n "$lock_bmi088" ] && [ "$lock_bmi088" != "$pinned_bmi088" ]; then
	echo "$0: daemon $version locks bmi088 at $lock_bmi088, the recipe pins $pinned_bmi088." >&2
	echo "  Set SRCREV_bmi088 to the commit (not the tag object) and rerun." >&2
	exit 1
fi
(cd "$tmp" && python3 -c '
import sys, tomllib
out = "# Autogenerated with '"'"'bitbake -c update_crates microduck-daemon'"'"'\n\n"
for lock in sys.argv[1:]:
    c = [p for p in tomllib.load(open(lock, "rb"))["package"] if "crates.io" in p.get("source", "")]
    out += "# from %s\nSRC_URI += \" \\" % lock
    out += "".join("\n    crate://crates.io/%s/%s \\" % (p["name"], p["version"]) for p in c)
    out += "\n\"\n\n" + "\n".join("SRC_URI[%s-%s.sha256sum] = \"%s\"" % (p["name"], p["version"], p["checksum"]) for p in c if "checksum" in p) + "\n"
sys.stdout.write(out)
' $locks) > "$dir/microduck-daemon-crates.inc"

echo "daemon: $version at $srcrev ($want); commit the diff" >&2
