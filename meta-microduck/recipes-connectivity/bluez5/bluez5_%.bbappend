# bluetoothd must not act as a GATT client of the centrals that connect to it.
#
# BlueZ does by default ([GATT] Client = true): when a phone connects to btd, it
# also browses the phone's own GATT services. An iPhone has some that need an
# encrypted link, so BlueZ asks for security, the iPhone sends a pairing
# request, and btd -- which runs without pairing (app-path-design.md 5.5) --
# refuses it. BlueZ then treats the failed browse as a dead link and drops the
# phone two seconds later. Measured on the beta board with an iPhone on iOS 27
# (2026-11-06, btmon): a disconnect every 4 s, each 2-3 s into the connection,
# so any call slower than that -- os.check -- never got its reply. With Client
# = false: no pairing attempt, and connections that last until the phone
# leaves. A Mac has no protected services to trip on, so it never showed this.
#
# Nothing on the robot reads a phone's services: btd is a GATT server only.
do_install:append:microduck() {
	conf=${D}${sysconfdir}/bluetooth/main.conf
	sed -i 's/^\[GATT\]$/[GATT]\nClient = false/' "$conf"
	grep -q '^Client = false$' "$conf" || bbfatal "no [GATT] section in $conf to disable the client in"
}
