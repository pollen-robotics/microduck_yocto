# webrtcbin for webrtcsink; meson requires sctp with it. docs/agents/media.md.
PACKAGECONFIG:append:microduck = " webrtc srtp sctp"

# webrtcbin needs libnice built with its elements (libnice_%.bbappend); say so.
RDEPENDS:${PN}-webrtc:append:microduck = " libnice"
