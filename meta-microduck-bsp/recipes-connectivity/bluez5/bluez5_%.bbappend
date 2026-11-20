# glibc 2.42 made speed_t the plain rate, so btattach -S wrote garbage line
# settings and the WQ9201S never attached. Drop once bluez5 is past 5.87.
FILESEXTRAPATHS:prepend:microduck-machine := "${THISDIR}/files:"
SRC_URI:append:microduck-machine = " file://0001-btattach-Update-for-glibc-2.42-compatibility.patch"
