#!/usr/bin/env python3
"""Convert AEMO NEM data to validation site format.
Inputs:
  - ARCHIVE daily package: raw/extracted/*.zip (288 5-min DispatchIS reports/day)
  - MMSDM monthly packages: raw/mmsdm/*.zip (SQL-loader MMS format)
Parses DISPATCH.PRICE (RRP) and DISPATCH.REGIONSUM (TOTALDEMAND) per region.
Output per region (NSW1/VIC1/QLD1/SA1/TAS1): validation/<region>/{train,test}.csv
  columns: timestamp,z,price_buy,price_sell   (z = TOTALDEMAND MW, price $/MWh)
TOU: buy = max(RRP,0)+5, sell = max(RRP,0)-2 (min 0)  [$/MWh spread]
Train/test: last 20% of available days = test.
"""
import zipfile, csv, io, os, sys
from datetime import datetime, timedelta

BASE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(BASE, 'raw')
OUT = os.path.join(BASE, 'validation')
REGIONS = ['NSW1', 'VIC1', 'QLD1', 'SA1', 'TAS1']

def parse_mms(text):
    """Return dict (region) -> list of (datetime, rrp, totaldemand)."""
    rows = {r: [] for r in REGIONS}
    tables = {}
    for ln in text.splitlines():
        if ln.startswith('I,'):
            p = ln.split(',')
            tables[f"{p[1]}.{p[2]}"] = p[4:]
        elif ln.startswith('D,'):
            p = ln.split(',')
            hdr = tables.get(f"{p[1]}.{p[2]}", [])
            d = dict(zip(hdr, p[4:4+len(hdr)]))
            region = d.get('REGIONID', '').strip('"')
            if region not in REGIONS:
                continue
            ts = datetime.strptime(d.get('SETTLEMENTDATE', '').strip('"'), '%Y/%m/%d %H:%M:%S')
            if f"{p[1]}.{p[2]}" == 'DISPATCH.PRICE':
                try:
                    rrp = float(d.get('RRP', ''))
                except ValueError:
                    rrp = 0.0
                # store with placeholder demand; merge later
                rows[region].append([ts, rrp, None])
            elif f"{p[1]}.{p[2]}" == 'DISPATCH.REGIONSUM':
                try:
                    td = float(d.get('TOTALDEMAND', ''))
                except ValueError:
                    td = 0.0
                rows[region].append([ts, None, td])
    # merge price and demand by timestamp
    merged = {r: {} for r in REGIONS}
    for r in REGIONS:
        for ts, rrp, td in rows[r]:
            if rrp is not None:
                merged[r].setdefault(ts, {})['rrp'] = rrp
            if td is not None:
                merged[r].setdefault(ts, {})['td'] = td
    return merged

def process_zip(path):
    merged = {r: {} for r in REGIONS}
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        return merged
    for name in z.namelist():
        if not name.lower().endswith('.csv'):
            continue
        try:
            text = z.read(name).decode('utf-8-sig')
        except Exception:
            continue
        m = parse_mms(text)
        for r in REGIONS:
            merged[r].update(m[r])
    return merged

def price(row):
    rrp = row.get('rrp', 0.0)
    buy = max(rrp, 0.0) + 5.0
    sell = max(max(rrp, 0.0) - 2.0, 0.0)
    return buy, sell

def main():
    sources = []
    # ARCHIVE daily packages (extracted sub-zips)
    ex = os.path.join(RAW, 'extracted')
    if os.path.isdir(ex):
        sources += [os.path.join(ex, f) for f in os.listdir(ex) if f.endswith('.zip')]
    # MMSDM monthly packages
    mms = os.path.join(RAW, 'mmsdm')
    if os.path.isdir(mms):
        sources += [os.path.join(mms, f) for f in os.listdir(mms) if f.endswith('.zip')]
    print(f'sources: {len(sources)} files')

    all_rows = {r: {} for r in REGIONS}
    for src in sources:
        m = process_zip(src)
        for r in REGIONS:
            all_rows[r].update(m[r])
        if len(sources) <= 5:
            print(f'  {os.path.basename(src)}: {sum(len(v) for v in m.values())} timestamps')

    for r in REGIONS:
        ts_sorted = sorted(all_rows[r].keys())
        complete = [ts for ts in ts_sorted if 'rrp' in all_rows[r][ts] and 'td' in all_rows[r][ts]]
        if len(complete) < 48:
            print(f'{r}: only {len(complete)} complete timestamps — skip')
            continue
        n_test = max(1, len(complete) // 5)
        train_ts, test_ts = complete[:-n_test], complete[-n_test:]
        d = os.path.join(OUT, r)
        os.makedirs(d, exist_ok=True)
        for split, ts_list in (('train', train_ts), ('test', test_ts)):
            with open(os.path.join(d, f'{split}.csv'), 'w') as f:
                f.write('timestamp,z,price_buy,price_sell\n')
                for ts in ts_list:
                    row = all_rows[r][ts]
                    buy, sell = price(row)
                    f.write(f'{ts.isoformat()},{row["td"]:.3f},{buy:.4f},{sell:.4f}\n')
        print(f'{r}: train {len(train_ts)} test {len(test_ts)} timestamps')
    # battery default for regions
    import json
    for r in REGIONS:
        d = os.path.join(OUT, r)
        if os.path.isdir(d):
            with open(os.path.join(d, 'battery.json'), 'w') as f:
                json.dump({"power_kw": 100.0, "capacity_kwh": 400.0, "charge_eff": 0.95, "discharge_eff": 0.95}, f)
    print('done')

if __name__ == '__main__':
    main()
