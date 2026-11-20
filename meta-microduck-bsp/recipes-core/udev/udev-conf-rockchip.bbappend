# Upstream (still at meta-rockchip's wrynose tip) unpacks loose file:// into
# ${UNPACKDIR} but leaves S at ${UNPACKDIR}/${BP}, so do_unpack warns. Drop when fixed there.
S:microduck-machine = "${UNPACKDIR}"
