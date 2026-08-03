#!/bin/bash
# Run 6 parameter sweep variants sequentially
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$ROOT/experiments/sdp_ar1_param.jl"
JULIA_RUNNER="$ROOT/scripts/julia_locked.sh"
LOGDIR="$ROOT/results_sdp/sweep_logs"
mkdir -p "$LOGDIR"

echo "=== Parameter Sweep Started: $(date) ==="

# V1: baseline
DX=0.1  DU=0.1  K_NOISE=10 MARGIN=0.50 NZ=20 TAG=v1_baseline   "$JULIA_RUNNER" "$SCRIPT" 2>&1 | tee "$LOGDIR/v1.log"
echo "=== V1 done: $(date) ==="

# V2: finer SoC grid
DX=0.05 DU=0.1  K_NOISE=10 MARGIN=0.50 NZ=20 TAG=v2_fine_soc   "$JULIA_RUNNER" "$SCRIPT" 2>&1 | tee "$LOGDIR/v2.log"
echo "=== V2 done: $(date) ==="

# V3: finer control
DX=0.1  DU=0.05 K_NOISE=10 MARGIN=0.50 NZ=20 TAG=v3_fine_ctl   "$JULIA_RUNNER" "$SCRIPT" 2>&1 | tee "$LOGDIR/v3.log"
echo "=== V3 done: $(date) ==="

# V4: more noise levels
DX=0.1  DU=0.1  K_NOISE=20 MARGIN=0.50 NZ=20 TAG=v4_k20        "$JULIA_RUNNER" "$SCRIPT" 2>&1 | tee "$LOGDIR/v4.log"
echo "=== V4 done: $(date) ==="

# V5: tighter z range
DX=0.1  DU=0.1  K_NOISE=10 MARGIN=0.25 NZ=20 TAG=v5_margin25   "$JULIA_RUNNER" "$SCRIPT" 2>&1 | tee "$LOGDIR/v5.log"
echo "=== V5 done: $(date) ==="

# V6: finer z grid
DX=0.1  DU=0.1  K_NOISE=10 MARGIN=0.50 NZ=30 TAG=v6_nz30       "$JULIA_RUNNER" "$SCRIPT" 2>&1 | tee "$LOGDIR/v6.log"
echo "=== V6 done: $(date) ==="

echo "=== All variants complete: $(date) ==="

# Extract scores
echo ""
echo "=== SCORES ==="
for f in "$LOGDIR"/v*.log; do
    tag=$(basename "$f" .log)
    score=$(grep "Mean Score:" "$f" | tail -1 | awk '{print $3}')
    gain=$(grep "Mean Gain:" "$f" | tail -1 | awk '{print $3}')
    echo "  $tag: score=$score gain=$gain"
done