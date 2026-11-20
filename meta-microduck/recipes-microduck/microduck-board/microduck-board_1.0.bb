SUMMARY = "Declare which electronic board this image is for, in robotd.toml"
DESCRIPTION = "Sets [board] version in /etc/robot/robotd.toml to the machine's \
board (MICRODUCK_BOARD), the declaration microduck_daemon's updater and \
robotctl health read. What provision-board.sh --board does on an Armbian board, \
done when the image is assembled."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

# The board is the machine's, so the package is too.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Nothing to install: the package is its postinst. An empty package still has to
# be created for the postinst to run.
ALLOW_EMPTY:${PN} = "1"
INHIBIT_DEFAULT_DEPS = "1"

# robotd.toml is the daemon's conffile; this edits it in place, so it must be there.
RDEPENDS:${PN} = "microduck-daemon"

# robotd refuses unknown keys and unknown board names and then will not start.
# So: declare only into a template that has a [board] table, and only a name
# the seeded robotd binary contains (else MICRODUCK_BOARD_FALLBACK, else none).
pkg_postinst:${PN}() {
	board="${MICRODUCK_BOARD}"
	fallback="${MICRODUCK_BOARD_FALLBACK}"
	cfg="$D${sysconfdir}/robot/robotd.toml"
	robotd="$D/opt/robot/daemon/current/bin/robotd"
	if [ -z "$board" ]; then
		echo "microduck-board: MICRODUCK_BOARD is empty; not declaring a board"
		exit 0
	fi
	if [ ! -f "$cfg" ] || ! grep -q '^\[board\]$' "$cfg"; then
		echo "microduck-board: $cfg has no [board] table (daemon predates it); not declaring '$board'"
		exit 0
	fi
	if [ ! -f "$robotd" ]; then
		echo "ERROR: microduck-board: no robotd at $robotd to check '$board' against" >&2
		exit 1
	fi
	if ! grep -aqF "$board" "$robotd"; then
		if [ -z "$fallback" ]; then
			echo "microduck-board: this daemon does not know the board '$board' and there is no fallback; not declaring one"
			exit 0
		fi
		echo "microduck-board: this daemon does not know the board '$board'; declaring '$fallback' instead"
		board="$fallback"
	fi
	awk -v board="$board" '
		/^\[/ { if (in_board && !done) { print "version = \"" board "\""; done = 1 } in_board = ($0 == "[board]") }
		in_board && /^#? *version *= *"/ { if (!done) { print "version = \"" board "\""; done = 1 } next }
		{ print }
		END { if (in_board && !done) print "version = \"" board "\"" }
	' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
	if ! awk '/^\[/{b=($0=="[board]")} b && /^version *= *"/' "$cfg" | grep -q "\"$board\""; then
		echo "ERROR: microduck-board: could not declare '$board' in $cfg" >&2
		exit 1
	fi
	echo "microduck-board: declared this image's board as '$board'"
}
