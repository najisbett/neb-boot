#!/usr/bin/env bash
# CPU-parallel NEB worker for a many-core rental.
# Logs go back over ntfy.sh; nothing needs an inbound port.
set -uo pipefail
TOPIC="neb-probe-941699db"
LOCK="80884ccafc06ca24b18d4436220798de74927d64d49344873b95b9d5698472bb"
OUT=/root/neb-cpu
mkdir -p "$OUT"; cd "$OUT"

say() { curl -sS -m 15 -H "Title: $1" -d "$2" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1; }

work() {
  NPROC=$(nproc)
  THREADS=$(( NPROC > 4 ? NPROC - 2 : 2 ))
  say "neb cpu boot" "cores=$NPROC threads=$THREADS $(date -u +%H:%M:%SZ)"

  python3 - <<'PY'
import urllib.request, tarfile, zipfile, os
rel = "https://github.com/SilasEigen/neb/releases/download/v1.0.1"
for name, kind in [("neb-1.0.1-linux-x86_64.tar.gz","tar"), ("nebminer-1.0.1.tar.gz","tar"), ("neb-datasets.zip","zip")]:
    urllib.request.urlretrieve(f"{rel}/{name}", name)
    if kind == "tar":
        with tarfile.open(name) as t: t.extractall(".")
    else:
        with zipfile.ZipFile(name) as z: z.extractall(".")
print(sorted(os.listdir(".")))
PY
  chmod +x neb-node neb-miner-cpu 2>/dev/null
  say "neb cpu files" "$(ls neb-node neb-miner-cpu neb-datasets.bin 2>/dev/null | tr '\n' ' ')"

  taskset -c 0,1 nohup ./neb-node --run --dataset neb-datasets.bin --datadir data --miner-lock "$LOCK" > node.log 2>&1 &
  for i in $(seq 1 90); do
    sleep 10
    H=$(curl -sS -m 5 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getinfo","params":[]}' http://127.0.0.1:8432 2>/dev/null | head -c 140)
    if [ -n "$H" ]; then say "neb cpu node" "up after $((i*10))s"; break; fi
  done

  nohup ./neb-miner-cpu --node 127.0.0.1:3441 --dataset neb-datasets.bin --threads "$THREADS" --engine table --plain > miner.log 2>&1 &
  say "neb cpu miner" "started threads=$THREADS $(date -u +%H:%M:%SZ)"

  while true; do
    sleep 60
    say "neb cpu rate" "$(tail -2 miner.log 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
  done
}

work >> boot.log 2>&1 &
echo "[onstart] cpu worker backgrounded"
exit 0