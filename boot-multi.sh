#!/usr/bin/env bash
# Two-GPU NEB worker: one miner process per GPU, reports both rates over ntfy.
set -uo pipefail
TOPIC="neb-probe-941699db"
LOCK="80884ccafc06ca24b18d4436220798de74927d64d49344873b95b9d5698472bb"
OUT=/root/neb-multi
mkdir -p "$OUT"; cd "$OUT"

say() { curl -sS -m 15 -H "Title: $1" -d "$2" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1; }

work() {
  GNU=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
  say "neb multi boot" "gpus=$GNU $(nvidia-smi --query-gpu=name --format=csv,noheader | tr '\n' ' ')"

  python3 - <<'PY'
import urllib.request, tarfile, zipfile, os
rel = "https://github.com/SilasEigen/neb/releases/download/v1.0.1"
for name, kind in [("neb-1.0.1-linux-x86_64.tar.gz","tar"), ("nebminer-1.0.1.tar.gz","tar"), ("neb-datasets.zip","zip")]:
    urllib.request.urlretrieve(f"{rel}/{name}", name)
    if kind == "tar":
        with tarfile.open(name) as t: t.extractall(".")
    else:
        with zipfile.ZipFile(name) as z: z.extractall(".")
print("ok", sorted(os.listdir(".")))
PY
  chmod +x neb-node neb-miner-gpu 2>/dev/null

  ./neb-miner-gpu --selftest --dataset neb-datasets.bin > selftest.log 2>&1
  say "neb multi selftest" "rc=$? :: $(tail -3 selftest.log | tr '\n' ' ' | cut -c1-260)"
  if ! grep -q "SELFTEST PASSED" selftest.log; then
    say "neb multi abort" "selftest failed, not starting miners :: $(tail -5 selftest.log | tr '\n' ' ' | cut -c1-300)"
    return
  fi

  nohup ./neb-node --run --dataset neb-datasets.bin --datadir data --miner-lock "$LOCK" > node.log 2>&1 &
  for i in $(seq 1 90); do
    sleep 10
    H=$(curl -sS -m 5 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"getinfo","params":[]}' http://127.0.0.1:8432 2>/dev/null | head -c 120)
    if [ -n "$H" ]; then say "neb multi node" "up after $((i*10))s"; break; fi
  done

  for d in $(seq 0 $((GNU-1))); do
    nohup ./neb-miner-gpu --node 127.0.0.1:3441 --dataset neb-datasets.bin --devices "$d" --plain > "miner$d.log" 2>&1 &
    say "neb multi miner" "gpu $d started"
    sleep 2
  done

  while true; do
    sleep 60
    SUM=""
    for d in $(seq 0 $((GNU-1))); do
      R=$(tail -1 "miner$d.log" 2>/dev/null | tr -s ' ')
      SUM="$SUM | gpu$d: $R"
    done
    say "neb multi rate" "${SUM:0:400}"
  done
}

work >> boot.log 2>&1 &
echo "[onstart] multi worker backgrounded"
exit 0