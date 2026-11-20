# webrtcbin refuses to preroll without the nicesrc/nicesink elements, which
# the default PACKAGECONFIG does not build (docs/agents/media.md).
PACKAGECONFIG:append:microduck = " gstreamer"
