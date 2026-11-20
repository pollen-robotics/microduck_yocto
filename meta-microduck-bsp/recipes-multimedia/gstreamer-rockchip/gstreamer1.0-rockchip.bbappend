# Past our two mpph264enc fixes, without which browsers get no video
# (docs/agents/media.md). Replacing SRC_URI is safe only while the base recipe
# has this one git entry; drop the file once meta-rockchip reaches ebc758a.
SRC_URI:microduck-machine = "git://github.com/JeffyCN/mirrors.git;protocol=https;branch=gstreamer-rockchip"
SRCREV:microduck-machine = "ebc758a13d425d34858a98dbcdb4a4bd702daa0f"
# `auto` would turn on whenever something brings EGL into the sysroot.
EXTRA_OEMESON:append:microduck-machine = " -Dgpu=disabled"
