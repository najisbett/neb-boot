#!/usr/bin/env bash
# Process-farm NEB worker: PPF miner processes per GPU. The 65,535 attempts/s
# ceiling is per process, so throughput scales with process count (and per-GPU
# headroom), not with how expensive the card is.
set -uo pipefail
TOPIC="neb-probe-941699db"
LOCK="80884ccafc06ca24b18d4436220798de74927d64d49344873b95b9d5698472bb"
PPF="${PPF:-2}"
OUT=/root/neb-farm
mkdir -p "$OUT"; cd "$OUT"

say() { curl -sS -m 15 -H "Title: $1" -d "$2" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1; }

work() {
  GNU=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
  say "farm boot" "run=${RUN_ID:-none} gpus=$GNU procs_per_gpu=$PPF $(nvidia-smi --query-gpu=name --format=csv,noheader | tr '\n' ' ')"

  python3 - <<'PY'
import urllib.request, tarfile, zipfile, os
rel = "https://github.com/SilasEigen/neb/releases/download/v1.0.1"
for name, kind in [("neb-1.0.1-linux-x86_64.tar.gz","tar"), ("nebminer-1.0.1.tar.gz","tar"), ("neb-datasets.zip","zip")]:
    urllib.request.urlretrieve(f"{rel}/{name}", name)
    if kind == "tar":
        with tarfile.open(name) as t: t.extractall(".")
    else:
        with zipfile.ZipFile(name) as z: z.extractall(".")
print("ok")
PY
  chmod +x neb-node neb-miner-gpu 2>/dev/null

  ./neb-miner-gpu --selftest --dataset neb-datasets.bin > selftest.log 2>&1
  say "farm selftest" "rc=$? :: $(tail -2 selftest.log | tr '\n' ' ' | cut -c1-200)"

  nohup ./neb-node --run --dataset neb-datasets.bin --datadir data --miner-lock "$LOCK" > node.log 2>&1 &
  for i in $(seq 1 90); do
    sleep 10
    H=$(curl -sS -m 5 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getinfo","params":[]}' http://127.0.0.1:8432 2>/dev/null | head -c 120)
    if [ -n "$H" ]; then say "farm node" "up after $((i*10))s"; break; fi
  done

  for g in $(seq 0 $((GNU-1))); do
    for p in $(seq 1 $PPF); do
      nohup ./neb-miner-gpu --node 127.0.0.1:3441 --dataset neb-datasets.bin --devices "$g" --plain > "miner-g${g}p${p}.log" 2>&1 &
      sleep 1
    done
    say "farm miners" "gpu $g: $PPF processes started"
  done

  while true; do
    sleep 60
    TOT=0; SH=0; BL=0; LINE=""
    for f in miner-g*p*.log; do
      L=$(tail -1 "$f" 2>/dev/null)
      R=$(printf '%s' "$L" | grep -oE '[0-9]+ attempts/s' | grep -oE '[0-9]+')
      S=$(printf '%s' "$L" | grep -oE 'shares [0-9]+' | grep -oE '[0-9]+')
      B=$(printf '%s' "$L" | grep -oE 'blocks [0-9]+' | grep -oE '[0-9]+')
      [ -n "$R" ] && TOT=$((TOT+R)) && LINE="$LINE ${f#miner-}:$R"
      [ -n "$S" ] && SH=$((SH+S))
      [ -n "$B" ] && BL=$((BL+B))
    done
    say "farm rate" "total=$TOT/s shares=$SH blocks=$BL |$LINE"
  done
}

work >> boot.log 2>&1 &
echo "[onstart] farm backgrounded"
exit 0