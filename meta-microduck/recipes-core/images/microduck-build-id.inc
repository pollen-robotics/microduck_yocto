# Build ids, shared by the shipping image and its bundle so both carry the same one.
#
# The shipping bundle's id is one second after the dev bundle's from the same run.
# CI builds both in one bitbake invocation, so both would otherwise carry the same
# DATETIME, and microduck-osupdate and the bucket key everything on that id: a dev
# board running dev build X would refuse candidate X as "already running".
# shortcut: two builds started within the same second collide, as two plain
# DATETIMEs already could; give the id a variant field if builds ever run that close.
def microduck_next_second(d):
    import calendar
    import time
    dt = d.getVar('DATETIME')
    # Task signatures are computed with a placeholder DATETIME ('12341234'); pass
    # anything that is not a 14-digit timestamp through.
    if len(dt) != 14 or not dt.isdigit():
        return dt
    t = calendar.timegm(time.strptime(dt, '%Y%m%d%H%M%S'))
    return time.strftime('%Y%m%d%H%M%S', time.gmtime(t + 1))
microduck_next_second[vardepsexclude] = "DATETIME"

MICRODUCK_SHIPPING_BUILD = "${@microduck_next_second(d)}"
MICRODUCK_SHIPPING_BUILD[vardepsexclude] = "DATETIME"
