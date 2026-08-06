#!/bin/bash
# AEMO post-download pipeline (unattended):
#   wait 14 valid daily zips -> extract -> convert -> scp to Mac ->
#   5 regions parallel 288-slot validation -> fetch results -> aggregate to viz JSON.
set -u
cd "$(dirname "$0")"
RAW=raw
ARCHIVE=$RAW/archive

# 1) wait for all 14 daily zips valid (download_archive.sh runs in background)
ok=0
for i in $(seq 1 360); do
  ok=0
  for f in $ARCHIVE/*.zip; do
    unzip -t "$f" >/dev/null 2>&1 && ok=$((ok+1))
  done
  echo "[wait] valid zips: $ok/14 (try $i)"
  [ "$ok" -ge 14 ] && break
  sleep 60
done
if [ "$ok" -lt 14 ]; then echo "WARN: only $ok/14 valid zips after 6h wait"; fi

# 2) extract all daily zips -> per-5min sub-zips
mkdir -p $RAW/extracted
for f in $ARCHIVE/*.zip; do
  unzip -o -q "$f" -d $RAW/extracted/ && echo "extracted $(basename $f)"
done
echo "extracted sub-zips: $(ls $RAW/extracted | wc -l)"

# 3) convert to per-region train/test CSV
.venv/bin/python3 aemo_convert.py | tail -10

# 4) scp to Mac
ssh kevin@192.168.10.147 'mkdir -p ~/emsx-experiment/external/aemo && rm -rf ~/emsx-experiment/external/aemo/validation && rm -f ~/emsx-experiment/external/aemo/results/*.json'
scp -r validation kevin@192.168.10.147:~/emsx-experiment/external/aemo/
echo "validation synced to Mac"

# 5) launch 5 regions in parallel on Mac (288 slots = 5min)
ssh kevin@192.168.10.147 'cd ~/emsx-experiment && mkdir -p external/aemo/results && for r in NSW1 VIC1 QLD1 SA1 TAS1; do nohup /opt/homebrew/bin/julia --project=$HOME/emsx-experiment external/run_external_validation.jl external/aemo/validation 288 $r > external/aemo_run_$r.log 2>&1 & done; echo "launched 5 regions"; sleep 2; ps aux | grep -c "[r]un_external_validation"' | tail -3

# 6) wait for 5 result files
for i in $(seq 1 240); do
  n=$(ssh kevin@192.168.10.147 'ls ~/emsx-experiment/external/aemo/results/*.json 2>/dev/null | wc -l')
  echo "[wait] aemo results: $n/5 (try $i)"
  [ "$n" -ge 5 ] && break
  sleep 60
done

# 7) fetch results + summary logs
mkdir -p results
scp -r kevin@192.168.10.147:~/emsx-experiment/external/aemo/results/ results/
echo "=== result files ==="
ls -la results/
echo "=== Mac run logs tail ==="
ssh kevin@192.168.10.147 'tail -2 ~/emsx-experiment/external/aemo_run_NSW1.log ~/emsx-experiment/external/aemo_run_SA1.log 2>/dev/null'

# 8) aggregate to visualization JSON
cd /home/ebt/Downloads/emsx/external_data
python3 aggregate_results.py aemo ../visualization/public/data/aemo

echo "PIPELINE DONE"
