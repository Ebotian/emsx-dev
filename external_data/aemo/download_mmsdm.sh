#!/bin/bash
# Download MMSDM monthly packages with fast-fail per file (slow AEMO server).
set -u
cd "$(dirname "$0")/raw"
mkdir -p mmsdm
BASE="https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM"
for year in 2024 2025; do
  for m in 01 02 03 04 05 06 07 08 09 10 11 12; do
    ym="${year}${m}"
    for table in DISPATCHPRICE DEMANDOPERATIONALACTUAL; do
      out="mmsdm/${table}_${ym}.zip"
      [ -s "$out" ] && unzip -t "$out" >/dev/null 2>&1 && { echo "skip $out"; continue; }
      url="${BASE}/${year}/MMSDM_${year}_${m}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23${table}%23FILE01%23${ym}010000.zip"
      ok=0
      for i in $(seq 1 40); do
        curl -sfL --noproxy '*' -C - --max-time 90 --retry 2 -o "$out" "$url" || true
        if unzip -t "$out" >/dev/null 2>&1; then ok=1; echo "OK $out ($(stat -c%s "$out") bytes)"; break; fi
        sleep 20
      done
      [ $ok -eq 1 ] || echo "FAIL $out after 40 attempts (skip)"
    done
  done
done
echo "MMSDM download loop done: $(ls mmsdm | wc -l) files"
