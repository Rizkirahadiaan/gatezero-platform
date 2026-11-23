#!/usr/bin/env bash
# gatezero-platform — baseline benchmark VM
#
# Dijalankan DI DALAM VM yang diukur (bukan dari laptop), kecuali iperf3
# yang butuh satu VM lain sebagai server.
#
# Pemakaian:
#   ./run-all.sh baseline          # sebelum hardening / sebelum k8s
#   ./run-all.sh post-hardening    # sesudah hardening
#   ./run-all.sh post-k8s          # sesudah cluster jalan
#
# Output: JSON ringkas + file mentah fio, di ./results/

set -euo pipefail

LABEL="${1:-baseline}"
OUT_DIR="$(dirname "$0")/../results"
STAMP="$(date +%F)"
BASE="$OUT_DIR/${STAMP}-${LABEL}"
mkdir -p "$OUT_DIR" "$BASE"

log() { printf '\n\033[36m[bench]\033[0m %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "MISSING: $1"; return 1; }; }

summary="$BASE/summary.txt"
: > "$summary"

# ---------------------------------------------------------------- disk 4k
if need fio; then
  log "fio: 4k random write (IOPS + p99)"
  fio --name=4k-randwrite --rw=randwrite --bs=4k --iodepth=32 --numjobs=4 \
      --size=2G --runtime=60 --time_based --group_reporting \
      --output-format=json --output="$BASE/fio-4k-randwrite.json" >/dev/null
  grep -E '"iops"|"clat_ns"' "$BASE/fio-4k-randwrite.json" | head -20 >> "$summary" || true
fi

# ---------------------------------------------------------------- disk 64k
if need fio; then
  log "fio: 64k sequential read (MB/s)"
  fio --name=64k-seqread --rw=read --bs=64k --iodepth=16 --numjobs=2 \
      --size=2G --runtime=60 --time_based --group_reporting \
      --output-format=json --output="$BASE/fio-64k-seqread.json" >/dev/null
fi

# ---------------------------------------------------------------- cpu
if need sysbench; then
  log "sysbench: CPU"
  sysbench cpu --threads="$(nproc)" --time=30 run | tee "$BASE/sysbench-cpu.txt" >> "$summary"
fi

# ---------------------------------------------------------------- mem
if need sysbench; then
  log "sysbench: memory"
  sysbench memory --memory-block-size=1M --memory-total-size=10G run \
    | tee "$BASE/sysbench-memory.txt" >> "$summary"
fi

# ---------------------------------------------------------------- network
if need iperf3 && [[ -n "${IPERF_SERVER:-}" ]]; then
  log "iperf3: throughput ke $IPERF_SERVER"
  iperf3 -c "$IPERF_SERVER" -P 4 -t 20 -J > "$BASE/iperf3.json" || true
else
  log "iperf3: dilewati (set IPERF_SERVER=<ip> dan jalankan 'iperf3 -s' di peer)"
fi

if need sockperf && [[ -n "${SOCKPERF_SERVER:-}" ]]; then
  log "sockperf: latency"
  sockperf ping-pong -i "$SOCKPERF_SERVER" -t 10 > "$BASE/sockperf.txt" 2>&1 || true
fi

# ---------------------------------------------------------------- etcd
if need etcdctl && [[ -f /etc/kubernetes/admin.conf ]]; then
  log "etcd: check perf"
  sudo env ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    check perf 2>&1 | tee "$BASE/etcd-check-perf.txt" >> "$summary" || true

  sudo env ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint status -w table > "$BASE/etcd-endpoint-status.txt" 2>&1 || true
fi

# ---------------------------------------------------------------- context
{
  echo "=== host ==="
  hostnamectl 2>/dev/null | sed -n '1,12p' || true
  echo
  echo "=== kernel ==="
  uname -r
  echo
  echo "=== disk ==="
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true
  echo
  echo "=== cpu ==="
  lscpu | grep -E 'Model name|^CPU\(s\)|Thread|MHz' || true
  echo
  echo "=== mem ==="
  free -h || true
} > "$BASE/context.txt" 2>&1

log "selesai -> $BASE"
echo
echo "Ringkasan tersimpan di: $summary"
echo "Commit hasil ini ke repo: git add $BASE && git commit -m 'bench($LABEL): $STAMP'"
