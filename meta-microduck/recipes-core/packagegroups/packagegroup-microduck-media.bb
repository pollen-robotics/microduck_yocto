SUMMARY = "GStreamer with Rockchip hardware video codecs"
DESCRIPTION = "The media stack mediad builds its pipelines from: GStreamer core and \
plugins, the Rockchip MPP/RGA hardware codecs and their device permissions."

LICENSE = "Apache-2.0"

# Before the inherit, or the group stays allarch and the build exits 1 on
# rockchip-mpp's Debian renaming (docs/agents/media.md).
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# The plugins mediad loads, measured on a board; a missing one fails only at
# runtime. How to measure again: docs/agents/media.md.
# udev-conf-rockchip: without it mpp/rga nodes are root-only and mediad fails silently.
RDEPENDS:${PN} = " \
    gstreamer1.0 \
    gstreamer1.0-plugins-base-app \
    gstreamer1.0-plugins-base-videoconvertscale \
    gstreamer1.0-plugins-base-videorate \
    gstreamer1.0-plugins-base-videotestsrc \
    gstreamer1.0-plugins-good-rtp \
    gstreamer1.0-plugins-good-rtpmanager \
    gstreamer1.0-plugins-good-video4linux2 \
    gstreamer1.0-plugins-good-videofilter \
    gstreamer1.0-plugins-bad-debugutilsbad \
    gstreamer1.0-plugins-bad-dtls \
    gstreamer1.0-plugins-bad-sctp \
    gstreamer1.0-plugins-bad-srtp \
    gstreamer1.0-plugins-bad-videoparsersbad \
    gstreamer1.0-plugins-bad-webrtc \
    gstreamer1.0-rockchip \
    rockchip-mpp \
    rockchip-librga \
    udev-conf-rockchip \
    v4l-utils \
"
