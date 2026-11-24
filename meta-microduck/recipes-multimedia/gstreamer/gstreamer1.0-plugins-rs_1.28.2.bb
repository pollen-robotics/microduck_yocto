SUMMARY = "GStreamer plugins written in Rust: webrtcsink/webrtcsrc and rtp"
DESCRIPTION = "The plugin reachy_mini_os ships as an 82.7 MB Git-LFS blob with no \
recipe, no source pin and four environment variables duplicated into every systemd \
unit to locate it. Built here from a pinned SRCREV, which is the clearest single \
argument for the whole Yocto trade."
HOMEPAGE = "https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs"

LICENSE = "MPL-2.0"
LIC_FILES_CHKSUM = "file://LICENSE-MPL-2.0;md5=815ca599c9df247a0c7f619bab123dad"

DEPENDS += "gstreamer1.0 gstreamer1.0-plugins-base gstreamer1.0-plugins-bad"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The git dependencies cargo-update-recipe-crates cannot vendor, all five: cargo
# resolves the whole workspace (docs/agents/media.md). Each SRCREV is the one
# Cargo.lock pins: grep -oE 'git\+[^"]+#[0-9a-f]{40}' Cargo.lock | sort -u
SRC_URI = "git://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git;protocol=https;nobranch=1;name=plugins \
           git://gitlab.freedesktop.org/gstreamer/gstreamer-rs.git;protocol=https;nobranch=1;name=bindings;destsuffix=gstreamer-rs \
           git://github.com/gtk-rs/gtk-rs-core.git;protocol=https;nobranch=1;name=gtkcore;destsuffix=gtk-rs-core \
           git://github.com/gtk-rs/gtk4-rs.git;protocol=https;nobranch=1;name=gtk4;destsuffix=gtk4-rs \
           git://github.com/rust-av/flavors.git;protocol=https;nobranch=1;name=flavors;destsuffix=flavors \
           git://github.com/rust-av/ffv1.git;protocol=https;nobranch=1;name=ffv1;destsuffix=ffv1 \
           file://0001-webrtcsink-add-mpph264enc-encoder-support.patch \
"

# Tag gstreamer-1.28.2, against a 1.28.5 core: the ABI holds within 1.x, and
# 1.28.5 moves three git pins and the webrtcsink patch, a bump of its own.
SRCREV_plugins = "08eeb63ff2f74405447089f20c48868478a6076d"
SRCREV_bindings = "f49606f22450e992556221e5c9dfeb628b8b54b0"
SRCREV_gtkcore = "48b79229f29fd9f87509e5ae3b34e8e584d6b92b"
SRCREV_gtk4 = "777c1468860b49100051034f798191a5c8a31c12"
SRCREV_flavors = "833508af656d298c269f2397c8541a084264d992"
SRCREV_ffv1 = "bd9eabfc14c9ad53c37b32279e276619f4390ab8"
SRCREV_FORMAT = "plugins_bindings_gtkcore_gtk4_flavors_ffv1"

require ${BPN}-crates.inc

inherit cargo_c cargo-update-recipe-crates

# Three of 65 members: webrtc, the rtp it payloads with, and the tracers
# (their own package, dev image only).
CARGO_BUILD_FLAGS += "--package gst-plugin-webrtc --package gst-plugin-rtp --package gst-plugin-tracers"

# One cargo [patch] entry per crate, from the lockfile and the checkouts: the
# class writes one per repository, and these hold 70 crates. Keep its entries'
# name+destsuffix anyway: they make it strip the git sources from Cargo.lock.
python microduck_cargo_git_patch_paths() {
    import os
    import re
    import tomllib

    unpackdir = d.getVar("UNPACKDIR")
    config = os.path.join(d.getVar("CARGO_HOME"), "config.toml")

    # Read the lockfile as it was *before* cargo_common stripped the git sources.
    lock = d.getVar("CARGO_LOCK_PATH")
    orig = lock + ".orig"
    source = orig if os.path.exists(orig) else lock

    # crate name -> repository URL, for every package resolved from git.
    # The URL is the [patch] key and has to match what the dependency declares, so
    # take it verbatim from the lockfile minus the ?branch/?rev query and #commit.
    with open(source, "rb") as f:
        packages = tomllib.load(f)["package"]
    wanted = {p["name"]: re.split(r"[?#]", p["source"].removeprefix("git+"))[0]
              for p in packages if p.get("source", "").startswith("git+")}

    if not wanted:
        bb.fatal("no git-sourced packages in %s. If upstream moved these crates to "
                 "crates.io then crates.inc already covers them and this function is "
                 "obsolete; if the lockfile moved, this is reading the wrong file."
                 % source)

    # Each repository is unpacked at ${UNPACKDIR}/<basename minus .git>, which is the
    # destsuffix convention used in SRC_URI above.
    def checkout(url):
        return os.path.join(unpackdir, os.path.basename(url).removesuffix(".git"))

    repos = sorted(set(wanted.values()))
    absent = [r for r in repos if not os.path.isdir(checkout(r))]
    if absent:
        bb.fatal("the lockfile resolves crates from %d git repositories and these are "
                 "not in SRC_URI: %s. Cargo resolves the whole workspace even though "
                 "CARGO_BUILD_FLAGS names only some members, so every one of them has to be "
                 "fetched." % (len(repos), " ".join(absent)))

    # Where each crate actually lives. Walk rather than assume: the -sys crates sit
    # under their parent (gstreamer/sys), and the GL ones nest further still.
    found = {}
    for repo in repos:
        root = checkout(repo)
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [x for x in dirnames if x not in (".git", "target")]
            if "Cargo.toml" not in filenames:
                continue
            with open(os.path.join(dirpath, "Cargo.toml"), "rb") as f:
                try:
                    package = tomllib.load(f).get("package", {}).get("name")
                except tomllib.TOMLDecodeError as e:
                    bb.fatal("%s/Cargo.toml: %s" % (dirpath, e))
            if package:
                found[(repo, package)] = dirpath

    missing = sorted(c for c, r in wanted.items() if (r, c) not in found)
    if missing:
        bb.fatal("no directory for: %s. A SRCREV moved without its crates -- each one "
                 "has to stay the commit SRCREV_plugins' Cargo.lock names."
                 % " ".join(missing))

    # Drop every [patch] block already in the file -- they are all the class's, since
    # it only writes them for SRC_URI git entries and all of ours are handled here --
    # then write the real ones.
    keep, skipping = [], False
    if os.path.exists(config):
        with open(config) as f:
            for line in f:
                if line.startswith("[patch."):
                    skipping = True
                elif line.startswith("["):
                    skipping = False
                if not skipping:
                    keep.append(line)

    with open(config, "w") as f:
        f.writelines(keep)
        for repo in repos:
            f.write('\n[patch."%s"]\n' % repo)
            for crate in sorted(c for c, r in wanted.items() if r == repo):
                f.write('%s = { path = "%s" }\n' % (crate, found[(repo, crate)]))

    bb.note("cargo git deps: %d crates patched across %d repositories"
            % (len(wanted), len(repos)))
}
do_configure[postfuncs] += "microduck_cargo_git_patch_paths"

# GStreamer plugins are unversioned .so files inside a plugin directory, so they
# belong in the runtime package. Real files, not symlinks, so dev-so does not fire.
PACKAGE_BEFORE_PN += "${PN}-tracers"
FILES:${PN}-tracers = "${libdir}/gstreamer-1.0/libgstrstracers.so"
FILES:${PN} += "${libdir}/gstreamer-1.0/*.so"
FILES:${PN}-dev += "${libdir}/gstreamer-1.0/*.a"

# webrtcsink builds a pipeline around webrtcbin at runtime; without this the plugin
# loads and then fails at pipeline construction.
RDEPENDS:${PN} += "gstreamer1.0-plugins-bad-webrtc"

# [buildpaths]: crates' C (ring) in cargo_home is outside gcc's DEBUG_PREFIX_MAP.
# Prepended, as gcc tries the last map first and ${S}/${B} must still win.
DEBUG_PREFIX_MAP:prepend = "-ffile-prefix-map=${WORKDIR}=${TARGET_DBGSRC_DIR} "

# After a SRCREV bump, regenerate crates.inc:
#   ./scripts/build-local.sh shell -c "bitbake -c update_crates gstreamer1.0-plugins-rs"
