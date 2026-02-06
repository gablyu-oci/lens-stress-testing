#!/bin/bash
###############################################################################
# Pushgateway Health Monitor
#
# Runs in background during stress tests to collect:
#   - Pushgateway pod CPU/memory via kubectl top
#   - Pod restarts / OOMKills
#   - Ingress controller health (when relevant)
#   - Pushgateway log errors
#
# Usage:
#   ./monitor.sh <scenario_id> [poll_interval_seconds]
#   ./monitor.sh C1 30
#
# Stop with: kill $(cat results/<scenario_id>_monitor.pid)
###############################################################################

set -euo pipefail

SCENARIO_ID="${1:?Usage: $0 <scenario_id> [poll_interval]}"
POLL_INTERVAL="${2:-30}"
NAMESPACE="oci-gpu-scanner-plugin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results"
mkdir -p "$RESULTS_DIR"

LOG_FILE="${RESULTS_DIR}/${SCENARIO_ID}_monitor.log"
HEALTH_CSV="${RESULTS_DIR}/${SCENARIO_ID}_health.csv"
PID_FILE="${RESULTS_DIR}/${SCENARIO_ID}_monitor.pid"

# Write PID for external stop
echo $$ > "$PID_FILE"

# Cleanup on exit
cleanup() {
    rm -f "$PID_FILE"
    echo "$(date -Iseconds) Monitor stopped" >> "$LOG_FILE"
}
trap cleanup EXIT

# ─── Discover pods ──────────────────────────────────────────────────────────

discover_pushgateway_pod() {
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus-pushgateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
    kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
        grep -i pushgateway | head -1 || echo ""
}

discover_ingress_pod() {
    kubectl get pods -n cluster-tools -l app.kubernetes.io/name=ingress-nginx \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

PG_POD=$(discover_pushgateway_pod)
INGRESS_POD=$(discover_ingress_pod)

# ─── CSV header ─────────────────────────────────────────────────────────────

echo "timestamp,pg_cpu_millicores,pg_memory_mi,pg_restarts,ingress_cpu_millicores,ingress_memory_mi" \
    > "$HEALTH_CSV"

# ─── Log header ─────────────────────────────────────────────────────────────

{
    echo "========================================"
    echo "Monitor started: $(date -Iseconds)"
    echo "Scenario:        $SCENARIO_ID"
    echo "Poll interval:   ${POLL_INTERVAL}s"
    echo "Pushgateway pod: ${PG_POD:-NOT FOUND}"
    echo "Ingress pod:     ${INGRESS_POD:-NOT FOUND}"
    echo "========================================"
} > "$LOG_FILE"

echo "[monitor] Started for scenario $SCENARIO_ID (PID $$)"
echo "[monitor] Pushgateway pod: ${PG_POD:-NOT FOUND}"
echo "[monitor] Logging to: $LOG_FILE"
echo "[monitor] Health CSV: $HEALTH_CSV"

# ─── Helper functions ───────────────────────────────────────────────────────

parse_cpu() {
    # Convert kubectl top output (e.g., "250m", "1", "2500m") to millicores
    local val="$1"
    if [[ "$val" == *m ]]; then
        echo "${val%m}"
    elif [[ "$val" =~ ^[0-9]+$ ]]; then
        echo $((val * 1000))
    else
        echo "0"
    fi
}

parse_mem() {
    # Convert kubectl top output (e.g., "128Mi", "1Gi") to MiB
    local val="$1"
    if [[ "$val" == *Mi ]]; then
        echo "${val%Mi}"
    elif [[ "$val" == *Gi ]]; then
        local gi="${val%Gi}"
        echo $((gi * 1024))
    elif [[ "$val" == *Ki ]]; then
        local ki="${val%Ki}"
        echo $((ki / 1024))
    else
        echo "0"
    fi
}

get_pod_metrics() {
    local pod="$1"
    local ns="$2"
    if [[ -z "$pod" ]]; then
        echo "0 0"
        return
    fi
    local top_output
    top_output=$(kubectl top pod "$pod" -n "$ns" --no-headers 2>/dev/null || echo "")
    if [[ -z "$top_output" ]]; then
        echo "0 0"
        return
    fi
    local cpu_raw mem_raw
    cpu_raw=$(echo "$top_output" | awk '{print $2}')
    mem_raw=$(echo "$top_output" | awk '{print $3}')
    echo "$(parse_cpu "$cpu_raw") $(parse_mem "$mem_raw")"
}

get_restarts() {
    local pod="$1"
    local ns="$2"
    if [[ -z "$pod" ]]; then
        echo "0"
        return
    fi
    kubectl get pod "$pod" -n "$ns" -o jsonpath='{.status.containerStatuses[0].restartCount}' \
        2>/dev/null || echo "0"
}

check_oomkills() {
    local pod="$1"
    local ns="$2"
    if [[ -z "$pod" ]]; then
        return
    fi
    local reason
    reason=$(kubectl get pod "$pod" -n "$ns" \
        -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")
    if [[ "$reason" == "OOMKilled" ]]; then
        echo "$(date -Iseconds) *** OOMKill detected on $pod ***" >> "$LOG_FILE"
        echo "[monitor] *** OOMKill detected on $pod ***"
    fi
}

collect_pg_errors() {
    local pod="$1"
    if [[ -z "$pod" ]]; then
        return
    fi
    local errors
    errors=$(kubectl logs "$pod" -n "$NAMESPACE" --since="${POLL_INTERVAL}s" \
        2>/dev/null | grep -iE "error|fail|panic|timeout|oom" | tail -5 || echo "")
    if [[ -n "$errors" ]]; then
        echo "$(date -Iseconds) Pushgateway errors:" >> "$LOG_FILE"
        echo "$errors" >> "$LOG_FILE"
    fi
}

collect_ingress_errors() {
    local pod="$1"
    if [[ -z "$pod" ]]; then
        return
    fi
    local errors
    errors=$(kubectl logs "$pod" -n cluster-tools --since="${POLL_INTERVAL}s" \
        2>/dev/null | grep -E " (413|429|502|503|504) " | tail -5 || echo "")
    if [[ -n "$errors" ]]; then
        echo "$(date -Iseconds) Ingress errors:" >> "$LOG_FILE"
        echo "$errors" >> "$LOG_FILE"
    fi
}

# ─── Main loop ──────────────────────────────────────────────────────────────

while true; do
    ts=$(date -Iseconds)

    # Pushgateway metrics
    read pg_cpu pg_mem <<< "$(get_pod_metrics "$PG_POD" "$NAMESPACE")"
    pg_restarts=$(get_restarts "$PG_POD" "$NAMESPACE")
    check_oomkills "$PG_POD" "$NAMESPACE"
    collect_pg_errors "$PG_POD"

    # Ingress metrics
    read ing_cpu ing_mem <<< "$(get_pod_metrics "$INGRESS_POD" "cluster-tools")"
    collect_ingress_errors "$INGRESS_POD"

    # Write CSV row
    echo "${ts},${pg_cpu},${pg_mem},${pg_restarts},${ing_cpu},${ing_mem}" >> "$HEALTH_CSV"

    # Log summary
    echo "${ts} PG: cpu=${pg_cpu}m mem=${pg_mem}Mi restarts=${pg_restarts} | " \
         "Ingress: cpu=${ing_cpu}m mem=${ing_mem}Mi" >> "$LOG_FILE"

    sleep "$POLL_INTERVAL"
done
