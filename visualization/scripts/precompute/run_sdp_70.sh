#!/bin/bash
# SDP 70 sites, parallel julia processes (local), output JSON.
set -e
SCRIPT="$(cd "$(dirname "$0")" && pwd)/paper_sdp.jl"
DIR="$(dirname "$SCRIPT")"
ROOT=/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research
OUT="$DIR/../../public/data/paper_sdp_raw.json"
mkdir -p "$(dirname "$OUT")"
cd "$ROOT"
seq 1 70 | xargs -P 12 -I{} sh -c 'julia --startup-file=no --project=. "'"$SCRIPT"'" {} 2>/dev/null | sed -n "s/^SDP site {} mean period cost = //p" > /tmp/sdp_site_{}.txt' 
python3 - <<PYEOF
import json, os, re
costs = {}
for s in range(1, 71):
    p = f"/tmp/sdp_site_{s}.txt"
    if os.path.exists(p):
        t = open(p).read().strip()
        if t:
            costs[str(s)] = float(t)
print("sites done:", len(costs))
json.dump(costs, open("$OUT", "w"))
PYEOF
echo "SDP 70 done -> $OUT"
