# bluetoothd must not act as a GATT client of the centrals that connect to it.
#
# BlueZ does by default ([GATT] Client = true): when a phone connects to btd, it
# also browses the phone's own GATT services. An iPhone has some that need an
# encrypted link, so BlueZ asks for security, the iPhone sends a pairing
# request, and btd -- which then ran without pairing (app-path-design.md 5.5)
# -- refused it. BlueZ then treats the failed browse as a dead link and drops the
# phone two seconds later. Measured on the beta board with an iPhone on iOS 27
# (2026-11-06, btmon): a disconnect every 4 s, each 2-3 s into the connection,
# so any call slower than that -- os.check -- never got its reply. With Client
# = false: no pairing attempt, and connections that last until the phone
# leaves. A Mac has no protected services to trip on, so it never showed this.
#
# Nothing on the robot reads a phone's services: btd is a GATT server only.
#
# A phone that forgot the robot must be able to pair with it again.
#
# Once btd requires an encrypted link, a phone bonds with the robot. When the
# owner forgets the robot in the phone's Bluetooth settings, the phone drops its
# keys and the robot keeps its own; the phone's next just-works pairing is then
# refused by BlueZ's default JustWorksRepairing = never, the link fails with
# PIN or Key Missing (0x06), and only removing the bond on the robot over ssh
# recovers it. Measured on a face-board-v1 beta with an iPhone (2026-11-09):
# refused twice under never; under always, forget-then-reconnect paired with no
# robot-side step. Again on a beta with a Pixel 4a (2026-11-12, btmon): the
# phone's re-pair replaced its existing bond and btd served it.
#
# The bond is encryption, not identity -- the PIN or the secure-mode key
# authenticates a phone (app-path-design.md 5.2) -- so for a phone always gives
# nothing away. The setting is adapter-wide, though: a device spoofing a bonded
# gamepad's address can now re-pair as that pad without pad.pair's PIN and
# window. That needs radio range and the pad's address; accepted as low risk.
do_install:append:microduck() {
	conf=${D}${sysconfdir}/bluetooth/main.conf
	sed -i 's/^\[GATT\]$/[GATT]\nClient = false/' "$conf"
	grep -q '^Client = false$' "$conf" || bbfatal "no [GATT] section in $conf to disable the client in"
	sed -i 's/^#\?JustWorksRepairing = .*$/JustWorksRepairing = always/' "$conf"
	grep -q '^JustWorksRepairing = always$' "$conf" || bbfatal "no JustWorksRepairing line in $conf to set to always"
}
