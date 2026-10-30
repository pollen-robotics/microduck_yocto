SUMMARY = "Camera tuning for the beta board: rkaiq 3A server and the GC2093 IQ file"
DESCRIPTION = "Rockchip's ISP 3A engine (rkaiq) and Seeed's tuning file for the \
beta board's GC2093 module (SIDB205300385-VA). Without them the ISP streams \
untuned: no white balance or colour correction, a green picture."
HOMEPAGE = "https://github.com/Seeed-Studio/seeed_armbian_extension"
# Rockchip's NOTICE (Apache-2.0), the same text meta-rockchip's rockchip-rkaiq
# checksums. The tree also links a few algorithm libraries Rockchip ships
# prebuilt (e.g. rkaiq/algos/af), under that same NOTICE.
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://NOTICE;md5=9645f39e9db895a4aa6e02cb57294595"

# rkaiq v6.0x32.0 from source, as Seeed publishes it: camera_engine_rkaiq on the
# deb_source branch of their public seeed_armbian_extension, with this module's
# IQ file in rkaiq/iqfiles/isp21. Not meta-rockchip's rockchip-rkaiq: the IQ
# file's format follows rkaiq's version, Seeed tuned this module against
# v6.0x32, and meta-rockchip builds a 2024-04 snapshot (v6.0x6.1). Same source
# commit as recipes-kernel/wq9201s.
require recipes-kernel/wq9201s/seeed-deb-source.inc
SRC_URI = " \
    ${SEEED_DEB_SOURCE} \
    file://rkaiq_3A.service \
    file://mediad-rkaiq.conf \
"
S = "${UNPACKDIR}/${BP}/camera_engine_rkaiq"

COMPATIBLE_MACHINE = "microduck-beta"

inherit cmake pkgconfig systemd

# librkaiq.so links libdrm.so.2. Without libdrm in DEPENDS the shlib scan has no
# provider for it and package_qa fails (file-rdeps); with it the runtime
# dependency is added automatically. m4, xxd and coreutils' tac (header_strip.sh;
# not among bitbake's HOSTTOOLS) generate the IQ parser's headers at build time.
DEPENDS += "libdrm m4-native xxd-native coreutils-native"

# Seeed's build-deb.sh for rk356x (ISP v21), flag for flag.
EXTRA_OECMAKE = " \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DRKAIQ_TARGET_SOC=rk356x \
    -DISP_HW_VERSION=-DISP_HW_V21 \
    -DARCH=aarch64 \
    -DRKAIQ_BUILD_BINARY_IQ=OFF \
    -DRKAIQ_USE_RAWSTREAM_LIB=OFF \
    -DRKAIQ_HAVE_FAKECAM=ON \
    -DRKAIQ_ENABLE_AF=ON \
    -DRKAIQ_ENABLE_LIBDRM=ON \
    -DRKAIQ_HAVE_MULTIISP=ON \
    -DCMAKE_SKIP_RPATH=TRUE \
"

# Two of meta-rockchip's rockchip-rkaiq fixes that are about our toolchain, not
# its snapshot: -Werror (Seeed builds with GCC 10, wrynose has 15), and the IQ
# parser's header generation, which runs the C compiler as a preprocessor without
# the sysroot's include path.
rkaiq_fix_build() {
	sed -i 's/-Werror//' ${S}/rkaiq/cmake/CompileOptions.cmake
	sed -i "s/\( \${CMAKE_C_COMPILER}\)/\1 -I\${CMAKE_SYSROOT}\/usr\/include/" \
		${S}/rkaiq/iq_parser_v2/CMakeLists.txt
}
do_patch[postfuncs] += "rkaiq_fix_build"

# The C parts are pre-C23 (`int f()` declarations that mean "any arguments"),
# which GCC 15's default C23 rejects as conflicting types; Seeed's GCC 10
# defaulted to gnu17. Build them as it did.
CFLAGS += "-std=gnu17"

do_generate_toolchain_file:append() {
	echo "set( CMAKE_SYSROOT ${STAGING_DIR_HOST} )" >> ${UNPACKDIR}/toolchain.cmake
}

# Only what the server loads: it maps librkaiq.so and nothing else of the
# package's libraries (read from /proc/<pid>/maps on a beta, with Seeed's build).
# Only the GC2093's IQ file. rkaiq's own install layout varies by version (the
# server has landed in usr/usr/bin), so stage it and pick the files out by name.
do_install() {
	DESTDIR=${B}/staging cmake_runcmake_build --target ${OECMAKE_TARGET_INSTALL}
	install -d ${D}${libdir} ${D}${bindir} ${D}${sysconfdir}/iqfiles
	for f in librkaiq.so:${libdir} rkaiq_3A_server:${bindir}; do
		p=$(find ${B}/staging -name "${f%%:*}" \( -type f -o -type l \) | head -n 1)
		[ -n "$p" ] || bbfatal "${f%%:*} was not built"
		install -m 0755 "$(readlink -f "$p")" ${D}${f#*:}/${f%%:*}
	done
	install -m 0644 ${S}/rkaiq/iqfiles/isp21/gc2093_SIDB205300385-VA_default.json ${D}${sysconfdir}/iqfiles/

	install -d ${D}${systemd_system_unitdir}/mediad.service.d
	install -m 0644 ${UNPACKDIR}/rkaiq_3A.service ${D}${systemd_system_unitdir}/
	install -m 0644 ${UNPACKDIR}/mediad-rkaiq.conf ${D}${systemd_system_unitdir}/mediad.service.d/rkaiq.conf
}

SYSTEMD_SERVICE:${PN} = "rkaiq_3A.service"

# librkaiq.so is unversioned (its SONAME is librkaiq.so), so it ships in the main
# package, not -dev.
FILES:${PN} += "${libdir}/librkaiq.so ${systemd_system_unitdir}/mediad.service.d"
FILES_SOLIBSDEV = ""
INSANE_SKIP:${PN} += "dev-so"
