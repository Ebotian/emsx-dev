#!/usr/bin/env python3
"""Precompute forecast accuracy/confidence vs horizon (1..96) over all 70
sites (training data). Metrics: RMSE/MAE/bias/R2; empirical coverage of
nominal 50/80/95% intervals (residual-quantile based)."""
import gzip, csv, os, json
import numpy as np

ROOT = os.environ.get("EMSX_DATA_ROOT", "/home/ebt/Downloads/emsx/.worktrees/orthogonal80-research")
TRAIN = os.path.join(ROOT, "dataset", "train")
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "public", "data", "accuracy.json")

H = 96
errs = {k: [] for k in range(1, H + 1)}
acts = {k: [] for k in range(1, H + 1)}

for sid in range(1, 71):
    with gzip.open(os.path.join(TRAIN, f"{sid}.csv.gz"), "rt") as f:
        rows = list(csv.DictReader(f))
    n = len(rows)
    actual = np.array([float(r["actual_consumption"]) - float(r["actual_pv"]) for r in rows])
    for k in range(1, H + 1):
        fk = np.array([float(r[f"load_{k-1:02d}"]) - float(r[f"pv_{k-1:02d}"]) for r in rows])
        # forecast at row i predicts row i+k+1 (0-based index i+k); valid i in [1, n-1-k]
        i_lo, i_hi = 1, n - 1 - k
        if i_hi <= i_lo:
            continue
        a = actual[k + 1 : n]              # actual[i+k+1], i from 1 -> idx k+1 .. n-1
        f = fk[1 : n - k]                  # fk[i], i from 1
        errs[k].extend((a - f).tolist())
        acts[k].extend(a.tolist())

points = []
for k in range(1, H + 1):
    e = np.array(errs[k])
    a = np.array(acts[k])
    if len(e) < 100:
        continue
    se = e**2
    r2 = 1.0 - float(se.sum()) / float(((a - a.mean()) ** 2).sum())
    def cov(q):
        lo, hi = np.quantile(e, (1 - q) / 2), np.quantile(e, (1 + q) / 2)
        return float(np.mean((e >= lo) & (e <= hi)))
    points.append({
        "horizon": k,
        "rmse": round(float(np.sqrt(se.mean())), 4),
        "mae": round(float(np.abs(e).mean()), 4),
        "bias": round(float(e.mean()), 4),
        "r2": round(r2, 4),
        "cov50": round(cov(0.50), 4),
        "cov80": round(cov(0.80), 4),
        "cov95": round(cov(0.95), 4),
    })

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(points, f, indent=1)
print(f"accuracy: {len(points)} horizons -> {OUT}")
for h in (1, 24, 48, 96):
    p = next((x for x in points if x["horizon"] == h), None)
    if p:
        print(f"  h={h}: rmse={p['rmse']} r2={p['r2']} cov95={p['cov95']}")
