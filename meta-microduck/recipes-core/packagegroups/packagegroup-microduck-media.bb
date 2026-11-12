SUMMARY = "GStreamer with Rockchip hardware video codecs"
DESCRIPTION = "The media stack mediad builds its pipelines from: GStreamer core and \
plugins, the Rockchip MPP/RGA hardware codecs and their device permissions."

LICENSE = "MIT"

# PACKAGE_ARCH has to be set BEFORE inherit packagegroup, not after it.
# packagegroup.bbclass snapshots the value immediately --
#
#     PACKAGE_ARCH_EXPANDED := "${PACKAGE_ARCH}"
#     inherit_defer ${@oe.utils.ifelse(d.getVar('PACKAGE_ARCH_EXPANDED') == 'all', 'allarch', '')}
#
# -- so only a value already in place at that line keeps allarch out. Assigning it
# afterwards is silently undone: allarch.bbclass registers a RecipePreFinalise
# handler that resets PACKAGE_ARCH to "all" whenever MULTILIB_VARIANTS is empty.
# The recipe therefore stayed allarch, and oe/packagedata.py get_package_mapping()
# gates on inherits_class('allarch'), not on the PACKAGE_ARCH value:
#
#     ERROR: packagegroup-microduck-media-1.0-r0 do_package_write_rpm: An allarch
#     packagegroup shouldn't depend on packages which are dynamically renamed
#     (rockchip-mpp to librockchip-mpp1)
#
# rockchip-mpp and rockchip-librga both rename Debian-style (librockchip-mpp1,
# librga2), which an allarch group may not depend on. Six of those bb.error calls
# fail no task at all -- they only bump bitbake's error counter, so the 2026-09-10
# HF build wrote the .wic, logged "all succeeded", and still exited 1.
PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

# The plugins mediad loads, by name, not the plugins-* sets: those pulled ~190
# plugin subpackages (20.6 MiB on 2026-10-15) and, through rsvg, cairo, pango and
# taglib, ~16 MiB of rendering and font libraries a headless robot never uses --
# with their CVEs (libsoup and sqlite through -soup alone). The image also puts
# the sets' -meta packages in BAD_RECOMMENDATIONS, or each set's main package
# would pull its -meta back in: gstreamer1.0-plugins-packaging.inc
# RRECOMMENDS:${PN} += "${PN}-meta".
#
# Measured, not read off the code: the libgst*.so in mediad's /proc/<pid>/maps on
# a beta board (daemon 0.18.8, 2026-11-09), idle and then during a WebRTC session
# from an on-board `gst-launch-1.0 webrtcsrc` viewer:
#
#   idle     app coreelements debugutilsbad rockchipmpp rswebrtc rtp rtpmanager
#            video4linux2 videoconvertscale videoparsersbad videorate
#   session  + dtls nice rsrtp sctp srtp webrtc
#
# coreelements is gstreamer1.0, rs* is gstreamer1.0-plugins-rs (microduck-daemon
# RDEPENDS on it), nice is libnice (plugins-bad-webrtc RDEPENDS on it, see the
# bbappend), rockchipmpp is gstreamer1.0-rockchip. Plus two mediad creates only
# sometimes, so the measurement could miss them: videoflip (plugins-good
# videofilter) when the camera is mounted rotated, and videotestsrc when there is
# no camera. A plugin missing here fails at runtime, not at build time: when a
# pipeline changes, measure again rather than guess.
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

# udev-conf-rockchip is meta-rockchip's own 99-rockchip-permissions.rules, and
# nothing in that layer pulls it in -- the recipe is referenced by no other .bb,
# .bbappend or .conf, so an image has to name it. Without it /dev/mpp_service and
# /dev/rga arrive 0600 root:root (measured on the board 2026-09-10; /dev/dri/card0
# is root:video only because systemd-udev-rules covers DRM). robotd runs as root
# so it does not care, but the failures that causes for an unprivileged mediad are
# silent and expensive -- microduck_daemon's docs/project/media-bringup.md records
# three separate debugging rounds:
#
#   /dev/mpp_service  mpph264enc is not registered at all, and mpi_enc_test
#                     writes an empty file and exits 0
#   /dev/rga          the element exists and the pipeline starts, then
#                     "Try to use uninit rgaCtx=(nil)" and pages of blit failures
#
# The upstream rule covers both, plus mali* and the DMA heaps, all GROUP="video"
# 0660 -- a superset of the hand-rolled 99-robot-mpp.rules that setup-gstreamer.sh
# installs on the Armbian prototype, so prefer it over shipping our own copy.
# `video`, not `robot`: `robot` gates the IPC sockets we define, and a kernel
# device node is not ours to redefine. mediad.service will still need
# SupplementaryGroups=video.

# gstreamer1.0-rockchip's default PACKAGECONFIG is "mpp rga kmssrc" plus x11 when
# that DISTRO_FEATURE is set. We removed x11, so rkximagesink is not built -- which
# is correct for a headless robot. kmssrc pulls in libdrm, and until now the image
# had no DRM userspace at all.
#
# Verified under qemu: the plugin loads and registers mppjpegdec, mppvideodec and
# mppvpxalphadecodebin -- decoders only. The encoders are NOT missing; they are
# compiled in and runtime-gated. gstmpph264enc.c:
#
#     gst_mpp_h264_enc_register (GstPlugin * plugin, guint rank)
#     {
#       if (!gst_mpp_enc_supported (MPP_VIDEO_CodingAVC))
#         return FALSE;
#       return gst_element_register (plugin, "mpph264enc", rank, ...);
#     }
#
# gst_mpp_enc_supported() queries MPP, which needs /dev/mpp_service, so mpph264enc,
# mpph265enc, mppvp8enc and mppjpegenc can only appear on the board. Their absence
# in qemu says nothing about whether hardware encode works -- that measurement is
# the whole point of this milestone and it needs the hardware.
#
# Note the plugin reports Version 1.14.4 (a GStreamer 1.14-era codebase) while our
# core is 1.28.5. It builds and loads, but that gap is worth remembering if elements
# behave oddly.
#
# Deliberately absent:
#
#   rockchip-rkaiq / rockchip-rkisp -- meta-rockchip's ISP stack. The beta board
#     gets Seeed's rkaiq build and tuning file from microduck-beta-camera instead
#     (that recipe says why); the Zero 3W's IMX219 has no tuning file.
#
# webrtcsink is not listed here: it is gstreamer1.0-plugins-rs, our own recipe
# (recipes-multimedia/gstreamer), which microduck-daemon RDEPENDS on.
