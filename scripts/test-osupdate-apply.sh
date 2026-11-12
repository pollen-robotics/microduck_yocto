#!/bin/sh
# Test microduck-osupdate apply's bundle check: the channel manifest is unsigned,
# so a bundle whose signed build is not the manifest's BUILD must be refused
# before the other slot is touched -- no `rauc install`, its good record kept.
#
# Runs the real script against fake curl, rauc, fw_printenv and systemctl, and
# fake RAUC status (RAUC_JSON), in a temporary directory. As on a production
# board: no dev CA on this host. TEST_SH picks the shell:
#
#   sh scripts/test-osupdate-apply.sh
#   TEST_SH=dash sh scripts/test-osupdate-apply.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/meta-microduck/recipes-microduck/microduck-osupdate/files/microduck-osupdate
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
bin=$work/bin; srv=$work/srv; mkdir -p "$bin"

# curl -o FILE ... URL: serves $SRV/<path under the bucket>.
cat > "$bin/curl" <<'EOF'
#!/bin/sh
prev=; for a; do [ "$prev" = -o ] && out=$a; prev=$a; done
src=$SRV/${a#https://huggingface.co/buckets/pollen-robotics/microduck-os/resolve/}
[ -f "$src" ] || exit 22
cat "$src" > "$out"
EOF
# rauc info prints $SIGNED as the bundle's build, or refuses it when empty.
cat > "$bin/rauc" <<'EOF'
#!/bin/sh
case $1 in
info) [ -n "$SIGNED" ] || { echo "signature verification failed" >&2; exit 1; }
	printf "RAUC_MF_COMPATIBLE='microduck-zero3'\nRAUC_MF_BUILD='%s'\n" "$SIGNED" ;;
install) echo "$2" >> "$WORK/installed" ;;
*) exit 1 ;;
esac
EOF
printf '#!/bin/sh\n' > "$bin/fw_printenv"
printf '#!/bin/sh\n' > "$bin/systemctl"
printf '#!/bin/sh\n' > "$bin/sleep"
chmod +x "$bin"/*

target=20261110000000; installed=20261101000000; older=20261001000000
m=microduck-zero3
mkdir -p "$srv/os/$m/builds" "$srv/os/$m/$target"
echo bundle > "$srv/os/$m/$target/stable.raucb"
printf 'VERSION=1.2.0\nBUILD=%s\nURL=%s\nSHA256=%s\nSIZE=%s\nCOMPATIBLE=%s\n' "$target" \
	"https://huggingface.co/buckets/pollen-robotics/microduck-os/resolve/os/$m/$target/stable.raucb" \
	"$(sha256sum "$srv/os/$m/$target/stable.raucb" | cut -d' ' -f1)" \
	"$(wc -c < "$srv/os/$m/$target/stable.raucb")" "$m" > "$srv/os/$m/builds/$target.env"
# Booted A runs $installed; B holds $older, recorded good by slot-health.
RAUC_JSON=$(printf '{"compatible":"%s","booted":"A","slots":[{"rootfs.0":{"bootname":"A","state":"booted","boot_status":"good","slot_status":{"bundle":{"build":"%s"}}}},{"rootfs.1":{"bootname":"B","state":"inactive","boot_status":"bad","slot_status":{"bundle":{"build":"%s"},"installed":{"timestamp":"2026-10-01T00:00:00Z"}}}}]}' \
	"$m" "$installed" "$older")

fails=0
expect() {  # installs|refused  description  signed-build  [message]
	rm -rf "$work/state" "$work/installed"
	echo "B@2026-10-01T00:00:00Z" > "$work/good"
	PATH="$bin:$PATH" WORK=$work SRV=$srv SIGNED=$3 RAUC_JSON=$RAUC_JSON \
		MICRODUCK_OSUPDATE_STATE=$work/state MICRODUCK_SLOT_GOOD=$work/good \
		${TEST_SH:-sh} "$script" apply "$target" > /dev/null 2>&1
	msg=$(cat "$work/state/message" 2>/dev/null); ok=1
	if [ "$1" = installs ]; then
		[ -f "$work/installed" ] || ok=0
	else
		[ ! -f "$work/installed" ] || ok=0
		[ "$(cat "$work/good")" = "B@2026-10-01T00:00:00Z" ] || ok=0
		[ ! -f "$work/state/bundle.raucb.part" ] || ok=0
		[ "$msg" = "$4" ] || ok=0
	fi
	if [ $ok = 1 ]; then echo "ok   $2"; else echo "FAIL $2: message '$msg'"; fails=1; fi
}

expect installs "the bundle is the manifest's build" "$target"
expect refused "an older bundle under a newer BUILD" "$older" \
	"the bundle is build $older, but its manifest says $target"
expect refused "a bundle RAUC will not verify" "" \
	"rauc refused it: signature verification failed (this board takes production-signed stable builds only)"
exit $fails
