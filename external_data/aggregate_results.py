#!/usr/bin/env python3
"""Aggregate validation results (per-site JSON) into visualization JSON:
  <dataset>/per_site_gain.json  -> [{site, dummy_cost, gains: {S_AR, R_P}}]
  <dataset>/curves.json         -> {sites: [{site, actual, ar1, persist}]}
  <dataset>/forecast_error.json -> [{site, persist_rmse, ar1_rmse}]  (RMSE of the
      one-step forecasts over the curve window, all aligned to the target slot)
Usage: aggregate_results.py <validation_dir> <out_dir>
"""
import json, os, sys, glob

val_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

gain_rows = []
curves = []
err_rows = []
n_err = 0
for fp in sorted(glob.glob(os.path.join(val_dir, 'results', '*.json'))):
    site = os.path.basename(fp).replace('.json', '')
    try:
        r = json.load(open(fp))
    except Exception:
        n_err += 1
        continue
    if 'error' in r:
        n_err += 1
        continue
    gain_rows.append({
        'site': site,
        'dummy_cost': r['cost']['dummy'],
        'gains': {'S_AR': r['gain']['sdp'], 'R_P': r['gain']['rp']},
    })
    c = r.get('curves', {})
    act, per, ar1 = c.get('actual'), c.get('persist'), c.get('ar1')
    if act and per and ar1:
        curves.append({'site': site, **c})
        n = min(len(act), len(per), len(ar1))
        if n > 1:
            rp = (sum((act[t] - per[t]) ** 2 for t in range(1, n)) / (n - 1)) ** 0.5
            ra = (sum((act[t] - ar1[t]) ** 2 for t in range(1, n)) / (n - 1)) ** 0.5
            err_rows.append({'site': site, 'persist_rmse': round(rp, 3), 'ar1_rmse': round(ra, 3)})

with open(os.path.join(out_dir, 'per_site_gain.json'), 'w') as f:
    json.dump(gain_rows, f, indent=1)
with open(os.path.join(out_dir, 'curves.json'), 'w') as f:
    json.dump({'sites': curves}, f, indent=1)
with open(os.path.join(out_dir, 'forecast_error.json'), 'w') as f:
    json.dump(err_rows, f, indent=1)
print(f'sites: {len(gain_rows)} gain rows, {len(curves)} curves, {len(err_rows)} forecast errors, {n_err} errors/skips')
print(f'-> {out_dir}/per_site_gain.json, {out_dir}/curves.json, {out_dir}/forecast_error.json')
