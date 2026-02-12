#!/bin/bash
###############################################################################
# Scenario Runner
#
# Runs a single stress-test scenario end-to-end:
#   1. Updates target count to N
#   2. Waits for Prometheus to discover all targets
#   3. Collects metrics every POLL_INTERVAL seconds for DURATION
#   4. Writes summary
#
# Prerequisites:
#   - setup_emitters.sh and setup_prometheus.sh have been run
#   - kubectl access to the cluster
#
# Usage:
#   ./run_scenario.sh <SCENARIO_ID>
#   ./run_scenario.sh R0
#   ./run_scenario.sh --list
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results"
NAMESPACE="lens"
DEPLOY_NAME="lens-prometheus-server"
POLL_INTERVAL=30

# ─── Scenario Definitions ───────────────────────────────────────────────────
# Format: id|nodes|duration_sec|purpose

SCENARIOS=(
    "R0|10|900|Sanity baseline"
    "R1|50|1200|Early scaling"
    "R2|100|1800|Mid-scale pressure"
    "R3|200|2700|Near target scale"
    "R4|250|2700|Push ceiling"
)

# ─── Functions ───────────────────────────────────────────────────────────────

list_scenarios() {
    echo ""
    echo "Available Scenarios"
    echo "==================="
    printf "%-6s %6s %8s %8s  %s\n" "Case" "Nodes" "Targets" "Duration" "Purpose"
    echo "-----  -----  -------  --------  -------"
    for entry in "${SCENARIOS[@]}"; do
        IFS='|' read -r id nodes dur purpose <<< "$entry"
        printf "%-6s %6s %8s %7sm  %s\n" "$id" "$nodes" "$(( nodes * 4 ))" "$(( dur / 60 ))" "$purpose"
    done
    echo ""
    echo "Soak test:  ./run_scenario.sh R5 <N> <DURATION_SEC>"
    echo "  Example:  ./run_scenario.sh R5 200 21600   # 200 nodes, 6 hours"
    echo ""
}

find_scenario() {
    local target="$1"
    for entry in "${SCENARIOS[@]}"; do
        IFS='|' read -r id rest <<< "$entry"
        if [[ "$id" == "$target" ]]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

stop_background() {
    local pid="$1"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# ─── Parse arguments ────────────────────────────────────────────────────────

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    list_scenarios
    exit 0
fi

SCENARIO_ID="${1:?Usage: $0 <SCENARIO_ID> or $0 --list}"

# Handle R5 (soak) with custom N and duration
if [[ "$SCENARIO_ID" == "R5" ]]; then
    NODES="${2:?R5 (soak) requires: $0 R5 <N> <DURATION_SEC>}"
    DURATION="${3:?R5 (soak) requires: $0 R5 <N> <DURATION_SEC>}"
    PURPOSE="Soak test (N=${NODES}, ${DURATION}s)"
else
    SCENARIO_DEF=$(find_scenario "$SCENARIO_ID" || true)
    if [[ -z "$SCENARIO_DEF" ]]; then
        echo "ERROR: Unknown scenario '${SCENARIO_ID}'"
        echo "Use '$0 --list' to see available scenarios."
        exit 1
    fi
    IFS='|' read -r _ NODES DURATION PURPOSE <<< "$SCENARIO_DEF"
fi

EXPECTED_TARGETS=$(( NODES * 4 ))
SCENARIO_RESULTS="${RESULTS_DIR}/${SCENARIO_ID}"
mkdir -p "$SCENARIO_RESULTS"

# ─── Banner ──────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Scenario ${SCENARIO_ID}: ${PURPOSE}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Nodes:            ${NODES}"
echo "  Targets:          ${EXPECTED_TARGETS}"
echo "  Duration:         ${DURATION}s ($((DURATION / 60))m)"
echo "  Poll interval:    ${POLL_INTERVAL}s"
echo "  Results dir:      ${SCENARIO_RESULTS}"
echo ""

# ─── Start port-forward ─────────────────────────────────────────────────────

echo "[runner] Starting port-forward to Prometheus..."
kubectl -n "$NAMESPACE" port-forward "deploy/${DEPLOY_NAME}" 9090:9090 \
    > /dev/null 2>&1 &
PF_PID=$!
sleep 3

if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "ERROR: port-forward failed to start."
    exit 1
fi
echo "[runner] Port-forward active (PID ${PF_PID})"

# Ensure cleanup on exit
cleanup() {
    echo ""
    echo "[runner] Cleaning up..."
    stop_background "${MONITOR_PID:-0}"
    stop_background "$PF_PID"
}
trap cleanup EXIT

# ─── Start monitor ───────────────────────────────────────────────────────────

echo "[runner] Starting health monitor..."
bash "${SCRIPT_DIR}/monitor.sh" "$SCENARIO_ID" "$POLL_INTERVAL" &
MONITOR_PID=$!
echo "[runner] Monitor PID: ${MONITOR_PID}"

# ─── Set targets ─────────────────────────────────────────────────────────────

echo ""
echo "[runner] Setting targets to N=${NODES}..."
bash "${SCRIPT_DIR}/generate_targets.sh" "$NODES"

# ─── Wait for target discovery ───────────────────────────────────────────────

echo ""
echo "[runner] Waiting for Prometheus to discover ${EXPECTED_TARGETS} targets..."

MAX_WAIT=180
WAITED=0
while true; do
    discovered=$(curl -sfg "http://localhost:9090/api/v1/query?query=count(up{job=~\"lens-scale-test.*\"})" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('data',{}).get('result',[]); print(r[0]['value'][1] if r else '0')" 2>/dev/null || echo "0")

    if [[ "$discovered" -ge "$EXPECTED_TARGETS" ]]; then
        echo "[runner] All ${EXPECTED_TARGETS} targets discovered."
        break
    fi

    WAITED=$((WAITED + 10))
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        echo "[runner] WARNING: Only ${discovered}/${EXPECTED_TARGETS} targets discovered after ${MAX_WAIT}s."
        echo "[runner] Proceeding anyway."
        break
    fi

    echo "[runner] Discovered ${discovered}/${EXPECTED_TARGETS} — waiting... (${WAITED}/${MAX_WAIT}s)"
    sleep 10
done

# ─── Collect metrics loop ───────────────────────────────────────────────────

echo ""
echo "[runner] Starting metric collection for ${DURATION}s..."
echo ""

START_TS=$(date +%s)
STOP_FAILURES=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TS ))

    if [[ $ELAPSED -ge $DURATION ]]; then
        echo ""
        echo "[runner] Duration reached (${ELAPSED}s / ${DURATION}s). Stopping."
        break
    fi

    # Collect metrics
    bash "${SCRIPT_DIR}/collect_metrics.sh" "$SCENARIO_ID" "$NODES" 2>/dev/null || true

    # Check stop rule: scrape success < 95% for 3 consecutive intervals
    success_pct=$(tail -1 "${SCENARIO_RESULTS}/${SCENARIO_ID}_metrics.csv" 2>/dev/null | \
        cut -d, -f5 || echo "100")
    if [[ -n "$success_pct" ]] && python3 -c "exit(0 if float('${success_pct:-100}') < 95 else 1)" 2>/dev/null; then
        STOP_FAILURES=$((STOP_FAILURES + 1))
        echo "[runner] WARNING: scrape success ${success_pct}% (< 95%, strike ${STOP_FAILURES}/3)"
    else
        STOP_FAILURES=0
    fi

    if [[ $STOP_FAILURES -ge 3 ]]; then
        echo ""
        echo "[runner] STOP RULE: scrape success < 95% for 3 consecutive polls."
        echo "[runner] Stopping scenario early at ${ELAPSED}s."
        break
    fi

    # Check for OOM restart
    restarts=$(tail -1 "${SCENARIO_RESULTS}/${SCENARIO_ID}_health.csv" 2>/dev/null | \
        cut -d, -f4 || echo "0")
    if [[ "${restarts:-0}" -gt 0 ]]; then
        echo "[runner] WARNING: Prometheus has ${restarts} restarts — possible OOM."
    fi

    sleep "$POLL_INTERVAL"
done

# ─── Write summary ───────────────────────────────────────────────────────────

END_TS=$(date +%s)
ACTUAL_DURATION=$(( END_TS - START_TS ))

echo ""
echo "[runner] Writing summary..."

CSV="${SCENARIO_RESULTS}/${SCENARIO_ID}_metrics.csv"
if [[ -f "$CSV" ]] && [[ $(wc -l < "$CSV") -gt 1 ]]; then
    python3 -c "
import csv, sys

with open('${CSV}') as f:
    rows = list(csv.DictReader(f))

if not rows:
    print('No data collected.')
    sys.exit(0)

def safe_float(v):
    try: return float(v)
    except: return None

def fmt(v, decimals=2):
    if v is None: return 'N/A'
    return f'{v:.{decimals}f}'

# Compute stats
success_pcts = [safe_float(r['scrape_success_pct']) for r in rows if safe_float(r['scrape_success_pct']) is not None]
dur_p50s = [safe_float(r['scrape_duration_p50']) for r in rows if safe_float(r['scrape_duration_p50']) is not None]
dur_p95s = [safe_float(r['scrape_duration_p95']) for r in rows if safe_float(r['scrape_duration_p95']) is not None]
dur_maxs = [safe_float(r['scrape_duration_max']) for r in rows if safe_float(r['scrape_duration_max']) is not None]
head_series = [safe_float(r['head_series']) for r in rows if safe_float(r['head_series']) is not None]
mem_bytes = [safe_float(r['memory_bytes']) for r in rows if safe_float(r['memory_bytes']) is not None]
cpu_vals = [safe_float(r['cpu_cores']) for r in rows if safe_float(r['cpu_cores']) is not None]
samples = [safe_float(r['samples_per_sec']) for r in rows if safe_float(r['samples_per_sec']) is not None]

summary = f'''Scenario ${SCENARIO_ID} Summary
==========================
Nodes:               ${NODES}
Targets:             ${EXPECTED_TARGETS}
Actual duration:     ${ACTUAL_DURATION}s ({int(${ACTUAL_DURATION}/60)}m)
Data points:         {len(rows)}

Scrape Success:
  Mean:              {fmt(sum(success_pcts)/len(success_pcts) if success_pcts else None, 1)}%
  Min:               {fmt(min(success_pcts) if success_pcts else None, 1)}%

Scrape Duration:
  p50 (mean):        {fmt(sum(dur_p50s)/len(dur_p50s) if dur_p50s else None, 4)}s
  p95 (mean):        {fmt(sum(dur_p95s)/len(dur_p95s) if dur_p95s else None, 4)}s
  max (peak):        {fmt(max(dur_maxs) if dur_maxs else None, 4)}s

Ingestion:
  samples/sec (last):{fmt(samples[-1] if samples else None, 0)}

Head Series:
  Start:             {fmt(head_series[0] if head_series else None, 0)}
  End:               {fmt(head_series[-1] if head_series else None, 0)}
  Peak:              {fmt(max(head_series) if head_series else None, 0)}

Memory:
  Start:             {fmt((mem_bytes[0]/1073741824) if mem_bytes else None, 2)} GB
  End:               {fmt((mem_bytes[-1]/1073741824) if mem_bytes else None, 2)} GB
  Peak:              {fmt((max(mem_bytes)/1073741824) if mem_bytes else None, 2)} GB

CPU:
  Mean:              {fmt(sum(cpu_vals)/len(cpu_vals) if cpu_vals else None, 3)} cores
  Peak:              {fmt(max(cpu_vals) if cpu_vals else None, 3)} cores
'''
print(summary)
with open('${SCENARIO_RESULTS}/${SCENARIO_ID}_summary.txt', 'w') as f:
    f.write(summary)
"
else
    echo "No metrics CSV found — nothing to summarize."
fi

echo "$(date -Iseconds)" > "${SCENARIO_RESULTS}/DONE"

echo ""
echo "Results in: ${SCENARIO_RESULTS}/"
ls -lh "${SCENARIO_RESULTS}/" 2>/dev/null || true
echo ""
echo "Scenario ${SCENARIO_ID} complete."
