# Without the hooks GST_TRACERS is a silent no-op. They are in the core library,
# so both images get them; the plugin is split out for the dev image only.
PACKAGECONFIG:append:microduck = " tracer-hooks coretracers"

PACKAGE_BEFORE_PN:append:microduck = " ${PN}-tracers"
FILES:${PN}-tracers = "${libdir}/gstreamer-1.0/libgstcoretracers.so"
