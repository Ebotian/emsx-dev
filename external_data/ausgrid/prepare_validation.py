#!/usr/bin/env python3
"""Ausgrid validation format: train/test split + TOU prices + battery params.
Net demand from processed/net_demand/. Output per customer:
  validation/<customer>/train.csv, test.csv  (timestamp,z,price_buy,price_sell)
  validation/<customer>/battery.json
TOU (2010-2013 NSW residential): peak 7-21h weekdays high, off-peak low.
Sell price = 60% of buy (net-metering style).
"""
import csv, os, json, glob
from datetime import datetime

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, 'processed', 'net_demand')
OUT = os.path.join(BASE, 'validation')

TRAIN_END = datetime(2012, 6, 30, 23, 59)
TEST_END = datetime(2013, 6, 30, 23, 59)

def is_peak(dt):
    return dt.weekday() < 5 and 7 <= dt.hour < 21

def price(dt):
    buy = 0.30 if is_peak(dt) else 0.12  # AUD/kWh TOU
    sell = buy * 0.6
    return buy, sell

BATTERY = {"power_kw": 5.0, "capacity_kwh": 13.5, "charge_eff": 0.95, "discharge_eff": 0.95}

os.makedirs(OUT, exist_ok=True)
files = sorted(glob.glob(os.path.join(SRC, '*.csv')))
n_train = n_test = 0
for fp in files:
    cust = os.path.basename(fp).replace('.csv', '')
    with open(fp) as f:
        rows = list(csv.DictReader(f))
    d = os.path.join(OUT, cust)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'train.csv'), 'w') as ft, open(os.path.join(d, 'test.csv'), 'w') as fte:
        ft.write('timestamp,z,price_buy,price_sell\n')
        fte.write('timestamp,z,price_buy,price_sell\n')
        for r in rows:
            ts = datetime.fromisoformat(r['timestamp'])
            buy, sell = price(ts)
            line = f"{r['timestamp']},{r['net_demand_kw']},{buy:.4f},{sell:.4f}\n"
            if ts <= TRAIN_END:
                ft.write(line); n_train += 1
            elif ts <= TEST_END:
                fte.write(line); n_test += 1
    with open(os.path.join(d, 'battery.json'), 'w') as fb:
        json.dump(BATTERY, fb)

print(f'customers: {len(files)}, train rows: {n_train}, test rows: {n_test}')
print(f'output: {OUT}/<customer>/(train.csv, test.csv, battery.json)')
