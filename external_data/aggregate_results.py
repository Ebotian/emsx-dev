#!/usr/bin/env python3
"""Aggregate validation results (per-site JSON) into visualization JSON:
  <dataset>/per_site_gain.json  -> [{site, dummy_cost, gains: {S_AR, R_P}}]
  <dataset>/curves.json         -> {sites: [{site, actual, ar1, persist}]}
Usage: aggregate_results.py <validation_dir> <out_dir>
"""
import json, os, sys, glob

val_dir, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

gain_rows = []
curves = []
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
    if 'curves' in r and r['curves'].get('actual'):
        curves.append({'site': site, **r['curves']})

with open(os.path.join(out_dir, 'per_site_gain.json'), 'w') as f:
    json.dump(gain_rows, f, indent=1)
with open(os.path.join(out_dir, 'curves.json'), 'w') as f:
    json.dump({'sites': curves}, f, indent=1)
print(f'sites: {len(gain_rows)} gain rows, {len(curves)} curves, {n_err} errors/skips')
print(f'-> {out_dir}/per_site_gain.json, {out_dir}/curves.json')
