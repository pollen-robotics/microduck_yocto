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

	# A second unversioned symlink, in /usr/local/lib, purely so the daemon's
	# update hook can find this.
	#
	# hooks/preinstall probes exactly one path -- ONNX_LIB_DIR=/usr/local/lib --
	# and reads the version out of what `readlink -f` resolves to, because asking
	# the library itself would mean dlopening it. A distro install in ${libdir} is
	# invisible to that check, so on 2026-09-16 a board carrying this very package
	# at the very version the hook wanted refused the 0.13.0 update with "ONNX
	# Runtime absent is below 1.23" and then failed to download a replacement
	# because the image has no curl. The update was correctly refused and nothing
	# was swapped; it just could never have succeeded.
	#
	# Pointing at the versioned file rather than at ${libdir}/libonnxruntime.so
	# keeps the hook's parse working through one hop instead of three, and means
	# this link says which version it is even if the chain above changes shape.
	#
	# The hook writes here itself when it does install ONNX, so this is the
	# directory it already owns -- we are only telling it what is already present.
	install -d ${D}${prefix}/local/lib
	ln -sf ${libdir}/libonnxruntime.so.${PV} ${D}${prefix}/local/lib/libonnxruntime.so
}

# The unversioned symlink has to be in the RUNTIME package, which is not where Yocto
# would put it. duck-control/src/policy.rs dylib_name() replicates ort's own lookup:
# with ORT_DYLIB_PATH unset it dlopens plain "libonnxruntime.so", so shipping that
# symlink in -dev would leave robotd unable to load the policy on a normal image.
# Hence FILES below, and the dev-so QA skip that permits it.
FILES:${PN} = " \
    ${libdir}/libonnxruntime.so \
    ${libdir}/libonnxruntime.so.* \
    ${libdir}/libonnxruntime_providers_shared.so \
    ${prefix}/local/lib/libonnxruntime.so \
"
FILES:${PN}-dev = "${includedir} ${libdir}/pkgconfig ${libdir}/cmake"

# already-stripped: Microsoft ships it stripped.
# dev-so: the deliberate unversioned-symlink placement above.
INSANE_SKIP:${PN} += "already-stripped dev-so"

# Prebuilt, so nothing here is rebuilt against our toolchain. It needs at most
# GLIBC_2.27 (checked with `strings | grep GLIBC_`), well below wrynose's glibc, so
# it loads -- but if a future release raises that, this is where it will surface.
