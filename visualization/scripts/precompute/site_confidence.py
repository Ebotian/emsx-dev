#!/usr/bin/env python3
"""Per-site forecast confidence (% R2) vs elapsed forecast time — 70-site curve family.
Each site yields R2 (%) at sampled horizons (every 2 steps = 30min), training data.
Also aggregates the median / P5 / P95 envelope for the front-end."""
import gzip, csv, os, json
import numpy as np

ROOT = os.environ.get("EMSX_DATA_ROOT", os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "..")))
TRAIN = os.path.join(ROOT, "dataset", "train")
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "public", "data", "site_confidence.json")

H = 96
STEP = 1                        # every horizon (15 min) — full granularity
HORIZONS = list(range(1, H + 1, STEP))
HORIZONS[-1] = H               # last sample is exactly 24h

rows_out = []                  # {site, horizon, minutes, r2}
for sid in range(1, 71):
    with gzip.open(os.path.join(TRAIN, f"{sid}.csv.gz"), "rt") as f:
        rows = list(csv.DictReader(f))
    n = len(rows)
    actual = np.array([float(r["actual_consumption"]) - float(r["actual_pv"]) for r in rows])
    denom = float(np.sum((actual - actual.mean()) ** 2))
    for k in HORIZONS:
        fk = np.array([float(r[f"load_{k-1:02d}"]) - float(r[f"pv_{k-1:02d}"]) for r in rows])
        i_lo, i_hi = 1, n - 1 - k
        if i_hi <= i_lo:
            continue
        a = actual[k + 1: n]
        f = fk[1: n - k]
        se = float(np.sum((a - f) ** 2))
        r2 = 1.0 - se / denom
        rows_out.append({
            "site": sid,
            "horizon": k,
            "minutes": k * 15,
            "r2": round(r2, 4),
        })

# envelope: median / P5 / P95 across sites per horizon
env = {}
for hz in HORIZONS:
    vals = sorted(r["r2"] for r in rows_out if r["horizon"] == hz)
    env[hz] = {
        "minutes": hz * 15,
        "median": round(float(np.median(vals)), 4),
        "p5": round(float(np.percentile(vals, 5)), 4),
        "p95": round(float(np.percentile(vals, 95)), 4),
    }

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump({"sites": rows_out, "envelope": [env[h] for h in HORIZONS]}, f, indent=1)

med15 = env[1]["median"] * 100
med96 = env[H]["median"] * 100
print(f"site_confidence: {len(rows_out)} points ({len(HORIZONS)} horizons x 70 sites) -> {OUT}")
print(f"  median confidence: 15min = {med15:.1f}%, 24h = {med96:.1f}%")
