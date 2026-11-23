# Client = false: browsing an iPhone's protected services made BlueZ ask for
# pairing, btd refused, and BlueZ dropped the phone every few seconds. btd is a
# GATT server only.
#
# JustWorksRepairing = always: a phone that forgot the robot can pair again
# without ssh. The bond is encryption, not identity (the PIN authenticates). It is
# adapter-wide, so a spoofed bonded gamepad could re-pair: accepted, low risk.
#
# UserspaceHID = false: a classic pad's reports go through the kernel's hidp, not
# bluetoothd. In hid-nintendo's full mode (microduck-gamepads.cfg) Switch-compatible
# pads stream their IMU, which cost bluetoothd ~16 % CPU through uhid on graphite.
# LE pads are unaffected: HID over GATT stays bluetoothd's.
do_install:append:microduck() {
	conf=${D}${sysconfdir}/bluetooth/main.conf
	sed -i 's/^\[GATT\]$/[GATT]\nClient = false/' "$conf"
	grep -q '^Client = false$' "$conf" || bbfatal "no [GATT] section in $conf to disable the client in"
	sed -i 's/^#\?JustWorksRepairing = .*$/JustWorksRepairing = always/' "$conf"
	grep -q '^JustWorksRepairing = always$' "$conf" || bbfatal "no JustWorksRepairing line in $conf to set to always"
	input=${D}${sysconfdir}/bluetooth/input.conf
	sed -i 's/^#\?UserspaceHID=.*$/UserspaceHID=false/' "$input"
	grep -q '^UserspaceHID=false$' "$input" || bbfatal "no UserspaceHID line in $input to set to false"
}
