#!/usr/bin/env python3
"""Per-site net-demand forecast RMSE over all 70 sites, ranked — mirrors
Figure 3 of the EMSx paper (arXiv:2001.00450). Uses training data, day-ahead
horizon (h=96) plus the all-horizon mean RMSE for reference."""
import gzip, csv, os, json
import numpy as np

ROOT = os.environ.get("EMSX_DATA_ROOT", os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "..")))
TRAIN = os.path.join(ROOT, "dataset", "train")
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "public", "data", "site_rmse.json")

H = 96
sites = []
for sid in range(1, 71):
    with gzip.open(os.path.join(TRAIN, f"{sid}.csv.gz"), "rt") as f:
        rows = list(csv.DictReader(f))
    n = len(rows)
    actual = np.array([float(r["actual_consumption"]) - float(r["actual_pv"]) for r in rows])
    rmse_by_h = {}
    for k in (1, H):
        fk = np.array([float(r[f"load_{k-1:02d}"]) - float(r[f"pv_{k-1:02d}"]) for r in rows])
        i_lo, i_hi = 1, n - 1 - k
        if i_hi <= i_lo:
            continue
        a = actual[k + 1: n]
        f = fk[1: n - k]
        rmse_by_h[k] = float(np.sqrt(np.mean((a - f) ** 2)))
    sites.append({
        "site": sid,
        "rmse96": round(rmse_by_h.get(H, float("nan")), 4),  # 24h-ahead, paper Figure 3 analogue
        "rmse1": round(rmse_by_h.get(1, float("nan")), 4),   # 15min-ahead reference
    })

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(sites, f, indent=1)
print(f"site_rmse: {len(sites)} sites -> {OUT}")
