#!/bin/bash
###############################################################################
# Run ALL Stress Test Scenarios Sequentially (runs inside the pod)
#
# This script is designed to execute inside the pushgateway-stress-test pod.
# It runs every scenario back-to-back, cleaning the Pushgateway between each
# one so results don't pollute each other.
#
# Usage (inside pod):
#   bash /opt/stress-test/scripts/run_all.sh [--skip-soak]
#
# The --skip-soak flag skips C6 and I6 (the multi-hour soak tests) to reduce
# total runtime from ~10 hours to ~6 hours.
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results"
GENERATOR="${SCRIPT_DIR}/generator.py"

CLUSTERIP="http://10.96.230.201:9091"
INGRESS="https://pushgateway.150.230.181.224.nip.io"

MASTER_LOG="${RESULTS_DIR}/run_all.log"
mkdir -p "$RESULTS_DIR"

SKIP_SOAK=false
if [[ "${1:-}" == "--skip-soak" ]]; then
    SKIP_SOAK=true
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

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
    log "STARTING scenario ${id}"
    log "  Params: ${params}"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    clean_pushgateway

    local start_ts=$(date +%s)

    python3 "$GENERATOR" --scenario "$id" $params 2>&1 | tee -a "$MASTER_LOG"
    local exit_code=${PIPESTATUS[0]}

    local end_ts=$(date +%s)
    local elapsed=$(( end_ts - start_ts ))
    local elapsed_min=$(( elapsed / 60 ))

    if [[ $exit_code -eq 0 ]]; then
        log "COMPLETED scenario ${id} in ${elapsed_min}m (exit 0)"
    else
        log "FAILED scenario ${id} in ${elapsed_min}m (exit ${exit_code})"
    fi

    # Write per-scenario marker
    echo "$(date -Iseconds)" > "${RESULTS_DIR}/${id}/DONE" 2>/dev/null || true

    log ""
    sleep 5  # brief cooldown between scenarios
}

# ─── Scenario Definitions ────────────────────────────────────────────────────

ALL_START=$(date +%s)
log "╔══════════════════════════════════════════════════════════════╗"
log "║          FULL STRESS TEST SUITE — STARTING                  ║"
log "║          $(date '+%Y-%m-%d %H:%M:%S')                               ║"
if [[ "$SKIP_SOAK" == true ]]; then
    log "║          Mode: SKIP SOAK (C6, I6 excluded)                  ║"
else
    log "║          Mode: FULL (including soak tests)                  ║"
fi
log "╚══════════════════════════════════════════════════════════════╝"
log ""

# --- ClusterIP Ramp ---
run_scenario C0 --endpoint "$CLUSTERIP" --nodes 10   --jitter 5  --interval 60 --duration 300  --jobs node+cluster
run_scenario C1 --endpoint "$CLUSTERIP" --nodes 100  --jitter 20 --interval 60 --duration 600  --jobs node+cluster
run_scenario C2 --endpoint "$CLUSTERIP" --nodes 250  --jitter 20 --interval 60 --duration 600  --jobs node+cluster
run_scenario C3 --endpoint "$CLUSTERIP" --nodes 500  --jitter 20 --interval 60 --duration 900  --jobs node+cluster
run_scenario C4 --endpoint "$CLUSTERIP" --nodes 750  --jitter 20 --interval 60 --duration 900  --jobs node+cluster
run_scenario C5 --endpoint "$CLUSTERIP" --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node+cluster

if [[ "$SKIP_SOAK" == false ]]; then
    run_scenario C6 --endpoint "$CLUSTERIP" --nodes 1000 --jitter 20 --interval 60 --duration 7200 --jobs node+cluster
fi

# --- ClusterIP Spike ---
run_scenario C7 --endpoint "$CLUSTERIP" --nodes 1000 --jitter 0  --interval 60 --duration 1200 --jobs node+cluster

# --- Ingress HTTPS Ramp ---
run_scenario I0 --endpoint "$INGRESS" --nodes 10   --jitter 5  --interval 60 --duration 300  --jobs node+cluster
run_scenario I1 --endpoint "$INGRESS" --nodes 100  --jitter 20 --interval 60 --duration 600  --jobs node+cluster
run_scenario I2 --endpoint "$INGRESS" --nodes 250  --jitter 20 --interval 60 --duration 600  --jobs node+cluster
run_scenario I3 --endpoint "$INGRESS" --nodes 500  --jitter 20 --interval 60 --duration 900  --jobs node+cluster
run_scenario I4 --endpoint "$INGRESS" --nodes 750  --jitter 20 --interval 60 --duration 900  --jobs node+cluster
run_scenario I5 --endpoint "$INGRESS" --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node+cluster

if [[ "$SKIP_SOAK" == false ]]; then
    run_scenario I6 --endpoint "$INGRESS" --nodes 1000 --jitter 20 --interval 60 --duration 7200 --jobs node+cluster
fi

# --- Ingress Spike ---
run_scenario I7 --endpoint "$INGRESS" --nodes 1000 --jitter 0  --interval 60 --duration 1200 --jobs node+cluster

# --- Node-level isolation ---
run_scenario N1 --endpoint "$CLUSTERIP" --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node
run_scenario N2 --endpoint "$INGRESS"   --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node

# --- Pod metrics inflation ---
run_scenario P1 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 1
run_scenario P2 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 10
run_scenario P3 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 50
run_scenario P4 --endpoint "$CLUSTERIP" --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 100

# ─── Done ────────────────────────────────────────────────────────────────────

ALL_END=$(date +%s)
ALL_ELAPSED=$(( ALL_END - ALL_START ))
ALL_HOURS=$(( ALL_ELAPSED / 3600 ))
ALL_MINS=$(( (ALL_ELAPSED % 3600) / 60 ))

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║          FULL STRESS TEST SUITE — COMPLETE                  ║"
log "║          Total time: ${ALL_HOURS}h ${ALL_MINS}m                                  ║"
log "║          $(date '+%Y-%m-%d %H:%M:%S')                               ║"
log "╚══════════════════════════════════════════════════════════════╝"

# Write a final marker
echo "$(date -Iseconds)" > "${RESULTS_DIR}/ALL_DONE"
