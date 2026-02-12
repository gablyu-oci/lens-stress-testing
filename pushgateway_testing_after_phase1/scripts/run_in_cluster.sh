#!/bin/bash
###############################################################################
# Run Pushgateway 2.0 Stress Test Inside the Cluster
#
# Usage:
#   ./run_in_cluster.sh <SCENARIO_ID>            # attached
#   ./run_in_cluster.sh <SCENARIO_ID> --detach   # detached
#   ./run_in_cluster.sh --all [--skip-soak]      # full suite
#   ./run_in_cluster.sh --list
#   ./run_in_cluster.sh --status
#   ./run_in_cluster.sh --results [SCENARIO_ID]
#   ./run_in_cluster.sh --shell
#   ./run_in_cluster.sh --cleanup
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="oci-gpu-scanner-plugin"
POD_NAME="pushgateway-stress-test"
REMOTE_DIR="/opt/stress-test"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[cluster]${NC} $*"; }
ok()   { echo -e "${GREEN}[cluster]${NC} $*"; }
warn() { echo -e "${YELLOW}[cluster]${NC} $*"; }
err()  { echo -e "${RED}[cluster]${NC} $*"; }

CLUSTERIP="http://10.96.242.191:9091"

pod_status() {
    kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound"
}

ensure_pod() {
    local status
    status=$(pod_status)
    [[ "$status" == "Running" ]] && { ok "Pod already running"; return; }
    [[ "$status" != "NotFound" ]] && {
        warn "Pod in state '$status', deleting..."
        kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --wait=true 2>/dev/null || true
    }
    log "Creating stress test pod..."
    kubectl apply -f "${SCRIPT_DIR}/stress-test-pod.yaml"
    kubectl wait --for=condition=Ready pod/"$POD_NAME" -n "$NAMESPACE" --timeout=120s
    ok "Pod is ready"
}

sync_files() {
    log "Setting up remote directory..."
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "mkdir -p ${REMOTE_DIR}/{payloads,scripts,results} && pip install -q aiohttp 2>&1 | tail -1"

    log "Copying payloads..."
    for f in "${PROJECT_DIR}"/payloads/*.txt; do
        [[ -f "$f" ]] && kubectl cp "$f" "${NAMESPACE}/${POD_NAME}:${REMOTE_DIR}/payloads/$(basename "$f")" 2>/dev/null || true
    done
    [[ -f "${PROJECT_DIR}/payloads/pushgateway-payload" ]] && kubectl cp "${PROJECT_DIR}/payloads/pushgateway-payload" "${NAMESPACE}/${POD_NAME}:${REMOTE_DIR}/payloads/pushgateway-payload" 2>/dev/null || true

    log "Copying scripts..."
    for f in generator.py monitor.sh run_scenario.sh run_all.sh requirements.txt; do
        [[ -f "${SCRIPT_DIR}/${f}" ]] && kubectl cp "${SCRIPT_DIR}/${f}" "${NAMESPACE}/${POD_NAME}:${REMOTE_DIR}/scripts/${f}"
    done

    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "chmod +x ${REMOTE_DIR}/scripts/*.sh 2>/dev/null || true"
    ok "Files synced"
}

get_scenario_params() {
    local id="$1"
    case "$id" in
        C0)   echo "--scenario C0 --endpoint $CLUSTERIP --nodes 10 --jitter 5 --interval 60 --duration 300 --jobs node+cluster+healthcheck" ;;
        C20)  echo "--scenario C20 --endpoint $CLUSTERIP --nodes 20 --jitter 10 --interval 60 --duration 300 --jobs node+cluster+healthcheck" ;;
        C30)  echo "--scenario C30 --endpoint $CLUSTERIP --nodes 30 --jitter 10 --interval 60 --duration 300 --jobs node+cluster+healthcheck" ;;
        C50)  echo "--scenario C50 --endpoint $CLUSTERIP --nodes 50 --jitter 15 --interval 60 --duration 600 --jobs node+cluster+healthcheck" ;;
        C80)  echo "--scenario C80 --endpoint $CLUSTERIP --nodes 80 --jitter 15 --interval 60 --duration 600 --jobs node+cluster+healthcheck" ;;
        C1)   echo "--scenario C1 --endpoint $CLUSTERIP --nodes 100 --jitter 20 --interval 60 --duration 600 --jobs node+cluster+healthcheck" ;;
        C150) echo "--scenario C150 --endpoint $CLUSTERIP --nodes 150 --jitter 20 --interval 60 --duration 600 --jobs node+cluster+healthcheck" ;;
        C200) echo "--scenario C200 --endpoint $CLUSTERIP --nodes 200 --jitter 20 --interval 60 --duration 600 --jobs node+cluster+healthcheck" ;;
        C2)   echo "--scenario C2 --endpoint $CLUSTERIP --nodes 250 --jitter 20 --interval 60 --duration 600 --jobs node+cluster+healthcheck" ;;
        C300) echo "--scenario C300 --endpoint $CLUSTERIP --nodes 300 --jitter 20 --interval 60 --duration 900 --jobs node+cluster+healthcheck" ;;
        C400) echo "--scenario C400 --endpoint $CLUSTERIP --nodes 400 --jitter 20 --interval 60 --duration 900 --jobs node+cluster+healthcheck" ;;
        C3)   echo "--scenario C3 --endpoint $CLUSTERIP --nodes 500 --jitter 20 --interval 60 --duration 900 --jobs node+cluster+healthcheck" ;;
        C4)   echo "--scenario C4 --endpoint $CLUSTERIP --nodes 750 --jitter 20 --interval 60 --duration 900 --jobs node+cluster+healthcheck" ;;
        C5)   echo "--scenario C5 --endpoint $CLUSTERIP --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node+cluster+healthcheck" ;;
        C6)   echo "--scenario C6 --endpoint $CLUSTERIP --nodes 1000 --jitter 20 --interval 60 --duration 7200 --jobs node+cluster+healthcheck" ;;
        C7)   echo "--scenario C7 --endpoint $CLUSTERIP --nodes 1000 --jitter 0 --interval 60 --duration 1200 --jobs node+cluster+healthcheck" ;;
        N1)   echo "--scenario N1 --endpoint $CLUSTERIP --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node" ;;
        P1) echo "--scenario P1 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 1" ;;
        P2) echo "--scenario P2 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 10" ;;
        P3) echo "--scenario P3 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 50" ;;
        P4) echo "--scenario P4 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 100" ;;
        *) err "Unknown scenario: $id"; return 1 ;;
    esac
}

# ─── Handlers ────────────────────────────────────────────────────────────────

[[ "${1:-}" == "--list" || "${1:-}" == "-l" ]] && { bash "${SCRIPT_DIR}/run_scenario.sh" --list; exit 0; }

if [[ "${1:-}" == "--cleanup" ]]; then
    log "Deleting pod ${POD_NAME}..."
    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found
    ok "Cleaned up"
    exit 0
fi

if [[ "${1:-}" == "--shell" ]]; then
    ensure_pod
    sync_files
    log "Opening shell..."
    kubectl exec -it "$POD_NAME" -n "$NAMESPACE" -- bash
    exit 0
fi

if [[ "${1:-}" == "--status" ]]; then
    log "Checking status..."
    local_status=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "
            if [ -f ${REMOTE_DIR}/results/RUNNING ]; then
                scenario=\$(cat ${REMOTE_DIR}/results/RUNNING)
                pid=\$(cat ${REMOTE_DIR}/results/RUNNING_PID 2>/dev/null || echo '?')
                started=\$(cat ${REMOTE_DIR}/results/RUNNING_STARTED 2>/dev/null || echo '?')
                kill -0 \$pid 2>/dev/null && echo \"RUNNING|\${scenario}|\${pid}|\${started}\" || echo \"FINISHED|\${scenario}|\${pid}|\${started}\"
            else
                latest=\$(ls -td ${REMOTE_DIR}/results/*/DONE 2>/dev/null | head -1)
                [ -n \"\$latest\" ] && echo \"DONE|\$(basename \$(dirname \$latest))||\$(cat \$latest)\" || echo 'IDLE|||'
            fi
        " 2>/dev/null || echo "POD_UNAVAILABLE|||")

    IFS='|' read -r state scenario pid started <<< "$local_status"
    case "$state" in
        RUNNING)  ok "Test RUNNING — scenario $scenario" ;;
        FINISHED) ok "Test FINISHED — scenario $scenario" ;;
        DONE)     ok "Last test COMPLETED — scenario $scenario" ;;
        IDLE)     log "No test running" ;;
        *)        warn "Pod unavailable. Use '$0 <SCENARIO_ID>' to start." ;;
    esac
    exit 0
fi

if [[ "${1:-}" == "--results" ]]; then
    SCENARIO_FOR_RESULTS="${2:-}"
    local_results="${PROJECT_DIR}/results"
    ensure_pod
    if [[ -z "$SCENARIO_FOR_RESULTS" ]]; then
        log "Copying ALL results..."
        mkdir -p "$local_results"
        scenarios=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "ls -d ${REMOTE_DIR}/results/*/ 2>/dev/null | xargs -I{} basename {}" 2>/dev/null || echo "")
        for s in $scenarios; do
            [[ -z "$s" || "$s" == "RUNNING"* ]] && continue
            log "Copying ${s}..."
            mkdir -p "${local_results}/${s}"
            kubectl exec "$POD_NAME" -n "$NAMESPACE" -- tar cf - -C ${REMOTE_DIR}/results/${s} . 2>/dev/null | tar xf - -C "${local_results}/${s}" 2>/dev/null || true
        done
        ok "Results saved to ${local_results}/"
    else
        log "Copying ${SCENARIO_FOR_RESULTS}..."
        mkdir -p "${local_results}/${SCENARIO_FOR_RESULTS}"
        kubectl exec "$POD_NAME" -n "$NAMESPACE" -- tar cf - -C ${REMOTE_DIR}/results/${SCENARIO_FOR_RESULTS} . 2>/dev/null | tar xf - -C "${local_results}/${SCENARIO_FOR_RESULTS}" 2>/dev/null || true
        ok "Results in ${local_results}/${SCENARIO_FOR_RESULTS}/"
    fi
    exit 0
fi

if [[ "${1:-}" == "--all" ]]; then
    SKIP_SOAK_FLAG=""
    [[ "${2:-}" == "--skip-soak" ]] && SKIP_SOAK_FLAG="--skip-soak"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Pushgateway 2.0 — Running ALL Scenarios (DETACHED)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    ensure_pod
    sync_files

    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "
        echo 'ALL' > ${REMOTE_DIR}/results/RUNNING
        echo \"\$(date -Iseconds)\" > ${REMOTE_DIR}/results/RUNNING_STARTED
        nohup bash -c '
            bash ${REMOTE_DIR}/scripts/run_all.sh ${SKIP_SOAK_FLAG}
            rm -f ${REMOTE_DIR}/results/RUNNING ${REMOTE_DIR}/results/RUNNING_PID ${REMOTE_DIR}/results/RUNNING_STARTED
        ' > ${REMOTE_DIR}/results/run_all_output.log 2>&1 &
        echo \$! > ${REMOTE_DIR}/results/RUNNING_PID
    "

    ok "All scenarios queued. Check: $0 --status"
    exit 0
fi

# ─── Single scenario ────────────────────────────────────────────────────────

SCENARIO_ID="${1:?Usage: $0 <SCENARIO_ID> [--detach] | --list | --status | --results | --shell | --cleanup}"
DETACH=false
[[ "${2:-}" == "--detach" ]] && DETACH=true

params=$(get_scenario_params "$SCENARIO_ID") || exit 1

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Pushgateway 2.0 — Scenario ${SCENARIO_ID}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

mkdir -p "${PROJECT_DIR}/results"
ensure_pod
sync_files

if [[ "$DETACH" == true ]]; then
    log "Launching ${SCENARIO_ID} in DETACHED mode..."
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- bash -c "
        mkdir -p ${REMOTE_DIR}/results/${SCENARIO_ID}
        echo '${SCENARIO_ID}' > ${REMOTE_DIR}/results/RUNNING
        nohup bash -c '
            python3 ${REMOTE_DIR}/scripts/generator.py ${params}
            echo \"\$(date -Iseconds)\" > ${REMOTE_DIR}/results/${SCENARIO_ID}/DONE
        ' > ${REMOTE_DIR}/results/${SCENARIO_ID}/run.log 2>&1 &
        echo \$! > ${REMOTE_DIR}/results/RUNNING_PID
    "
    ok "Running in background. $0 --results ${SCENARIO_ID} to copy results."
else
    log "Running ${SCENARIO_ID} (attached)..."
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- python3 ${REMOTE_DIR}/scripts/generator.py $params
    mkdir -p "${PROJECT_DIR}/results/${SCENARIO_ID}"
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- tar cf - -C ${REMOTE_DIR}/results/${SCENARIO_ID} . 2>/dev/null | tar xf - -C "${PROJECT_DIR}/results/${SCENARIO_ID}" 2>/dev/null || true
    ok "Results in ${PROJECT_DIR}/results/${SCENARIO_ID}/"
fi
echo ""
