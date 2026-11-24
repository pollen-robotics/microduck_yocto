#!/bin/sh
# The duck detector on the NPU: duck-bench loads librknnrt and the .rknn model
# like mediad, on a synthetic test card. Detections are reported, not judged
# (the model sees a duck in the colour bars). Prints one line.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$(timeout 60 /opt/robot/daemon/current/bin/duck-bench \
	--model /opt/robot/detector/current/duck_detect.rknn --frames "$here/npu" \
	--warmup 2 --passes 3 --hz 0 2>&1) || {
	echo "duck-bench failed: $(echo "$out" | tail -3 | tr '\n' ' ')"
	exit 1
}
echo "$out" | grep -E '^(runtime|latency|detections)' | tr -s ' ' | tr '\n' ';'
echo
echo "$out" | grep -q '^latency'
