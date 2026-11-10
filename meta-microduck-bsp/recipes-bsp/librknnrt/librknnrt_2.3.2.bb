SUMMARY = "Rockchip's RKNPU2 runtime (librknnrt.so), prebuilt for aarch64"
DESCRIPTION = "The userspace half of the RK3566 NPU. microduck_daemon's duck-detect \
dlopens librknnrt.so to run the duck detector's .rknn model, and falls back to the \
CPU (.onnx through ONNX Runtime) when it cannot -- so without this package the \
detector works, slower and warmer. The kernel half is the rknpu driver, built into \
the vendor kernel and enabled in the beta device tree."
HOMEPAGE = "https://github.com/airockchip/rknn-toolkit2"

# Rockchip's own terms, not an open-source licence: "All rights reserved", as-is,
# no warranty, and no explicit redistribution clause. Rockchip publishes the binary
# itself in the public repo above, which is what every Rockchip distro ships.
LICENSE = "Rockchip-RKNN"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a2399e2538b7ebeac89b5b1cc648459a"
NO_GENERIC_LICENSE[Rockchip-RKNN] = "LICENSE"

# Version: the tag in rknn-toolkit2, which must be at least as new as the toolkit
# that converted the model ("a runtime older than its model fails at rknn_init with
# a number"). Keep it in step with microduck_daemon's
# [workspace.metadata.rknpu] runtime pin and scripts/setup-npu.sh's RUNTIME.
#
# Two files, not the repo: rknn-toolkit2 carries Python wheels for every release
# and is far too big to clone for one .so.
RKNN_TAG = "v${PV}"
RKNN_RAW = "https://raw.githubusercontent.com/airockchip/rknn-toolkit2/${RKNN_TAG}"
SRC_URI = " \
    ${RKNN_RAW}/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so;name=lib \
    ${RKNN_RAW}/LICENSE;name=license \
"
SRC_URI[lib.sha256sum] = "d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8"
SRC_URI[license.sha256sum] = "d846f57d942c7dfdca7b8b54f9e8bb39e1e226790dc4f5ee205d6fd678961720"

S = "${UNPACKDIR}"

# An aarch64 binary drop.
COMPATIBLE_HOST = "aarch64.*-linux"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

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
# not -dev. Hence FILES and the dev-so skip, as for onnxruntime.
FILES:${PN} = "${libdir}/librknnrt.so ${libdir}/librknnrt.version"
FILES_SOLIBSDEV = ""

# already-stripped: Rockchip ships it stripped. ldflags: not linked by our toolchain.
# Needs at most GLIBC_2.17 / GLIBCXX_3.4.22 (`grep -ao` over the .so), far below wrynose's.
INSANE_SKIP:${PN} += "already-stripped ldflags dev-so"
