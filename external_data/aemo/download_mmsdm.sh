#!/bin/bash
# Limited-time AEMO download probe: each file gets at most 3 x 60s attempts.
# If the first file cannot complete, AEMO data acquisition is judged blocked.
set -u
cd "$(dirname "$0")/raw"
mkdir -p mmsdm
BASE="https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM"
tables=("DISPATCHPRICE" "DEMANDOPERATIONALACTUAL")
for ym in 202401 202402 202403 202404 202405 202406; do
  year=${ym:0:4}; m=${ym:4:2}
  for table in "${tables[@]}"; do
    out="mmsdm/${table}_${ym}.zip"
    [ -s "$out" ] && unzip -t "$out" >/dev/null 2>&1 && { echo "skip $out"; continue; }
    url="${BASE}/${year}/MMSDM_${year}_${m}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23${table}%23FILE01%23${ym}010000.zip"
    ok=0
    for i in 1 2 3; do
      curl -sfL --noproxy '*' -C - --max-time 60 -o "$out" "$url" || true
      if unzip -t "$out" >/dev/null 2>&1; then ok=1; echo "OK $out ($(stat -c%s "$out") bytes)"; break; fi
      sleep 10
    done
    if [ $ok -eq 1 ]; then
      echo "AEMO DOWNLOAD FEASIBLE - continuing full range"
      # continue remaining months
      for ym2 in 202407 202408 202409 202410 202411 202412 2025{01,02,03,04,05,06,07,08,09,10,11,12}; do
        y2=${ym2:0:4}; m2=${ym2:4:2}
        for table2 in "${tables[@]}"; do
          out2="mmsdm/${table2}_${ym2}.zip"
          [ -s "$out2" ] && unzip -t "$out2" >/dev/null 2>&1 && continue
          url2="${BASE}/${y2}/MMSDM_${y2}_${m2}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23${table2}%23FILE01%23${ym2}010000.zip"
          ok2=0
          for j in 1 2 3; do
            curl -sfL --noproxy '*' -C - --max-time 60 -o "$out2" "$url2" || true
            if unzip -t "$out2" >/dev/null 2>&1; then ok2=1; echo "OK $out2"; break; fi
            sleep 10
          done
          [ $ok2 -eq 1 ] || echo "FAIL $out2 (skip)"
        done
      done
      break 2
    else
      echo "FAIL $out after 3 attempts"
    fi
  done
done
echo "probe done: $(ls mmsdm | wc -l) files"
