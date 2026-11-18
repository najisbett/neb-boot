#!/usr/bin/env bash
# Runs inside a rented GPU container (Vast onstart fetches and executes this).
# No SSH, no inbound ports: binaries come from GitHub, logs go back over ntfy.sh.
set -uo pipefail
TOPIC="neb-probe-941699db"
LOCK="80884ccafc06ca24b18d4436220798de74927d64d49344873b95b9d5698472bb"
REL="https://github.com/SilasEigen/neb/releases/download/v1.0.1"
OUT=/root/neb-run
mkdir -p "$OUT"
cd "$OUT"

say() { curl -sS -m 15 -H "Title: $1" -d "$2" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1; }

work() {
  echo "[boot] fetching"
  python3 - <<'PY'
import urllib.request, tarfile, zipfile, os
rel = "https://github.com/SilasEigen/neb/releases/download/v1.0.1"
files = [("neb-1.0.1-linux-x86_64.tar.gz", "tar"), ("nebminer-1.0.1.tar.gz", "tar"), ("neb-datasets.zip", "zip")]
for name, kind in files:
    urllib.request.urlretrieve(f"{rel}/{name}", name)
    if kind == "tar":
        with tarfile.open(name) as t: t.extractall(".")
    else:
        with zipfile.ZipFile(name) as z: z.extractall(".")
print("files:", sorted(os.listdir(".")))
PY
  chmod +x neb-node neb-miner-gpu 2>/dev/null
  say "neb boot" "files ready: $(ls neb-node neb-miner-gpu neb-datasets.bin 2>/dev/null | tr '\n' ' ')"

  ./neb-miner-gpu --selftest --dataset neb-datasets.bin > selftest.log 2>&1
  say "neb selftest" "rc=$? :: $(tail -3 selftest.log | tr '\n' ' ' | cut -c1-300)"

  nohup ./neb-node --run --dataset neb-datasets.bin --datadir data --miner-lock "$LOCK" > node.log 2>&1 &
  for i in $(seq 1 90); do
    sleep 10
    H=$(curl -sS -m 5 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getinfo","params":[]}' http://127.0.0.1:8432 2>/dev/null | head -c 160)
    if [ -n "$H" ]; then say "neb node" "up after $((i*10))s :: ${H:0:120}"; break; fi
  done

  nohup ./neb-miner-gpu --node 127.0.0.1:3441 --dataset neb-datasets.bin --plain > miner.log 2>&1 &
  say "neb miner" "started $(date -u +%H:%M:%SZ)"

  while true; do
    sleep 60
    say "neb hashrate" "$(tail -2 miner.log 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
  done
}

work >> boot.log 2>&1 &
echo "[onstart] backgrounded"
exit 0