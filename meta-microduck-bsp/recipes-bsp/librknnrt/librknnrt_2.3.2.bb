SUMMARY = "Rockchip's RKNPU2 runtime (librknnrt.so), prebuilt for aarch64"
DESCRIPTION = "The userspace half of the RK3566 NPU. microduck_daemon's duck-detect \
dlopens librknnrt.so to run the duck detector's .rknn model, and falls back to the \
CPU (.onnx through ONNX Runtime) when it cannot -- so without this package the \
detector works, slower and warmer. The kernel half is the rknpu driver, built into \
the vendor kernel and enabled in the beta device tree."
HOMEPAGE = "https://github.com/airockchip/rknn-toolkit2"

# Not open source, and no explicit redistribution clause; Rockchip publishes
# the binary itself, as every Rockchip distro ships it.
LICENSE = "Rockchip-RKNN"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a2399e2538b7ebeac89b5b1cc648459a"
NO_GENERIC_LICENSE[Rockchip-RKNN] = "LICENSE"

# PV: at least the toolkit that converted the model, in step with the daemon's
# [workspace.metadata.rknpu] pin. Two files, not the repo: it holds every wheel.
RKNN_TAG = "v${PV}"
RKNN_RAW = "https://raw.githubusercontent.com/airockchip/rknn-toolkit2/${RKNN_TAG}"
SRC_URI = " \
    ${RKNN_RAW}/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so;name=lib \
    ${RKNN_RAW}/LICENSE;name=license \
"
SRC_URI[lib.sha256sum] = "d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8"
SRC_URI[license.sha256sum] = "d846f57d942c7dfdca7b8b54f9e8bb39e1e226790dc4f5ee205d6fd678961720"

S = "${UNPACKDIR}"

COMPATIBLE_HOST = "aarch64.*-linux"

# Our do_install replaces the class's: ${S} also holds the LICENSE.
inherit bin_package

do_install() {
	install -d ${D}${libdir}
	install -m 0755 ${UNPACKDIR}/librknnrt.so ${D}${libdir}/
	# The stamp microduck_daemon's scripts/setup-npu.sh reads. Its update hook runs
	# that script, which downloads the runtime unless this file names the tag it
	# wants -- and on a read-only RAUC slot that download can only fail.
	echo "${RKNN_TAG}" > ${D}${libdir}/librknnrt.version
}

# The unversioned name is the only one Rockchip ships (it is also the library's
# SONAME), and it is what duck-detect dlopens -- it belongs in the runtime package,
# not -dev. A real file, not a symlink, so dev-so does not fire.
FILES:${PN} = "${libdir}/librknnrt.so ${libdir}/librknnrt.version"
FILES_SOLIBSDEV = ""

# Shipped stripped.
# Needs at most GLIBC_2.17 / GLIBCXX_3.4.22 (`grep -ao` over the .so), far below wrynose's.
INHIBIT_PACKAGE_STRIP_FILES = "${PKGD}${libdir}/librknnrt.so"
# ldflags: Rockchip's .so has no GNU_HASH; only a Rockchip rebuild can fix it.
INSANE_SKIP:${PN} += "ldflags"
