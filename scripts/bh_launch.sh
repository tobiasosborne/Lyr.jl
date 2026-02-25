#!/bin/bash
# Black hole flyby — launch 4 workers with 16 threads each
# 64 cores → 4 workers × 16 threads = full utilization
set -e
cd "$(dirname "$0")/.."

N=100
WORKERS=2
PER=$((N / WORKERS))
OUTDIR=showcase/mov4_blackhole
mkdir -p "$OUTDIR"

echo "============================================================"
echo "Black Hole Volumetric Flyby"
echo "  $N frames at 512x512"
echo "  $WORKERS workers × 32 threads each"
echo "============================================================"

PIDS=()
for i in $(seq 0 $((WORKERS - 1))); do
    FIRST=$((i * PER))
    LAST=$(( (i + 1) * PER - 1 ))
    [ $LAST -ge $N ] && LAST=$((N - 1))
    LOG="$OUTDIR/worker_$((i+1)).log"
    echo "  Worker $((i+1)): frames $FIRST..$LAST → $LOG"
    julia --project -t 32 scripts/bh_worker.jl $FIRST $LAST > "$LOG" 2>&1 &
    PIDS+=($!)
done

echo ""
echo "Waiting for ${#PIDS[@]} workers (PIDs: ${PIDS[*]})..."
echo ""

FAIL=0
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        echo "  Worker $((i+1)): done"
    else
        echo "  Worker $((i+1)): FAILED (see $OUTDIR/worker_$((i+1)).log)"
        FAIL=$((FAIL+1))
    fi
done

DONE=$(ls "$OUTDIR"/frame_*.ppm 2>/dev/null | wc -l)
echo ""
echo "$DONE/$N frames rendered ($FAIL workers failed)"

if [ "$DONE" -eq "$N" ]; then
    echo ""
    echo "Encoding MP4..."
    ffmpeg -y -framerate 25 -i "$OUTDIR/frame_%04d.ppm" \
        -c:v libx264 -pix_fmt yuv420p showcase/black_hole_flyby.mp4
    echo "→ showcase/black_hole_flyby.mp4"
fi
