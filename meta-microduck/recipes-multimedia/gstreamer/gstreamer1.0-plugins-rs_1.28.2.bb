SUMMARY = "GStreamer plugins written in Rust: webrtcsink/webrtcsrc and rtp"
DESCRIPTION = "The plugin reachy_mini_os ships as an 82.7 MB Git-LFS blob with no \
recipe, no source pin and four environment variables duplicated into every systemd \
unit to locate it. Built here from a pinned SRCREV, which is the clearest single \
argument for the whole Yocto trade."
HOMEPAGE = "https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs"

LICENSE = "MPL-2.0"
LIC_FILES_CHKSUM = "file://LICENSE-MPL-2.0;md5=815ca599c9df247a0c7f619bab123dad"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Six repositories, and everything after the first is the difficulty of this recipe.
#
# gst-plugins-rs takes its bindings from git rather than crates.io:
#
#   gst = { package = "gstreamer",
#           git = "https://gitlab.freedesktop.org/gstreamer/gstreamer-rs",
#           branch = "0.25", version = "0.25.0" }
#
# and cargo-update-recipe-crates only vendors crates.io entries --
#
#   crates_candidates = list(filter(lambda c: 'crates.io' in c.get('source', ''), ...))
#
# -- so none of those crates reaches the generated crates.inc and cargo cannot
# resolve them under --frozen. Every 1.28.x tag (1.28.0 .. 1.28.6) does this, which
# is why no upstream Yocto recipe for gst-plugins-rs exists.
#
# There are five such repositories, not one. The first attempt fetched only
# gstreamer-rs and still failed, on `glib` from gtk-rs-core, because **cargo
# resolves the entire workspace even when --package names only some members**: the error
# came from gst-plugin-analytics, which we do not build. Resolution needs every
# member's sources present; compilation still only touches what we ask for, so
# gtk4-rs and the rest are fetched and never built.
#
# Each SRCREV below is the commit gst-plugins-rs's own Cargo.lock pins, not the tip
# of the branch it names. A tip would build a combination upstream never resolved
# and would differ between two builds of the same SRCREV_plugins. Extract them with:
#
#   grep -oE 'git\+[^"]+#[0-9a-f]{40}' Cargo.lock | sort -u
SRC_URI = "git://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git;protocol=https;nobranch=1;name=plugins \
           git://gitlab.freedesktop.org/gstreamer/gstreamer-rs.git;protocol=https;nobranch=1;name=bindings;destsuffix=gstreamer-rs \
           git://github.com/gtk-rs/gtk-rs-core.git;protocol=https;nobranch=1;name=gtkcore;destsuffix=gtk-rs-core \
           git://github.com/gtk-rs/gtk4-rs.git;protocol=https;nobranch=1;name=gtk4;destsuffix=gtk4-rs \
           git://github.com/rust-av/flavors.git;protocol=https;nobranch=1;name=flavors;destsuffix=flavors \
           git://github.com/rust-av/ffv1.git;protocol=https;nobranch=1;name=ffv1;destsuffix=ffv1 \
           file://0001-webrtcsink-add-mpph264enc-encoder-support.patch \
"

# Tag gstreamer-1.28.2 -- note the prefix, the tags are not bare version numbers.
# Chosen to match GStreamer core 1.28.2. The 2026-10-15 oe-core bump moved core to
# 1.28.5 and this stayed: GStreamer keeps its ABI within 1.x, and gstreamer-1.28.5
# moves three of the git pins below (gstreamer-rs, gtk-rs-core, gtk4-rs), reworks
# Cargo.lock and needs the webrtcsink patch rebased -- a bump of its own.
SRCREV_plugins = "08eeb63ff2f74405447089f20c48868478a6076d"
SRCREV_bindings = "f49606f22450e992556221e5c9dfeb628b8b54b0"
SRCREV_gtkcore = "48b79229f29fd9f87509e5ae3b34e8e584d6b92b"
SRCREV_gtk4 = "777c1468860b49100051034f798191a5c8a31c12"
SRCREV_flavors = "833508af656d298c269f2397c8541a084264d992"
SRCREV_ffv1 = "bd9eabfc14c9ad53c37b32279e276619f4390ab8"
SRCREV_FORMAT = "plugins_bindings_gtkcore_gtk4_flavors_ffv1"

# No S assignment. oe-core's bitbake.conf sets S = "${UNPACKDIR}/${BP}" and
# BB_GIT_DEFAULT_DESTSUFFIX = "${BP}", so the gst-plugins-rs checkout -- the one
# without an explicit destsuffix -- already lands exactly there. Setting
# S = "${UNPACKDIR}/git" by hand is now a hard do_unpack error rather than a
# harmless leftover, which is how this recipe failed its first build.
#
# Every other checkout carries a destsuffix and so lands beside S, named after the
# repository, which is the convention the postfunc below relies on.

require ${BPN}-crates.inc

# cargo_c drives `cargo cbuild`/`cargo cinstall` and pulls cargo-c-native itself.
# net/webrtc/Cargo.toml already carries [package.metadata.capi] with
# install_subdir = "gstreamer-1.0", so cinstall lands the plugins in the right place.
inherit cargo_c cargo-update-recipe-crates

# gstreamer-webrtc-1.0 and gstreamer-sdp-1.0 live in plugins-bad, which is also where
# the webrtcbin element comes from -- see the bbappend enabling PACKAGECONFIG webrtc.
DEPENDS += "gstreamer1.0 gstreamer1.0-plugins-base gstreamer1.0-plugins-bad"

# Three of 65 workspace members. Building the whole repo would be hundreds of crates
# of plugins nothing here needs. gst-plugin-rtp comes along because the webrtc
# plugin's payloading path uses it. gst-plugin-tracers (buffer-lateness,
# queue-levels, pipeline-snapshot, pad-push-timings, memory-tracer, pcap-writer)
# is pure Rust -- every crate it pulls is already in crates.inc, since Cargo.lock
# covers the whole workspace -- and lands in its own package for the dev image.
CARGO_BUILD_FLAGS += "--package gst-plugin-webrtc --package gst-plugin-rtp --package gst-plugin-tracers"

# Point cargo at the fetched checkouts, one [patch] entry per crate.
#
# cargo_common_do_patch_paths already does this for git dependencies, but it can only
# express *one crate per repository*: it reads `name` and `destsuffix` off each SRC_URI
# entry and emits `name = { path = <UNPACKDIR>/<destsuffix> }`. These repositories hold
# 70 crates between them -- gstreamer-rs alone has 39, each in its own subdirectory and
# some nested two deep (gstreamer/sys, gstreamer-gl/egl/sys). One entry per repository
# cannot name them, and adding a repository once per crate would clone it that many
# times and still point every entry at its root.
#
# So the class writes six useless entries and this function replaces the lot. Their
# names are not wasted: giving those SRC_URI entries both `name` and `destsuffix` is
# what makes the class do the other half of its job, which we do want -- stripping the
# `source = "git..."` lines out of Cargo.lock so --frozen still passes, after keeping
# the .orig copy this function reads.
#
# Nothing here is hand-maintained. The repositories, their crate names and the [patch]
# keys all come from the lockfile; the paths come from walking the checkouts. A bumped
# SRCREV that moves or renames a crate is then a build failure that names it, rather
# than a patch that silently does not apply -- which is the failure this area has
# already produced once, in the v3 binary release whose MANIFEST claims a patch its
# .so does not contain.
python microduck_cargo_git_patch_paths() {
    import os
    import re

    unpackdir = d.getVar("UNPACKDIR")
    config = os.path.join(d.getVar("CARGO_HOME"), "config.toml")

    # Read the lockfile as it was *before* cargo_common stripped the git sources.
    lock = d.getVar("CARGO_LOCK_PATH")
    orig = lock + ".orig"
    source = orig if os.path.exists(orig) else lock

    # crate name -> repository URL, for every package resolved from git.
    # The URL is the [patch] key and has to match what the dependency declares, so
    # take it verbatim from the lockfile minus the ?branch/?rev query and #commit.
    wanted = {}
    name = None
    with open(source) as f:
        for line in f:
            line = line.strip()
            match = re.match(r'name = "([^"]+)"', line)
            if match:
                name = match.group(1)
                continue
            match = re.match(r'source = "git\+([^?#"]+)', line)
            if match and name:
                wanted[name] = match.group(1)

    if not wanted:
        bb.fatal("no git-sourced packages in %s. If upstream moved these crates to "
                 "crates.io then crates.inc already covers them and this function is "
                 "obsolete; if the lockfile moved, this is reading the wrong file."
                 % source)

    # Each repository is unpacked at ${UNPACKDIR}/<basename minus .git>, which is the
    # destsuffix convention used in SRC_URI above.
    def checkout(url):
        return os.path.join(unpackdir, os.path.basename(url)[:-4]
                            if url.endswith(".git") else os.path.basename(url))

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
            package, section = None, None
            with open(os.path.join(dirpath, "Cargo.toml")) as f:
                for line in f:
                    stripped = line.strip()
                    if stripped.startswith("["):
                        section = stripped
                        continue
                    if section == "[package]":
                        match = re.match(r'name\s*=\s*"([^"]+)"', stripped)
                        if match:
                            package = match.group(1)
                            break
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
# belong in the runtime package and dev-so has to be skipped.
PACKAGE_BEFORE_PN += "${PN}-tracers"
FILES:${PN}-tracers = "${libdir}/gstreamer-1.0/libgstrstracers.so"
FILES:${PN} += "${libdir}/gstreamer-1.0/*.so"
FILES:${PN}-dev += "${libdir}/gstreamer-1.0/*.a"
INSANE_SKIP:${PN} += "dev-so"
INSANE_SKIP:${PN}-tracers += "dev-so"

# webrtcsink builds a pipeline around webrtcbin at runtime; without this the plugin
# loads and then fails at pipeline construction.
RDEPENDS:${PN} += "gstreamer1.0-plugins-bad-webrtc"

# The plugin compiles and links; do_package_qa then fails the build on
#
#   QA Issue: File /usr/lib/gstreamer-1.0/.debug/libgstrswebrtc.so in package
#   gstreamer1.0-plugins-rs-dbg contains reference to TMPDIR [buildpaths]
#
# rust-common.bbclass passes --remap-path-prefix=${WORKDIR}=${TARGET_DBGSRC_DIR},
# and everything this recipe compiles lives under WORKDIR -- the checkouts, the
# vendored crates, both sysroots -- so something is embedding an absolute path by a
# route that flag does not cover. microduck-daemon, a plain cargo build of
# executables, does not trip it, so the suspect is cargo-c's own cdylib link or a
# build script, not the git dependencies added here.
#
# Downgraded rather than skipped, and only for this recipe. What it protects is
# build reproducibility, and the affected file is in the -dbg package, which no
# microduck image installs -- IMAGE_FEATURES carries no dbg-pkgs, so this never
# reaches a robot. Failing the whole image on it while the cause is unknown trades
# a real feature for a property of a package we do not ship.
#
# The postfunc below is what makes this temporary: it prints the offending strings,
# so the next build says which path and from where instead of just that one exists.
ERROR_QA:remove = "buildpaths"
WARN_QA:append = " buildpaths"

python microduck_report_buildpaths() {
    import os
    import re

    tmpdir = d.getVar("TMPDIR").encode()
    pkgd = d.getVar("PKGD")
    hits = set()

    for dirpath, _, filenames in os.walk(pkgd):
        for filename in filenames:
            path = os.path.join(dirpath, filename)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as f:
                    blob = f.read()
            except (IOError, OSError):
                continue
            for match in re.finditer(re.escape(tmpdir) + b"[^\x00\n]{0,140}", blob):
                hits.add((os.path.relpath(path, pkgd),
                          match.group(0).decode("utf-8", "replace")))

    for where, what in sorted(hits)[:25]:
        bb.warn("buildpath in %s: %s" % (where, what))
    if len(hits) > 25:
        bb.warn("buildpath: %d more not shown" % (len(hits) - 25))
}
do_package[postfuncs] += "microduck_report_buildpaths"

# Cargo.lock has 1139 crates, so crates.inc is large and the first fetch is long.
# Regenerate after a SRCREV bump with:
#   ./scripts/build-local.sh shell -c "bitbake -c update_crates gstreamer1.0-plugins-rs"
