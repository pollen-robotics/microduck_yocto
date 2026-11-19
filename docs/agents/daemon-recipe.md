# The daemon recipe (`microduck-daemon_<version>.bb`)

Why each part of the recipe is the way it is. The recipe itself keeps only
one-line pointers; the reasons live here.

## Source and pin

- **Licence: the whole `LICENSE` file, not a line range of `Cargo.toml`.** The
  old line-range checksum broke as soon as the manifest above it was edited (at
  6507d2e `license =` moved from line 28 to 88). md5 `86d3f3a9` is the
  Apache-2.0 text we fetch, so it differs from oe-core's `89aea4e1`.
- **The build fetches over SSH** (README.md: ssh-agent with a GitHub key).
  Robots download release assets anonymously over HTTPS, which works only
  because the repo is public: a *private* repo's
  `releases/download/<tag>/<asset>` returns 404 with or without a token
  (updater-design.md §11).
- **`SRCREV_daemon` is a release's `source_revision`, never `main` nor the tag.**
  The recipe once pinned 6507d2e, 21 commits ahead of 0.12.0, and both called
  themselves 0.12.0. updaterd compares versions, so it would never converge.
  Bump with `scripts/bump-daemon.sh` (README.md, "Which daemon the image seeds").
- **Rust floor.** 0.15.3 was the first release to build on wrynose's Rust 1.94.1
  (0.15.1/0.15.2 needed 1.99). A release that needs a newer Rust is a CI
  failure, not a reason to pin an older one.
- **`bmi088` (tof's IMU driver) is the one git dependency.**
  `cargo-update-recipe-crates` only emits crates.io entries, so it is in
  `SRC_URI` by hand. `cargo_common_do_patch_paths` turns a git entry with both
  `name` and `destsuffix` into a `[patch]` and strips its `source = "git...`
  lines from `Cargo.lock`, so:
  - `name` must be the *crate* name (`bmi088`), not the repo's;
  - `SRCREV_bmi088` is the commit (`bd113f31`), not the annotated tag object
    (`172ddbee`), which cargo rejects;
  - it does not follow a release: a release that moves bmi088 fails CI until
    bumped here.
  - Two git URLs force `name=daemon` and `SRCREV_FORMAT`; a bare `SRCREV`
    applies to neither.
- **No `S =`.** See AGENTS.md.

## Build

- `cmake-native`: rustls uses aws-lc-rs, whose `aws-lc-sys` runs CMake. No
  OpenSSL in the Rust build. CMake is a tool for that one crate, so not
  `inherit cmake`: that class would run CMake on our cargo workspace.
- `systemd` + `inherit pkgconfig`: padd's gilrs needs libudev-sys
  unconditionally. `systemd` gives the library, `pkgconfig` the binary its
  build.rs runs. Without the latter the env looks right and the build dies with
  "The pkg-config command could not be found."
- GStreamer: mediad links the bindings, and each `-sys` crate pkg-configs a `.pc`:

  | recipe | `.pc` |
  |---|---|
  | glib-2.0 | glib-2.0, gobject-2.0, gio-2.0 |
  | gstreamer1.0 | gstreamer-1.0, gstreamer-base-1.0 |
  | gstreamer1.0-plugins-base | gstreamer-app-1.0, gstreamer-video-1.0, gstreamer-sdp-1.0 |
  | gstreamer1.0-plugins-bad | gstreamer-webrtc-1.0, only because our bbappend enables webrtc |

  They sit under `[target.'cfg(target_os = "linux")'.dependencies]`, which is how
  they were missed the first time (0.12.0: `Package 'gstreamer-1.0' not found`).
  When adding a workspace member, read the target-conditional tables too.
- **`--workspace` minus exclusions**, not a list of members: a crate added
  upstream builds without editing the recipe (upstream's `default-members` does
  the same). Excluded: `xtask` (release tooling, can sign), `test-support`,
  `duckctl` (laptop client), `duck-ether` (not in `default-members` either).
- **`DUCK_REVISION = SRCREV_daemon`**: the commit CI stamps, so daemons stop
  logging "rev unknown". No `DUCK_BUILD_TIME`: it would make the image
  unreproducible.

## Users and groups

- Created at image build time (`useradd`), not by upstream's `sysusers.d`, which
  is not installed: deterministic, no sysusers ordering.
- systemd refuses a unit whose `User=` or `SupplementaryGroups=` does not exist,
  so every daemon gets its user, hardware or not.
- `btd`: own unprivileged user, it parses bytes from anyone in radio range.
  `bluetooth` exists only to satisfy its unit: oe-core's bluez5 D-Bus policy has
  no `group="bluetooth"` rule.
- `robot-account` owns `/var/lib/robot/hf-token` so only mediad reads it, not
  all of `robot` (microduck#230). updaterd writes it as root.
- `nfcd` is both nfcd's `User=` and the group microduck-nfc's udev rule gives
  the reader to.
- Supplementary groups:

  | unit | groups | note |
  |---|---|---|
  | mediad | video render robot | exist already (udev-conf-rockchip, DRM rules) |
  | tofd | i2c robot | `i2c` does not exist on a stock image: groupadd + `60-robot-i2c.rules` (`/dev/i2c-*` is 0600 root) |
  | padd | input robot | `/dev/input/event*` is already root:input |
  | nfcd | dialout robot | the bench USB reader's `/dev/ttyACM*` |
  | netpadd, autod, mapd | robot | network or AF_UNIX only |

## Units

- **Every unit enabled.** A robot with the hardware must come up working.
  mediad, tofd and padd have no `Condition=`, so they fail on a bare bring-up
  board: `systemctl disable --now mediad tofd padd` there. nfcd only logs and
  retries.
- `padd.service` is in `${PN}-padd` with its binary, so `SYSTEMD_PACKAGES` names
  both packages (it defaults to `${PN}` alone and padd would never be enabled).
- `netpadd` stays down unless `[netpad] enabled`, and padd then stands down.
- `duck-gateway` exits 0 without a setup code, so it never shows in
  `systemctl --failed`.
- `robot-boot-check.service` has no `[Install]`: the timer starts it. It hands a
  release whose daemons did not come up to `robot-rescue` (current → golden).
  Both scripts live in `/usr/local/sbin`, outside the release tree, because they
  run when the release cannot be trusted.
- **New daemons.** 0.21.0 added autod and mapd; the first image had their
  binaries but no units, so the NFC autonomous tag did nothing (2026-11-13).
  `do_install` now fails on any unit the release ships and the recipe does not
  install, and `scripts/bump-daemon.sh` checks it before a build. Its check greps
  for `/<dir>/systemd/<unit> ` in the recipe, so keep one `install` line per unit
  in that form.

## Install layout

- **Release tree, the layout updaterd owns**: `/opt/robot/daemon/releases/<ver>/`,
  `current` and `golden` (never pruned, the rescue net) both pointing at it.
  Units are installed verbatim: their `ExecStart` already says `current/bin/`. An
  earlier packaging rewrote them to `/usr/bin`, so an update swapped `current`,
  reported success, and changed nothing.
- `/opt/robot/daemon` must not straddle a mount: an update is a `rename(2)` of
  `current` (updater-design.md §7.1).
- **Binaries move by glob**, not a list. The list once forgot padd, which would
  have left `${PN}-padd` with a unit and no binary. updaterd's orphan check also
  refuses a release that lacks a binary an installed unit execs.
- **Data files mirror the `--include` lines of the daemon's
  `.github/workflows/_build-release.yml`.** Nothing checks it, and a miss shows
  only on freshly flashed robots. Models come from `${S}`, since a detector's
  input is the loop's own feature row. `emotions/` appeared in 0.18.8.
- `robotctl` on PATH is a symlink through `current`, so it follows updates.
- **Completion** goes to bash-completion's lazy directory, not
  `/etc/bash_completion.d` (sourced at every login: 0.14 s vs 0.05 s on
  duck-882e). Not yet effective: bash-completion creates `/etc/bash_completion.d`,
  so the next update's `setup-login.sh` writes the eager copy there too. Fixing
  that is a daemon change.
- **Name prompt** (`/etc/profile.d/robot-name-prompt.sh`) is cut from
  `scripts/setup-login.sh`'s `PROMPT` heredoc, so there is one copy; an update
  rewrites the same path. The build fails if the heredoc disappears.
- **Config.** `CONFFILES` only covers package upgrades; a RAUC update rewrites
  `/etc`. Per-robot robotd edits go in `/var/lib/robot/robotd.toml` (daemon PR
  #483); `updater.toml` has no such layer yet.
- `updater.toml`'s `repo` is rewritten from upstream's `ORG/duck-daemon`
  placeholder (an image is a deployment), and the build fails if the rewrite
  stops applying.
- All trusted keys ship from the first image, so key rotation needs no reflash.
  The dev key is staged from `deploy/dev-key/` (not matched by the
  `trusted_keys/*.pub` glob) and packaged in `${PN}-devkey`.
- `/var/lib/robot/weird-ble`: TEMPORARY, `remove-with-real-radio`, the
  gamepad-pairing workaround. See zero3-board.md, "Gamepad pairing".

## Packages

- `${PN}-padd`: the gamepad stack and its libudev dependency, separable. It only
  governs the seed: an update reinstates the whole release tree.
- `${PN}-bash-completion`: dev image only. Its `RDEPENDS` on bash-completion is
  what makes it work: that package ships `/etc/profile.d/bash_completion.sh`,
  which defines the lazy loader. `bash-completion.bbclass` is not inherited
  because it would add a build dependency for nothing.
- `${PN}-devkey`: dev image only. The key and `allow_dev_keys = true` together,
  since either alone leaves a board that refuses branch builds. It enables
  `robotctl update apply --ref` and `provision-board.sh --ref`. It does *not*
  make a board track a branch: updaterd's prerelease filter is not
  configurable. The `.dev.` in the filename is how updaterd tells a dev key from
  a release key. Its postinst also rewrites updater.toml's "Both false"
  sentence so the file does not contradict itself, and fails if upstream rewords
  it.

## Runtime dependencies

| dependency | why |
|---|---|
| systemd | updaterd runs `systemctl` for restarts |
| ca-certificates | every HTTPS fetch |
| networkmanager, bluez5 | configd and btd drive them over D-Bus. Declared, not left to the image |
| curl | `hooks/postinstall`'s seeders (policies, detector) are POSIX shell with curl |
| coreutils | `robot-rescue` uses `mv -fT`, which busybox lacks |
| gstreamer1.0-plugins-rs | mediad exits without `webrtcsink` (crash-looped 37 times, 2026-09-15); also carries the mpph264enc patch |
| gstreamer1.0-rockchip | its patch lets mpph264enc admit constrained-baseline; without it no codec negotiates |
| onnxruntime (RRECOMMENDS, aarch64) | dlopened by ort `load-dynamic`, floor 1.23; robotd starts without it and fails only when asked to walk |
| microduck-policies | no policy set → `unhealthy` → every update rolls back. Bump with the daemon's `POLICY_VERSION` |
| microduck-detector (RRECOMMENDS) | detector off by default. Bump with `DETECTOR_VERSION` |
| microduck-slot-health | RAUC marks a slot good on the same check as robot-boot-check |
