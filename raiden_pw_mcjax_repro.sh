#!/bin/bash
set -euo pipefail

SRC_CONTEXT="gke_cloud-tpu-inference-test_us-west1-c_lancewang-pw-v5e-4slice"
DST_CONTEXT="gke_cloud-tpu-inference-test_us-west1_lancewang-mcjax-v5e-2slice"
SRC_JOBSET_NAME="lwraidenpwsrc"
DST_JOBSET_NAME="lwraidenmcjaxdst"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_PY="${REPRO_PY:-$SCRIPT_DIR/raiden_pathways_direct_api_repro.py}"

dst_pods=$(kubectl --context="$DST_CONTEXT" get pods -l jobset.sigs.k8s.io/jobset-name="$DST_JOBSET_NAME",jobset.sigs.k8s.io/replicatedjob-name=proc --field-selector=status.phase=Running --sort-by=.metadata.creationTimestamp -o name | cut -d/ -f2 | tr "\n" " " | sed "s/[[:space:]]*$//")
dst_pod=$(printf "%s\n" "$dst_pods" | awk "{print \$NF}")
src_pod=$(kubectl --context="$SRC_CONTEXT" get pods -l jobset.sigs.k8s.io/jobset-name="$SRC_JOBSET_NAME",jobset.sigs.k8s.io/replicatedjob-name=proc --field-selector=status.phase=Running --sort-by=.metadata.creationTimestamp -o name | tail -n 1 | cut -d/ -f2)

src_ip=$(kubectl --context="$SRC_CONTEXT" get pod "$src_pod" -o jsonpath="{.status.podIP}")
dst_ip=$(kubectl --context="$DST_CONTEXT" get pod "$dst_pod" -o jsonpath="{.status.podIP}")

echo "=== Topology Information ==="
echo "src_pod: $src_pod (IP: $src_ip)"
echo "dst_pods: $dst_pods"
echo "last dst_pod: $dst_pod (IP: $dst_ip)"

echo "=== Syncing repro script to pods ==="
kubectl --context="$SRC_CONTEXT" cp "$REPRO_PY" "$src_pod":/tmp/raiden_pathways_direct_api_repro.py -c proc
for dp in $dst_pods; do
  echo "Copying to dst pod $dp..."
  kubectl --context="$DST_CONTEXT" cp "$REPRO_PY" "$dp":/tmp/raiden_pathways_direct_api_repro.py -c proc
done

echo "=== Cleaning old processes on all pods ==="
kubectl --context="$SRC_CONTEXT" exec "$src_pod" -c proc -- /opt/venv/bin/python -c "import os, signal; [os.kill(int(p), signal.SIGKILL) for p in os.listdir(\"/proc\") if p.isdigit() and int(p) != os.getpid() and os.path.exists(f\"/proc/{p}/cmdline\") and \"python\" in open(f\"/proc/{p}/cmdline\", errors=\"ignore\").read()]" || true
kubectl --context="$SRC_CONTEXT" exec "$src_pod" -c proc -- rm -f /tmp/direct_api_*.log

for dp in $dst_pods; do
  kubectl --context="$DST_CONTEXT" exec "$dp" -c proc -- /opt/venv/bin/python -c "import os, signal; [os.kill(int(p), signal.SIGKILL) for p in os.listdir(\"/proc\") if p.isdigit() and int(p) != os.getpid() and os.path.exists(f\"/proc/{p}/cmdline\") and \"python\" in open(f\"/proc/{p}/cmdline\", errors=\"ignore\").read()]" || true &
done
wait

for dp in $dst_pods; do
  kubectl --context="$DST_CONTEXT" exec "$dp" -c proc -- rm -f /tmp/direct_api_*.log &
done
wait

echo "=== Launching destination workers concurrently ==="
for dp in $dst_pods; do
  kubectl --context="$DST_CONTEXT" exec "$dp" -c proc -- sh -lc "
    export RAIDEN_FAIL_ON_IDENTICAL_SLICE_PLANS=0
    export RAIDEN_LOG_DETAILED_SLICE_PLANS=1
    nohup /opt/venv/bin/python -u /tmp/raiden_pathways_direct_api_repro.py \
      --role=destination \
      --controller_address=${src_ip}:10019 \
      --num_src_hosts=4 \
      --num_dst_hosts=4 \
      > /tmp/direct_api_destination.log 2>&1 &
  " &
done
wait

echo "=== Waiting for destination workers to register ==="
sleep 10

echo "=== Launching source worker on $src_pod ==="
kubectl --context="$SRC_CONTEXT" exec "$src_pod" -c proc -- sh -lc "
  export RAIDEN_FAIL_ON_IDENTICAL_SLICE_PLANS=0
  export RAIDEN_LOG_DETAILED_SLICE_PLANS=1
  nohup /opt/venv/bin/python -u /tmp/raiden_pathways_direct_api_repro.py \
    --role=source \
    --controller_address=127.0.0.1:10019 \
    --num_src_hosts=4 \
    --num_dst_hosts=4 \
    > /tmp/direct_api_source.log 2>&1 &
"

echo "=== Running controller_src on $src_pod ==="
kubectl --context="$SRC_CONTEXT" exec "$src_pod" -c proc -- sh -lc "
  export RAIDEN_FAIL_ON_IDENTICAL_SLICE_PLANS=0
  export RAIDEN_LOG_DETAILED_SLICE_PLANS=1
  /opt/venv/bin/python -u /tmp/raiden_pathways_direct_api_repro.py \
    --role=controller_src \
    --controller_address=0.0.0.0:10019 \
    --num_src_hosts=4 \
    --num_dst_hosts=4 \
    --log_level=INFO \
    2>&1 | tee /tmp/direct_api_controller_src.log
" || echo "controller_src exited with status $?"

echo "=== Waiting 5s for destination H2D and verification ==="
sleep 10

echo "=== Source worker log ==="
kubectl --context="$SRC_CONTEXT" exec "$src_pod" -c proc -- cat /tmp/direct_api_source.log

echo "=== Destination logs on dst pods ==="
for dp in $dst_pods; do
  echo "--- Dst pod: $dp ---"
  kubectl --context="$DST_CONTEXT" exec "$dp" -c proc -- cat /tmp/direct_api_destination.log || true
done
