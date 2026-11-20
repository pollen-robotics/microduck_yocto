# The media stack (`packagegroup-microduck-media`)

What the image installs for `mediad`, and how to check it is still enough.

## Only the plugins mediad loads

The image lists plugins by name, not the `plugins-*` sets. The sets pulled
~190 plugin packages (20.6 MiB, 2026-10-15) plus ~16 MiB of rsvg, cairo,
pango and taglib a headless robot never uses, with their CVEs (libsoup and
sqlite through `-soup` alone). `microduck-image.bb` also puts the sets' `-meta`
packages in `BAD_RECOMMENDATIONS`: each set's main package RRECOMMENDS its
`-meta` (`gstreamer1.0-plugins-packaging.inc`), which would bring them all back.

A missing plugin fails at runtime, not at build time. **When a pipeline
changes, measure again**: read the `libgst*.so` in mediad's `/proc/<pid>/maps`
on a beta board, idle and then during a WebRTC session (an on-board
`gst-launch-1.0 webrtcsrc` viewer is enough). Daemon 0.18.8, 2026-11-09:

```
idle     app coreelements debugutilsbad rockchipmpp rswebrtc rtp rtpmanager
         video4linux2 videoconvertscale videoparsersbad videorate
session  + dtls nice rsrtp sctp srtp webrtc
```

`coreelements` is `gstreamer1.0`, `rs*` is `gstreamer1.0-plugins-rs` (the
daemon RDEPENDS on it), `nice` is libnice (through plugins-bad-webrtc),
`rockchipmpp` is `gstreamer1.0-rockchip`. Two more that mediad creates only
sometimes, so a measurement can miss them: `videoflip` (camera mounted
rotated) and `videotestsrc` (no camera). Then add the plugin name to the list
in `scripts/qemu-test.sh` too.

## Device permissions: `udev-conf-rockchip`

meta-rockchip's `99-rockchip-permissions.rules`, which nothing in that layer
pulls in. Without it `/dev/mpp_service` and `/dev/rga` are `0600 root:root`
(measured 2026-09-10) and an unprivileged mediad fails silently:

- no `/dev/mpp_service`: `mpph264enc` is not registered at all, and
  `mpi_enc_test` writes an empty file and exits 0;
- no `/dev/rga`: the pipeline starts, then "Try to use uninit rgaCtx=(nil)" and
  pages of blit failures.

The rule makes them (and the DMA heaps) `video` 0660, a superset of the
Armbian prototype's hand-rolled `99-robot-mpp.rules`. `video`, not `robot`:
`robot` gates our IPC sockets, a kernel device node is not ours to redefine.

## gstreamer1.0-rockchip

- The MPP *encoders* register only if MPP answers, which needs
  `/dev/mpp_service`: under qemu the plugin shows decoders only, and that says
  nothing about hardware encode. Test encodes on the board, with the real camera.
- The plugin reports version 1.14.4 against a 1.28 core. It builds and loads;
  remember the gap if elements behave oddly.
- No x11 in the distro, so no `rkximagesink`; `kmssrc` brings libdrm.
- `rockchip-rkaiq`/`rkisp` stay out: the beta gets Seeed's rkaiq and tuning
  from `microduck-beta-camera`, and the Zero 3W's IMX219 has no tuning file.

## WebRTC: what oe-core leaves out

Each of these builds and loads fine and fails only when a pipeline starts.

- **webrtcbin** (plugins-bad): oe-core's default `PACKAGECONFIG` has no
  `webrtc`, so webrtcsink fails with "no element webrtcbin". `srtp` comes with
  it (media encryption), and meson refuses `webrtc` without `sctp` (data
  channels, which mediad's `control` and `teleop` use).
- **libnice's GStreamer elements**: webrtcbin looks up the `nicesrc`/`nicesink`
  factories before it prerolls, and fails with "libnice elements are not
  available" (measured 2026-09-10). meta-oe's libnice defaults to
  `-Dgstreamer=disabled`, and the library alone arrived only as a shlib
  dependency, so nothing noticed. Its `gstreamer` option puts the plugin in
  the libnice package (there is no `gstreamer1.0-nice` in meta-oe), and
  plugins-bad's `-webrtc` now RDEPENDS on libnice to say so.
- **mpph264enc** (gstreamer-rockchip): two of our commits, merged upstream as
  JeffyCN/mirrors#83 (df71354, bd16b2b), past meta-rockchip's c37e7cf pin. One
  lets it offer `constrained-baseline`, without which webrtcsink's discovery
  finds no codec and every session dies on not-negotiated. The other makes it
  report its real level: it said 4.0 for everything, and with `42c028` on the
  wire Firefox and Chrome showed nothing for 720p30 (level 3.1, browsers offer
  `42e01f`) while a GStreamer client was fine (2026-09-16). The pinned tip
  also brings 4b68d0f (pool of max-pending+1 buffers, so rkisp stops dropping
  frames) and a `gpu` meson option we disable, so EGL in the sysroot cannot
  change the plugin silently. Drop the bbappend once meta-rockchip's SRCREV
  reaches ebc758a; until then recheck that its `SRC_URI` is still the one git
  entry we replace.

## Why `PACKAGE_ARCH` comes before `inherit packagegroup`

`packagegroup.bbclass` snapshots it (`PACKAGE_ARCH_EXPANDED := ...`) to decide
on `allarch`. Set afterwards, allarch's pre-finalise handler resets it to
`all`, and an allarch group may not depend on Debian-renamed packages
(`rockchip-mpp` → `librockchip-mpp1`, `librga2`). Those `bb.error`s fail no
task: the build writes the `.wic`, logs "all succeeded", and exits 1.
