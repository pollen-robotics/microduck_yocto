# Client = false: browsing an iPhone's protected services made BlueZ ask for
# pairing, btd refused, and BlueZ dropped the phone every few seconds. btd is a
# GATT server only.
#
# JustWorksRepairing = always: a phone that forgot the robot can pair again
# without ssh. The bond is encryption, not identity (the PIN authenticates). It is
# adapter-wide, so a spoofed bonded gamepad could re-pair: accepted, low risk.
do_install:append:microduck() {
	conf=${D}${sysconfdir}/bluetooth/main.conf
	sed -i 's/^\[GATT\]$/[GATT]\nClient = false/' "$conf"
	grep -q '^Client = false$' "$conf" || bbfatal "no [GATT] section in $conf to disable the client in"
	sed -i 's/^#\?JustWorksRepairing = .*$/JustWorksRepairing = always/' "$conf"
	grep -q '^JustWorksRepairing = always$' "$conf" || bbfatal "no JustWorksRepairing line in $conf to set to always"
}
