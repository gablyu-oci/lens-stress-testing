#!/bin/bash
###############################################################################
# Run ALL Stress Test 2.0 Scenarios (Pushgateway - Updated Architecture)
#
# Runs inside the pushgateway-stress-test pod.
# Usage: bash /opt/stress-test/scripts/run_all.sh [--skip-soak]
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results"
GENERATOR="${SCRIPT_DIR}/generator.py"

CLUSTERIP="http://10.96.242.191:9091"

MASTER_LOG="${RESULTS_DIR}/run_all.log"
mkdir -p "$RESULTS_DIR"

SKIP_SOAK=false
if [[ "${1:-}" == "--skip-soak" ]]; then
    SKIP_SOAK=true
fi

JOBS_FILTER="node+cluster+healthcheck"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$MASTER_LOG"
}

clean_pushgateway() {
    log "Cleaning Pushgateway (deleting all metric groups)..."
    python3 -c "
import urllib.request, json
try:
    req = urllib.request.Request('${CLUSTERIP}/api/v1/metrics')
    resp = urllib.request.urlopen(req)
    data = json.loads(resp.read().decode())
    deleted = 0
    for group in data.get('data', []):
        labels = group.get('labels', {})
        job, instance = labels.get('job',''), labels.get('instance','')
        url = '${CLUSTERIP}/metrics/job/' + job
        if instance:
            url += '/instance/' + instance
        try:
            urllib.request.urlopen(urllib.request.Request(url, method='DELETE'))
            deleted += 1
        except:
            pass
    print(f'  Deleted {deleted} groups')
except Exception as e:
    print(f'  Warning: cleanup failed: {e}')
" 2>&1 | tee -a "$MASTER_LOG"
}

run_scenario() {
    local id="$1"
    shift
    local params="$*"

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "STARTING scenario ${id} (Pushgateway 2.0)"
    log "  Params: ${params}"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    clean_pushgateway

    local start_ts=$(date +%s)

    python3 "$GENERATOR" --scenario "$id" --jobs "$JOBS_FILTER" $params 2>&1 | tee -a "$MASTER_LOG"
    local exit_code=${PIPESTATUS[0]}

    local end_ts=$(date +%s)
    local elapsed=$(( end_ts - start_ts ))
    local elapsed_min=$(( elapsed / 60 ))

    if [[ $exit_code -eq 0 ]]; then
        log "COMPLETED scenario ${id} in ${elapsed_min}m (exit 0)"
    else
        log "FAILED scenario ${id} in ${elapsed_min}m (exit ${exit_code})"
    fi

    echo "$(date -Iseconds)" > "${RESULTS_DIR}/${id}/DONE" 2>/dev/null || true
    log ""
    sleep 5
}

ALL_START=$(date +%s)
log "╔══════════════════════════════════════════════════════════════╗"
log "║     PUSHGATEWAY STRESS TEST 2.0 — FULL SUITE STARTING       ║"
log "║     $(date '+%Y-%m-%d %H:%M:%S')                               ║"
log "║     Jobs: ${JOBS_FILTER}"
if [[ "$SKIP_SOAK" == true ]]; then
    log "║     Mode: SKIP SOAK (C6 excluded)                         ║"
else
    log "║     Mode: FULL (including soak tests)                     ║"
fi
log "╚══════════════════════════════════════════════════════════════╝"
log ""

# ClusterIP Ramp
run_scenario C0  --endpoint "$CLUSTERIP" --nodes 10   --jitter 5  --interval 60 --duration 300
run_scenario C20 --endpoint "$CLUSTERIP" --nodes 20   --jitter 10 --interval 60 --duration 300
run_scenario C30 --endpoint "$CLUSTERIP" --nodes 30   --jitter 10 --interval 60 --duration 300
run_scenario C50 --endpoint "$CLUSTERIP" --nodes 50   --jitter 15 --interval 60 --duration 600
run_scenario C80 --endpoint "$CLUSTERIP" --nodes 80   --jitter 15 --interval 60 --duration 600
run_scenario C1  --endpoint "$CLUSTERIP" --nodes 100  --jitter 20 --interval 60 --duration 600
run_scenario C150 --endpoint "$CLUSTERIP" --nodes 150 --jitter 20 --interval 60 --duration 600
run_scenario C200 --endpoint "$CLUSTERIP" --nodes 200 --jitter 20 --interval 60 --duration 600
run_scenario C2  --endpoint "$CLUSTERIP" --nodes 250  --jitter 20 --interval 60 --duration 600
run_scenario C300 --endpoint "$CLUSTERIP" --nodes 300 --jitter 20 --interval 60 --duration 900
run_scenario C400 --endpoint "$CLUSTERIP" --nodes 400 --jitter 20 --interval 60 --duration 900
run_scenario C3  --endpoint "$CLUSTERIP" --nodes 500  --jitter 20 --interval 60 --duration 900
run_scenario C4  --endpoint "$CLUSTERIP" --nodes 750  --jitter 20 --interval 60 --duration 900
run_scenario C5  --endpoint "$CLUSTERIP" --nodes 1000 --jitter 20 --interval 60 --duration 1200

if [[ "$SKIP_SOAK" == false ]]; then
    run_scenario C6 --endpoint "$CLUSTERIP" --nodes 1000 --jitter 20 --interval 60 --duration 7200
fi

run_scenario C7 --endpoint "$CLUSTERIP" --nodes 1000 --jitter 0  --interval 60 --duration 1200

# Node-level isolation
run_scenario N1 --endpoint "$CLUSTERIP" --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node

# Pod metrics inflation
run_scenario P1 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 1
run_scenario P2 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 10
run_scenario P3 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 50
run_scenario P4 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 100

ALL_END=$(date +%s)
ALL_ELAPSED=$(( ALL_END - ALL_START ))
ALL_HOURS=$(( ALL_ELAPSED / 3600 ))
ALL_MINS=$(( (ALL_ELAPSED % 3600) / 60 ))

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║     PUSHGATEWAY STRESS TEST 2.0 — COMPLETE                  ║"
log "║     Total time: ${ALL_HOURS}h ${ALL_MINS}m                               ║"
log "║     $(date '+%Y-%m-%d %H:%M:%S')                               ║"
log "╚══════════════════════════════════════════════════════════════╝"

echo "$(date -Iseconds)" > "${RESULTS_DIR}/ALL_DONE"
