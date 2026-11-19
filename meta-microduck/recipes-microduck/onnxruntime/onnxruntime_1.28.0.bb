SUMMARY = "ONNX Runtime, Microsoft's prebuilt aarch64 shared library"
DESCRIPTION = "Needed by robotd's gait policy. duck-control depends on ort \
2.0.0-rc.11 with the \"load-dynamic\" feature, so the library is dlopened at first \
use rather than linked -- robotd installs and starts fine without it and only fails \
when asked to walk."
HOMEPAGE = "https://onnxruntime.ai"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=0f7e3b1308cb5c00b372a6e78835732d"

# Prebuilt: a source build pulls protobuf, abseil and onnx for a library we only
# dlopen. Keep PV at or above the daemon's onnxruntime floor (1.23): ort panics below.
SRC_URI = "https://github.com/microsoft/onnxruntime/releases/download/v${PV}/onnxruntime-linux-aarch64-${PV}.tgz"
SRC_URI[sha256sum] = "e15ff8b5d85afe6c144d97c6fd432254bf76a219daaf17658087d6ecb3e8f0bb"

S = "${UNPACKDIR}/onnxruntime-linux-aarch64-${PV}"

COMPATIBLE_HOST = "aarch64.*-linux"

# Our do_install replaces the class's: the archive is not laid out like a rootfs.
inherit bin_package

# Never `cp -a`: it keeps Microsoft's uid 1004, and do_package fails on it.
do_install() {
	install -d ${D}${libdir}
	install -m 0755 ${S}/lib/libonnxruntime.so.${PV} ${D}${libdir}/
	ln -sf libonnxruntime.so.${PV} ${D}${libdir}/libonnxruntime.so.1
	ln -sf libonnxruntime.so.1 ${D}${libdir}/libonnxruntime.so
	install -m 0755 ${S}/lib/libonnxruntime_providers_shared.so ${D}${libdir}/

	install -d ${D}${includedir}
	cp -R ${S}/include/. ${D}${includedir}/
	chmod -R u+rwX,go+rX,go-w ${D}${includedir}

	install -d ${D}${libdir}/pkgconfig
	install -m 0644 ${S}/lib/pkgconfig/*.pc ${D}${libdir}/pkgconfig/

	# For the daemon's hooks/preinstall, as librknnrt.version: no dlopen needed.
	echo "${PV}" > ${D}${libdir}/libonnxruntime.version
}

# The daemon loads libonnxruntime.so.1 (ORT_DYLIB_PATH), so the bare .so is -dev's.
FILES:${PN} = " \
    ${libdir}/libonnxruntime.so.* \
    ${libdir}/libonnxruntime_providers_shared.so \
    ${libdir}/libonnxruntime.version \
"
FILES:${PN}-dev = "${libdir}/libonnxruntime.so ${includedir} ${libdir}/pkgconfig ${libdir}/cmake"

# Shipped stripped.
INHIBIT_PACKAGE_STRIP_FILES = " \
    ${PKGD}${libdir}/libonnxruntime.so.${PV} \
    ${PKGD}${libdir}/libonnxruntime_providers_shared.so \
"

# Prebuilt, so nothing here is rebuilt against our toolchain. It needs at most
# GLIBC_2.27 (checked with `strings | grep GLIBC_`), well below wrynose's glibc, so
# it loads -- but if a future release raises that, this is where it will surface.
