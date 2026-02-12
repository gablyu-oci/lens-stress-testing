#!/bin/bash
###############################################################################
# Pushgateway Health Monitor (Pushgateway 2.0)
#
# Runs in background during stress tests.
# Usage: ./monitor.sh <scenario_id> [poll_interval_seconds]
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

echo $$ > "$PID_FILE"

cleanup() {
    rm -f "$PID_FILE"
    echo "$(date -Iseconds) Monitor stopped" >> "$LOG_FILE"
}
trap cleanup EXIT

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

echo "timestamp,pg_cpu_millicores,pg_memory_mi,pg_restarts,ingress_cpu_millicores,ingress_memory_mi" > "$HEALTH_CSV"

{
    echo "========================================"
    echo "Monitor started: $(date -Iseconds)"
    echo "Scenario:        $SCENARIO_ID (Pushgateway 2.0)"
    echo "Poll interval:   ${POLL_INTERVAL}s"
    echo "Pushgateway pod: ${PG_POD:-NOT FOUND}"
    echo "Ingress pod:     ${INGRESS_POD:-NOT FOUND}"
    echo "========================================"
} > "$LOG_FILE"

echo "[monitor] Started for scenario $SCENARIO_ID (PID $$)"

parse_cpu() {
    local val="$1"
    if [[ "$val" == *m ]]; then echo "${val%m}"
    elif [[ "$val" =~ ^[0-9]+$ ]]; then echo $((val * 1000))
    else echo "0"; fi
}

parse_mem() {
    local val="$1"
    if [[ "$val" == *Mi ]]; then echo "${val%Mi}"
    elif [[ "$val" == *Gi ]]; then echo $((${val%Gi} * 1024))
    elif [[ "$val" == *Ki ]]; then echo $((${val%Ki} / 1024))
    else echo "0"; fi
}

get_pod_metrics() {
    local pod="$1" ns="$2"
    [[ -z "$pod" ]] && { echo "0 0"; return; }
    local top_output
    top_output=$(kubectl top pod "$pod" -n "$ns" --no-headers 2>/dev/null || echo "")
    [[ -z "$top_output" ]] && { echo "0 0"; return; }
    echo "$(parse_cpu "$(echo "$top_output" | awk '{print $2}')") $(parse_mem "$(echo "$top_output" | awk '{print $3}')")"
}

get_restarts() {
    [[ -z "${1:-}" ]] && { echo "0"; return; }
    kubectl get pod "$1" -n "$2" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0"
}

check_oomkills() {
    [[ -z "${1:-}" ]] && return
    local reason
    reason=$(kubectl get pod "$1" -n "$2" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")
    [[ "$reason" == "OOMKilled" ]] && echo "$(date -Iseconds) *** OOMKill on $1 ***" >> "$LOG_FILE"
}

collect_pg_errors() {
    [[ -z "${1:-}" ]] && return
    local errors
    errors=$(kubectl logs "$1" -n "$NAMESPACE" --since="${POLL_INTERVAL}s" 2>/dev/null | grep -iE "error|fail|panic|timeout|oom" | tail -5 || echo "")
    [[ -n "$errors" ]] && { echo "$(date -Iseconds) Pushgateway errors:" >> "$LOG_FILE"; echo "$errors" >> "$LOG_FILE"; }
}

collect_ingress_errors() {
    [[ -z "${1:-}" ]] && return
    local errors
    errors=$(kubectl logs "$1" -n cluster-tools --since="${POLL_INTERVAL}s" 2>/dev/null | grep -E " (413|429|502|503|504) " | tail -5 || echo "")
    [[ -n "$errors" ]] && { echo "$(date -Iseconds) Ingress errors:" >> "$LOG_FILE"; echo "$errors" >> "$LOG_FILE"; }
}

while true; do
    ts=$(date -Iseconds)
    read pg_cpu pg_mem <<< "$(get_pod_metrics "$PG_POD" "$NAMESPACE")"
    pg_restarts=$(get_restarts "$PG_POD" "$NAMESPACE")
    check_oomkills "$PG_POD" "$NAMESPACE"
    collect_pg_errors "$PG_POD"
    read ing_cpu ing_mem <<< "$(get_pod_metrics "$INGRESS_POD" "cluster-tools")"
    collect_ingress_errors "$INGRESS_POD"
    echo "${ts},${pg_cpu},${pg_mem},${pg_restarts},${ing_cpu},${ing_mem}" >> "$HEALTH_CSV"
    echo "${ts} PG: cpu=${pg_cpu}m mem=${pg_mem}Mi | Ingress: cpu=${ing_cpu}m mem=${ing_mem}Mi" >> "$LOG_FILE"
    sleep "$POLL_INTERVAL"
done
