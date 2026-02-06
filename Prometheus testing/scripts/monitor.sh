#!/bin/bash
###############################################################################
# Prometheus Health Monitor
#
# Runs in background during stress tests to collect:
#   - Prometheus pod CPU/memory via kubectl top
#   - Pod restarts / OOMKills
#   - Prometheus log errors
#
# Usage:
#   ./monitor.sh <scenario_id> [poll_interval_seconds]
#   ./monitor.sh R0 30
###############################################################################

set -euo pipefail

SCENARIO_ID="${1:?Usage: $0 <scenario_id> [poll_interval]}"
POLL_INTERVAL="${2:-30}"
NAMESPACE="lens"
DEPLOY_NAME="lens-prometheus-server"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results/${SCENARIO_ID}"
mkdir -p "$RESULTS_DIR"

LOG_FILE="${RESULTS_DIR}/${SCENARIO_ID}_monitor.log"
HEALTH_CSV="${RESULTS_DIR}/${SCENARIO_ID}_health.csv"
PID_FILE="${RESULTS_DIR}/${SCENARIO_ID}_monitor.pid"

echo $$ > "$PID_FILE"

cleanup() {
    rm -f "$PID_FILE"
    echo "$(date -Iseconds) Monitor stopped" >> "$LOG_FILE"
}
trap cleanup EXIT

# ─── Discover Prometheus pod ─────────────────────────────────────────────────

PROM_POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=prometheus \
    -l app.kubernetes.io/component=server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$PROM_POD" ]]; then
    PROM_POD=$(kubectl -n "$NAMESPACE" get pods -o name 2>/dev/null | \
        grep prometheus-server | head -1 | sed 's|pod/||')
fi

# ─── CSV header ──────────────────────────────────────────────────────────────

echo "timestamp,prom_cpu_millicores,prom_memory_mi,prom_restarts" > "$HEALTH_CSV"

# ─── Log header ──────────────────────────────────────────────────────────────

{
    echo "========================================"
    echo "Monitor started: $(date -Iseconds)"
    echo "Scenario:        $SCENARIO_ID"
    echo "Poll interval:   ${POLL_INTERVAL}s"
    echo "Prometheus pod:  ${PROM_POD:-NOT FOUND}"
    echo "========================================"
} > "$LOG_FILE"

echo "[monitor] Started for ${SCENARIO_ID} (PID $$), pod=${PROM_POD:-?}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

parse_cpu() {
    local val="$1"
    if [[ "$val" == *m ]]; then echo "${val%m}"
    elif [[ "$val" =~ ^[0-9]+$ ]]; then echo $((val * 1000))
    else echo "0"; fi
}

parse_mem() {
    local val="$1"
    if [[ "$val" == *Mi ]]; then echo "${val%Mi}"
    elif [[ "$val" == *Gi ]]; then echo $(( ${val%Gi} * 1024 ))
    elif [[ "$val" == *Ki ]]; then echo $(( ${val%Ki} / 1024 ))
    else echo "0"; fi
}

# ─── Main loop ───────────────────────────────────────────────────────────────

while true; do
    ts=$(date -Iseconds)

    # CPU / Memory
    cpu_m=0; mem_mi=0
    if [[ -n "$PROM_POD" ]]; then
        top_out=$(kubectl top pod "$PROM_POD" -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
        if [[ -n "$top_out" ]]; then
            cpu_raw=$(echo "$top_out" | awk '{print $2}')
            mem_raw=$(echo "$top_out" | awk '{print $3}')
            cpu_m=$(parse_cpu "$cpu_raw")
            mem_mi=$(parse_mem "$mem_raw")
        fi
    fi

    # Restarts
    restarts=0
    if [[ -n "$PROM_POD" ]]; then
        restarts=$(kubectl get pod "$PROM_POD" -n "$NAMESPACE" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus-server")].restartCount}' \
            2>/dev/null || echo "0")
    fi

    # OOMKill check
    if [[ -n "$PROM_POD" ]]; then
        reason=$(kubectl get pod "$PROM_POD" -n "$NAMESPACE" \
            -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus-server")].lastState.terminated.reason}' \
            2>/dev/null || echo "")
        if [[ "$reason" == "OOMKilled" ]]; then
            echo "${ts} *** OOMKill detected on ${PROM_POD} ***" >> "$LOG_FILE"
        fi
    fi

    # Prometheus log errors (last poll interval)
    if [[ -n "$PROM_POD" ]]; then
        errors=$(kubectl logs "$PROM_POD" -n "$NAMESPACE" -c prometheus-server \
            --since="${POLL_INTERVAL}s" 2>/dev/null | \
            grep -iE "error|fail|panic|oom" | tail -5 || echo "")
        if [[ -n "$errors" ]]; then
            echo "${ts} Prometheus errors:" >> "$LOG_FILE"
            echo "$errors" >> "$LOG_FILE"
        fi
    fi

    # Write CSV
    echo "${ts},${cpu_m},${mem_mi},${restarts}" >> "$HEALTH_CSV"

    # Log summary
    echo "${ts} cpu=${cpu_m}m mem=${mem_mi}Mi restarts=${restarts}" >> "$LOG_FILE"

    sleep "$POLL_INTERVAL"
done
