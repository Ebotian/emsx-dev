#!/bin/bash
# Download 14 days of AEMO ARCHIVE DispatchIS daily packages (5-min RRP+demand).
# Each ~5.6MB; slow AEMO server -> resume-retry per file.
set -u
cd "$(dirname "$0")/raw"
mkdir -p archive
BASE="https://www.nemweb.com.au/Reports/ARCHIVE/DispatchIS_Reports"
# last 14 days ending 2026-08-04 (2026-07-22 .. 2026-08-04)
for d in 20260722 20260723 20260724 20260725 20260726 20260727 20260728 20260729 20260730 20260731 20260801 20260802 20260803 20260804; do
  out="archive/PUBLIC_DISPATCHIS_${d}.zip"
  [ -s "$out" ] && unzip -t "$out" >/dev/null 2>&1 && { echo "skip $out"; continue; }
  url="${BASE}/PUBLIC_DISPATCHIS_${d}.zip"
  ok=0
  for i in $(seq 1 100); do
    curl -sfL --noproxy '*' -C - --max-time 120 --retry 2 -o "$out" "$url" || true
    if unzip -t "$out" >/dev/null 2>&1; then ok=1; echo "OK $out ($(stat -c%s "$out") bytes)"; break; fi
    sleep 30
  done
  [ $ok -eq 1 ] || echo "FAIL $out after 100 attempts"
done
echo "archive download done: $(ls archive | wc -l) files"
