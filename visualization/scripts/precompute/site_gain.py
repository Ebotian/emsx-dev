#!/usr/bin/env python3
"""Per-site final-result gains — mirrors the paper figures gain_by_rmse / gain_by_gap.
Gain convention (paper eq. for the gain): G_i(phi) = dummy_cost_i - cost_i(phi)
(absolute saving over the no-battery dummy). The perfect-prediction upper bound is
G_bar_i = dummy_cost_i - lp_cost_i where lp_cost_i is the physical LP oracle cost
(per-site, may be negative on net-exporting sites). Sites can be ranked by the 24h
forecast RMSE (gain_by_rmse) or by site id (gain_by_gap)."""
import os, json

PUB = os.path.join(os.path.dirname(__file__), "..", "..", "public", "data")

per_site = json.load(open(os.path.join(PUB, "per_site.json")))
site_rmse = {r["site"]: r for r in json.load(open(os.path.join(PUB, "site_rmse.json")))}

CTRLS = ["Dummy", "MPC", "OLFC-10", "SDP", "SDP-AR(1)", "S_AR", "R_P", "R_FE96"]

# physical LP oracle cost per site (official scoring convention)
lp_cost = {}
if os.path.exists("/tmp/physical_lp_oracle.csv"):
    import csv
    with open("/tmp/physical_lp_oracle.csv") as f:
        for r in csv.DictReader(f):
            lp_cost[int(r["site"])] = float(r["lp_upper"])

rows = []
for site in sorted(map(int, per_site["S_AR"].keys())):
    dummy = per_site["Dummy"][str(site)]["cost"]
    gains = {c: round(dummy - per_site[c][str(site)]["cost"], 4) for c in CTRLS}
    entry = {
        "site": site,
        "rmse96": site_rmse[site]["rmse96"],
        "dummy_cost": round(dummy, 2),
        "gains": gains,                       # saving vs dummy per controller
    }
    if site in lp_cost:
        entry["lp_gain"] = round(dummy - lp_cost[site], 4)  # perfect-prediction upper bound gain
    rows.append(entry)

with open(os.path.join(PUB, "site_gain.json"), "w") as f:
    json.dump(rows, f, indent=1)
lp_n = sum(1 for r in rows if "lp_gain" in r)
print(f"site_gain: {len(rows)} sites -> site_gain.json (lp_gain rows: {lp_n})")
