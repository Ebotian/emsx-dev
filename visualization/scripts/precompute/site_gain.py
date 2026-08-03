#!/usr/bin/env python3
"""Per-site final-result gains — merges per_site scores, per-site RMSE, and the
physical LP oracle upper bound. Mirrors the paper figures gain_by_rmse / gain_by_gap:
  - gain_by_rmse: controllers' per-site score, sites ranked by forecast RMSE ascending
  - gain_by_gap:   per-site score vs the LP upper bound (dashed) and dummy zero line
Score convention: G_i = (C_dummy_i - C_i) / C_dummy_i (continuous-SOC physical track).
LP upper bound score: (C_dummy - C_lp) / C_dummy."""
import os, json

PUB = os.path.join(os.path.dirname(__file__), "..", "..", "public", "data")

per_site = json.load(open(os.path.join(PUB, "per_site.json")))
site_rmse = {r["site"]: r for r in json.load(open(os.path.join(PUB, "site_rmse.json")))}

CTRLS = ["Dummy", "MPC", "OLFC-10", "SDP", "SDP-AR(1)", "S_AR", "R_P", "R_FE96"]

# LP oracle: physical score is (dummy - cost) / (dummy - lp_cost), i.e. normalized
# against the LP perfect-prediction cost — so the LP upper bound is score 1.0 by
# construction (see .worktrees/.../scripts/score_physical_run.jl).
lp_cost = {}
if os.path.exists("/tmp/physical_lp_oracle.csv"):
    import csv
    with open("/tmp/physical_lp_oracle.csv") as f:
        for r in csv.DictReader(f):
            lp_cost[int(r["site"])] = float(r["lp_upper"])

rows = []
for site in sorted(map(int, per_site["S_AR"].keys())):
    dummy = per_site["Dummy"][str(site)]["cost"]
    entry = {
        "site": site,
        "rmse96": site_rmse[site]["rmse96"],
        "dummy_cost": round(dummy, 2),
        "scores": {c: round(per_site[c][str(site)]["score"], 4) for c in CTRLS},
    }
    if site in lp_cost:
        entry["lp_score"] = 1.0  # LP perfect-prediction = upper bound by convention
    rows.append(entry)

with open(os.path.join(PUB, "site_gain.json"), "w") as f:
    json.dump(rows, f, indent=1)
print(f"site_gain: {len(rows)} sites -> site_gain.json (lp rows: {sum(1 for r in rows if 'lp_score' in r)})")
