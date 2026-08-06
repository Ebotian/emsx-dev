#!/usr/bin/env python3
"""Prepare Ausgrid Solar Home data for SDP-AR(1) validation.
Net demand = GC (gross consumption) - GG (gross solar generation), 30-min.
Output: processed/net_demand/<customer>.csv (timestamp, net_demand_kw)
License: CC BY 3.0 AU (source: Ausgrid via pierreh.eu mirror).
"""
import csv, os
from datetime import datetime, timedelta

YEARS = ['2010-2011', '2011-2012', '2012-2013']
BASE = os.path.dirname(os.path.abspath(__file__))

MONTHS = {'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
          'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12}

def parse_date(s):
    s = s.strip()
    for fmt in ('%d/%m/%Y', '%d/%m/%y'):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            pass
    try:  # '1-Jul-10'
        day, mon, yr = s.split('-')
        return datetime(2000 + int(yr), MONTHS[mon], int(day))
    except Exception:
        raise ValueError(f'unparseable date: {s!r}')

# (customer, date) -> {cat: [48 values]}
data = {}
for year in YEARS:
    with open(os.path.join(BASE, f'Solar home {year}.csv')) as f:
        rows = list(csv.reader(f))
    for r in rows[2:]:
        if len(r) < 53 or not r[0].strip():
            continue
        key = (r[0].strip(), parse_date(r[4]))
        vals = [float(v) if v.strip() else 0.0 for v in r[5:53]]
        data.setdefault(key, {})[r[3].strip()] = vals

out_dir = os.path.join(BASE, 'processed', 'net_demand')
os.makedirs(out_dir, exist_ok=True)

custs = sorted({k[0] for k in data})
rows_written = 0
missing = 0
for cust in custs:
    dates = sorted({k[1] for k in data if k[0] == cust})
    path = os.path.join(out_dir, f'{cust}.csv')
    with open(path, 'w') as f:
        f.write('timestamp,net_demand_kw\n')
        for d in dates:
            gc = data.get((cust, d), {}).get('GC')
            gg = data.get((cust, d), {}).get('GG')
            if gc is None or gg is None:
                missing += 1
                continue
            for i in range(48):  # 30*(i+1) min: 0:30 .. 24:00 (next day 0:00)
                ts = d + timedelta(minutes=30 * (i + 1))
                f.write(f'{ts.isoformat()},{gc[i] - gg[i]:.4f}\n')
                rows_written += 1

print(f'customers: {len(custs)}, rows written: {rows_written}, missing GC/GG days: {missing}')
print(f'output: {out_dir}/<customer>.csv (30-min net demand = GC - GG)')
