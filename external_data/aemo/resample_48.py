#!/usr/bin/env python3
"""AEMO validation data, normalized to the Ausgrid unit convention.
Input:  aemo/validation/<region>/{train,test}.csv   (5min, z in MW, $/MWh)
Output: aemo/validation48/<region>/{train,test}.csv (30min, z in kW, $/kWh)
  z_kW  = mean of 6 consecutive 5min z  * 1000
  price = mean of 6 5min prices         / 1000   ($/MWh -> $/kWh)
Battery per region scaled to its mean demand using the Ausgrid site ratio
(power = 5x mean z, capacity = 2.7h x power), so the arbitrage problem is
comparable to the household-scale validation.
"""
import csv, os, json
from datetime import datetime, timedelta

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, 'validation')
OUT = os.path.join(BASE, 'validation48')
REGIONS = ['NSW1', 'VIC1', 'QLD1', 'SA1', 'TAS1']

def ceil_30min(ts):
    """Round an AEMO 5-min end label up to the next 30-min grid boundary
    (:00 / :30). The daily last block [23:30..23:55] labels roll to 00:00."""
    dt = datetime.fromisoformat(ts)
    m = dt.minute
    if m == 0 or m == 30:
        return ts
    dt2 = dt + timedelta(minutes=(30 - m % 30))
    return dt2.isoformat()

def resample(split):
    out_all = {}
    for r in REGIONS:
        sp = os.path.join(SRC, r, f'{split}.csv')
        if not os.path.isfile(sp):
            print(f'{r}/{split}: missing, skip'); continue
        os.makedirs(os.path.join(OUT, r), exist_ok=True)
        with open(sp) as f:
            rows = list(csv.DictReader(f))
        out_rows = []
        for i in range(0, len(rows), 6):
            blk = rows[i:i+6]
            if len(blk) < 6:
                continue
            z_kw = sum(float(b['z']) for b in blk) / 6 * 1000.0
            buy = sum(float(b['price_buy']) for b in blk) / 6 / 1000.0
            sell = sum(float(b['price_sell']) for b in blk) / 6 / 1000.0
            ts = ceil_30min(blk[-1]['timestamp'])
            out_rows.append((ts, z_kw, buy, sell))
        with open(os.path.join(OUT, r, f'{split}.csv'), 'w') as f:
            f.write('timestamp,z,price_buy,price_sell\n')
            for ts, z, buy, sell in out_rows:
                f.write(f'{ts},{z:.1f},{buy:.6f},{sell:.6f}\n')
        out_all[r] = out_rows
        print(f'{r}/{split}: {len(out_rows)} rows (30min, kW)')
    return out_all

train_rows = resample('train')
resample('test')

# battery scaled per region from train mean z (Ausgrid ratio: power=5x mean, cap=2.7h x power)
for r in REGIONS:
    d = os.path.join(OUT, r)
    if not os.path.isdir(d):
        continue
    rows = train_rows.get(r, [])
    if not rows:
        continue
    z_mean_kw = sum(x[1] for x in rows) / len(rows)
    power_kw = round(5.0 * z_mean_kw, -2)
    capacity_kwh = round(2.7 * power_kw, -2)
    with open(os.path.join(d, 'battery.json'), 'w') as f:
        json.dump({"power_kw": power_kw, "capacity_kwh": capacity_kwh,
                   "charge_eff": 0.95, "discharge_eff": 0.95}, f)
    print(f'{r}: battery power={power_kw:.0f} kW ({power_kw/1000:.0f} MW), cap={capacity_kwh:.0f} kWh ({capacity_kwh/1e6:.0f} GWh)')
print('done ->', OUT)
