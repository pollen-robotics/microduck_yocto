# Pin JeffyCN/mirrors `gstreamer-rockchip` past the two mpph264enc commits we
# sent upstream as JeffyCN/mirrors#83 (merged as df71354 and bd16b2b,
# patch-identical to the pollen-robotics/gstreamer_rockship fork we built from
# before). meta-rockchip 54f31b3 still pins c37e7cf, which has neither.
#
# The first lets mpph264enc say `constrained-baseline`, without which webrtcsink's
# discovery pass finds no codec at all and every session dies on not-negotiated.
#
# The second makes it tell the truth about its level. It advertised a fixed 4.0
# whatever it encoded; 1280x720@30 is exactly level 3.1, and browsers offer
# profile-level-id=42e01f for it. With 42c028 on the wire Firefox and Chrome
# showed nothing, while a GStreamer client on the same stream was fine --
# confirmed on hardware on 2026-09-16, where forcing level=3.1 by hand restored
# the picture immediately.
#
# ebc758a is the branch tip on 2026-10-22. Upstream merged our commits on top of
# Jeffy's RGA/GPU conversion rework (a09d56b..890834c), so no merged commit
# avoids it. The tip also brings 4b68d0f: the encoder's proposed pool now
# requires max-pending+1 buffers, so rkisp stops running dry and dropping frames.
#
# Between c37e7cf and ebc758a COPYING is unchanged, so the base recipe's
# LIC_FILES_CHKSUM holds. meson_options.txt gained one option, `gpu` (an
# EGL/GLES2/GBM conversion tier, `auto`). We opt out of opengl, so it would find
# nothing anyway, but `auto` turns on whenever something drags EGL into the
# sysroot -- disable it outright rather than let the plugin change silently.
#
# Replacing SRC_URI wholesale is safe here -- unlike u-boot-rockchip -- because
# the base recipe (meta-rockchip 54f31b3) has exactly one entry, this git URL.
# Recheck that when bumping meta-rockchip, and drop this file once its SRCREV
# reaches ebc758a.
#
# The recipe file is gstreamer1.0-rockchip.bb with no version, so this append is
# named to match it exactly -- a _%.bbappend would not attach to it.

SRC_URI:microduck-machine = "git://github.com/JeffyCN/mirrors.git;protocol=https;branch=gstreamer-rockchip"
SRCREV:microduck-machine = "ebc758a13d425d34858a98dbcdb4a4bd702daa0f"
EXTRA_OEMESON:append:microduck-machine = " -Dgpu=disabled"
