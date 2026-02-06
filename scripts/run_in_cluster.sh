#!/bin/bash
###############################################################################
# Run Stress Test Inside the Cluster
#
# Deploys a pod, copies scripts+payloads in, runs the scenario.
# Supports attached mode (live output) and detached mode (close your laptop).
#
# Usage:
#   ./run_in_cluster.sh <SCENARIO_ID>            # attached (live output)
#   ./run_in_cluster.sh <SCENARIO_ID> --detach   # detached (safe to disconnect)
#   ./run_in_cluster.sh --all                    # run ALL scenarios detached (~10h)
#   ./run_in_cluster.sh --all --skip-soak        # run all except C6/I6 (~6h)
#   ./run_in_cluster.sh --logs [SCENARIO_ID|ALL] # tail live logs
#   ./run_in_cluster.sh --status                 # check if a test is running
#   ./run_in_cluster.sh --results [SCENARIO_ID]  # copy results back
#   ./run_in_cluster.sh --list                   # show all scenarios
#   ./run_in_cluster.sh --shell                  # get a shell into the pod
#   ./run_in_cluster.sh --cleanup                # delete the pod
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

# ─── Functions (defined early so flag handlers can use them) ─────────────────

pod_status() {
    kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound"
}

ensure_pod() {
    local status
    status=$(pod_status)

    if [[ "$status" == "Running" ]]; then
        ok "Pod already running"
        return
    fi

    if [[ "$status" != "NotFound" ]]; then
        warn "Pod in state '$status', deleting and recreating..."
        kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --wait=true 2>/dev/null || true
    fi

    log "Creating stress test pod..."
    kubectl apply -f "${SCRIPT_DIR}/stress-test-pod.yaml"

    log "Waiting for pod to be ready..."
    kubectl wait --for=condition=Ready pod/"$POD_NAME" -n "$NAMESPACE" --timeout=120s
    ok "Pod is ready"
}

sync_files() {
    log "Setting up remote directory..."
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "mkdir -p ${REMOTE_DIR}/{payloads,scripts,results} && pip install -q aiohttp 2>&1 | tail -1"

    log "Copying payloads..."
    for f in "${PROJECT_DIR}"/payloads/*.txt "${PROJECT_DIR}"/payloads/pushgateway-payload; do
        [[ -f "$f" ]] && kubectl cp "$f" "${NAMESPACE}/${POD_NAME}:${REMOTE_DIR}/payloads/$(basename "$f")"
    done

    log "Copying scripts..."
    for f in generator.py monitor.sh run_scenario.sh run_all.sh requirements.txt; do
        [[ -f "${SCRIPT_DIR}/${f}" ]] && kubectl cp "${SCRIPT_DIR}/${f}" "${NAMESPACE}/${POD_NAME}:${REMOTE_DIR}/scripts/${f}"
    done

    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "chmod +x ${REMOTE_DIR}/scripts/*.sh ${REMOTE_DIR}/scripts/*.py 2>/dev/null || true"

    ok "Files synced"
}

# ─── Handle special flags ───────────────────────────────────────────────────

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    bash "${SCRIPT_DIR}/run_scenario.sh" --list
    exit 0
fi

if [[ "${1:-}" == "--all" ]]; then
    SKIP_SOAK_FLAG=""
    if [[ "${2:-}" == "--skip-soak" ]]; then
        SKIP_SOAK_FLAG="--skip-soak"
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Running ALL Scenarios (DETACHED)${NC}"
    if [[ -n "$SKIP_SOAK_FLAG" ]]; then
        echo -e "${YELLOW}  Skipping soak tests (C6, I6) — ~6 hours total${NC}"
    else
        echo -e "${YELLOW}  Including soak tests (C6, I6) — ~10 hours total${NC}"
    fi
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    ensure_pod
    sync_files

    log "Launching full test suite in DETACHED mode..."
    log "The tests run inside the pod — safe to close your terminal."
    echo ""

    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "
            echo 'ALL' > ${REMOTE_DIR}/results/RUNNING
            echo \"\$(date -Iseconds)\" > ${REMOTE_DIR}/results/RUNNING_STARTED
            nohup bash -c '
                bash ${REMOTE_DIR}/scripts/run_all.sh ${SKIP_SOAK_FLAG}
                rm -f ${REMOTE_DIR}/results/RUNNING ${REMOTE_DIR}/results/RUNNING_PID ${REMOTE_DIR}/results/RUNNING_STARTED
            ' > ${REMOTE_DIR}/results/run_all_output.log 2>&1 &
            PID=\$!
            echo \$PID > ${REMOTE_DIR}/results/RUNNING_PID
            echo \"Master runner started with PID \$PID\"
        "

    echo ""
    ok "All scenarios are queued and running sequentially inside the pod."
    echo ""
    echo "  Check status:      $0 --status"
    echo "  Follow master log: $0 --logs ALL"
    echo "  Follow a scenario: $0 --logs C3"
    echo "  Copy all results:  $0 --results"
    echo "  Shell into pod:    $0 --shell"
    echo ""
    echo "  You can now safely close this terminal."
    echo ""

    # Auto-copy: local watcher that copies ALL results when suite finishes
    local_results="${PROJECT_DIR}/results"
    mkdir -p "$local_results"
    nohup bash -c "
        while true; do
            sleep 120
            all_done=\$(kubectl exec ${POD_NAME} -n ${NAMESPACE} -- \
                cat ${REMOTE_DIR}/results/ALL_DONE 2>/dev/null) || true
            if [[ -n \"\$all_done\" ]]; then
                echo '[auto-copy] Full suite finished, copying all results...' >> '${local_results}/auto_copy.log'
                # Copy each scenario folder
                scenarios=\$(kubectl exec ${POD_NAME} -n ${NAMESPACE} -- \
                    bash -c \"ls -d ${REMOTE_DIR}/results/*/ 2>/dev/null | xargs -I{} basename {}\" 2>/dev/null) || true
                for s in \$scenarios; do
                    mkdir -p '${local_results}/'\$s
                    kubectl exec ${POD_NAME} -n ${NAMESPACE} -- \
                        tar cf - -C ${REMOTE_DIR}/results/\$s . 2>/dev/null | \
                        tar xf - -C '${local_results}/'\$s 2>/dev/null
                done
                # Copy master logs
                kubectl exec ${POD_NAME} -n ${NAMESPACE} -- \
                    cat ${REMOTE_DIR}/results/run_all.log > '${local_results}/run_all.log' 2>/dev/null || true
                kubectl exec ${POD_NAME} -n ${NAMESPACE} -- \
                    cat ${REMOTE_DIR}/results/run_all_output.log > '${local_results}/run_all_output.log' 2>/dev/null || true
                echo '[auto-copy] All results copied to ${local_results}/' >> '${local_results}/auto_copy.log'
                exit 0
            fi
        done
    " >> "${local_results}/auto_copy.log" 2>&1 &
    log "Auto-copy watcher started (PID $!) — all results will be copied when suite finishes."

    exit 0
fi

if [[ "${1:-}" == "--cleanup" ]]; then
    log "Deleting pod ${POD_NAME}..."
    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found
    ok "Cleaned up"
    exit 0
fi

if [[ "${1:-}" == "--shell" ]]; then
    log "Opening shell into ${POD_NAME}..."
    kubectl exec -it "$POD_NAME" -n "$NAMESPACE" -- bash
    exit 0
fi

if [[ "${1:-}" == "--status" ]]; then
    log "Checking test status..."
    local_status=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "
            if [ -f ${REMOTE_DIR}/results/RUNNING ]; then
                scenario=\$(cat ${REMOTE_DIR}/results/RUNNING)
                pid=\$(cat ${REMOTE_DIR}/results/RUNNING_PID 2>/dev/null || echo '?')
                started=\$(cat ${REMOTE_DIR}/results/RUNNING_STARTED 2>/dev/null || echo '?')
                if kill -0 \$pid 2>/dev/null; then
                    echo \"RUNNING|\${scenario}|\${pid}|\${started}\"
                else
                    echo \"FINISHED|\${scenario}|\${pid}|\${started}\"
                fi
            else
                # Check for most recently completed scenario
                latest=\$(ls -td ${REMOTE_DIR}/results/*/DONE 2>/dev/null | head -1)
                if [ -n \"\$latest\" ]; then
                    scenario=\$(basename \$(dirname \$latest))
                    finished=\$(cat \$latest)
                    echo \"DONE|\${scenario}||\${finished}\"
                else
                    echo 'IDLE|||'
                fi
            fi
        " 2>/dev/null || echo "POD_UNAVAILABLE|||")

    IFS='|' read -r state scenario pid started <<< "$local_status"
    case "$state" in
        RUNNING)
            ok "Test is RUNNING"
            echo "  Scenario: $scenario"
            echo "  PID:      $pid"
            echo "  Started:  $started"
            echo ""
            echo "  View live output:"
            echo "    $0 --logs $scenario"
            ;;
        FINISHED)
            ok "Test has FINISHED (cleaning up...)"
            echo "  Scenario: $scenario"
            echo "  Started:  $started"
            echo ""
            echo "  Copy results:"
            echo "    $0 --results $scenario"
            ;;
        DONE)
            ok "Last test COMPLETED"
            echo "  Scenario:  $scenario"
            echo "  Finished:  $started"
            echo ""
            echo "  Copy results:"
            echo "    $0 --results $scenario"
            ;;
        IDLE)
            log "No test is running"
            ;;
        POD_UNAVAILABLE)
            warn "Pod is not running. Use '$0 <SCENARIO_ID>' to start."
            ;;
    esac
    exit 0
fi

if [[ "${1:-}" == "--logs" ]]; then
    SCENARIO_FOR_LOGS="${2:-}"
    if [[ -z "$SCENARIO_FOR_LOGS" ]]; then
        # Auto-detect from RUNNING file
        SCENARIO_FOR_LOGS=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
            cat ${REMOTE_DIR}/results/RUNNING 2>/dev/null || echo "")
        if [[ -z "$SCENARIO_FOR_LOGS" ]]; then
            err "No running test found. Specify scenario ID: $0 --logs C5"
            exit 1
        fi
    fi
    log "Tailing logs for ${SCENARIO_FOR_LOGS}..."
    log "(Ctrl+C to stop following — the test keeps running)"
    echo ""
    if [[ "$SCENARIO_FOR_LOGS" == "ALL" ]]; then
        kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
            tail -f ${REMOTE_DIR}/results/run_all.log 2>/dev/null || \
            warn "Master log not found yet. Suite may still be starting."
    else
        kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
            tail -f ${REMOTE_DIR}/results/${SCENARIO_FOR_LOGS}/run.log 2>/dev/null || \
            warn "Log file not found yet. Test may still be starting."
    fi
    exit 0
fi

if [[ "${1:-}" == "--results" ]]; then
    SCENARIO_FOR_RESULTS="${2:-}"
    local_results="${PROJECT_DIR}/results"
    if [[ -z "$SCENARIO_FOR_RESULTS" ]]; then
        log "Copying ALL results..."
        mkdir -p "$local_results"
        # List scenario folders on the pod and copy each one
        scenarios=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
            bash -c "ls -d ${REMOTE_DIR}/results/*/ 2>/dev/null | xargs -I{} basename {}" 2>/dev/null || echo "")
        if [[ -z "$scenarios" ]]; then
            warn "No scenario results found on pod"
            exit 1
        fi
        for s in $scenarios; do
            log "Copying ${s}..."
            mkdir -p "${local_results}/${s}"
            kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
                tar cf - -C ${REMOTE_DIR}/results/${s} . 2>/dev/null | \
                tar xf - -C "${local_results}/${s}" 2>/dev/null || true
        done
        ok "Results saved to ${local_results}/"
        ls -d "${local_results}/"*/ 2>/dev/null
    else
        log "Copying results for ${SCENARIO_FOR_RESULTS}..."
        mkdir -p "${local_results}/${SCENARIO_FOR_RESULTS}"
        kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
            tar cf - -C ${REMOTE_DIR}/results/${SCENARIO_FOR_RESULTS} . 2>/dev/null | \
            tar xf - -C "${local_results}/${SCENARIO_FOR_RESULTS}" 2>/dev/null || true
        ok "Results saved to ${local_results}/${SCENARIO_FOR_RESULTS}/"
        ls -lh "${local_results}/${SCENARIO_FOR_RESULTS}/" 2>/dev/null || warn "No files found for ${SCENARIO_FOR_RESULTS}"
    fi
    exit 0
fi

# ─── Parse main arguments ───────────────────────────────────────────────────

SCENARIO_ID="${1:?Usage: $0 <SCENARIO_ID> [--detach] | --list | --status | --logs | --results | --shell | --cleanup}"
DETACH=false
if [[ "${2:-}" == "--detach" ]]; then
    DETACH=true
fi

# ─── Parse scenario parameters ──────────────────────────────────────────────

get_scenario_params() {
    local id="$1"
    local CLUSTERIP="http://10.96.230.201:9091"
    local INGRESS="https://pushgateway.150.230.181.224.nip.io"

    case "$id" in
        # ClusterIP ramp
        C0) echo "--scenario C0 --endpoint $CLUSTERIP --nodes 10 --jitter 5 --interval 60 --duration 300 --jobs node+cluster" ;;
        C1) echo "--scenario C1 --endpoint $CLUSTERIP --nodes 100 --jitter 20 --interval 60 --duration 600 --jobs node+cluster" ;;
        C2) echo "--scenario C2 --endpoint $CLUSTERIP --nodes 250 --jitter 20 --interval 60 --duration 600 --jobs node+cluster" ;;
        C3) echo "--scenario C3 --endpoint $CLUSTERIP --nodes 500 --jitter 20 --interval 60 --duration 900 --jobs node+cluster" ;;
        C4) echo "--scenario C4 --endpoint $CLUSTERIP --nodes 750 --jitter 20 --interval 60 --duration 900 --jobs node+cluster" ;;
        C5) echo "--scenario C5 --endpoint $CLUSTERIP --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node+cluster" ;;
        C6) echo "--scenario C6 --endpoint $CLUSTERIP --nodes 1000 --jitter 20 --interval 60 --duration 7200 --jobs node+cluster" ;;
        C7) echo "--scenario C7 --endpoint $CLUSTERIP --nodes 1000 --jitter 0 --interval 60 --duration 1200 --jobs node+cluster" ;;

        # Ingress HTTPS ramp
        I0) echo "--scenario I0 --endpoint $INGRESS --nodes 10 --jitter 5 --interval 60 --duration 300 --jobs node+cluster" ;;
        I1) echo "--scenario I1 --endpoint $INGRESS --nodes 100 --jitter 20 --interval 60 --duration 600 --jobs node+cluster" ;;
        I2) echo "--scenario I2 --endpoint $INGRESS --nodes 250 --jitter 20 --interval 60 --duration 600 --jobs node+cluster" ;;
        I3) echo "--scenario I3 --endpoint $INGRESS --nodes 500 --jitter 20 --interval 60 --duration 900 --jobs node+cluster" ;;
        I4) echo "--scenario I4 --endpoint $INGRESS --nodes 750 --jitter 20 --interval 60 --duration 900 --jobs node+cluster" ;;
        I5) echo "--scenario I5 --endpoint $INGRESS --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node+cluster" ;;
        I6) echo "--scenario I6 --endpoint $INGRESS --nodes 1000 --jitter 20 --interval 60 --duration 7200 --jobs node+cluster" ;;
        I7) echo "--scenario I7 --endpoint $INGRESS --nodes 1000 --jitter 0 --interval 60 --duration 1200 --jobs node+cluster" ;;

        # Node-level isolation
        N1) echo "--scenario N1 --endpoint $CLUSTERIP --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node" ;;
        N2) echo "--scenario N2 --endpoint $INGRESS --nodes 1000 --jitter 20 --interval 60 --duration 1200 --jobs node" ;;

        # Cluster-level / pod metrics
        P1) echo "--scenario P1 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 1" ;;
        P2) echo "--scenario P2 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 10" ;;
        P3) echo "--scenario P3 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 50" ;;
        P4) echo "--scenario P4 --endpoint $CLUSTERIP --nodes 0 --jitter 5 --interval 60 --duration 1800 --jobs cluster --pod-multiplier 100" ;;

        *)
            err "Unknown scenario: $id"
            return 1
            ;;
    esac
}

# ─── Copy results back ──────────────────────────────────────────────────────

copy_results() {
    local scenario_id="$1"
    local local_results="${PROJECT_DIR}/results/${scenario_id}"
    mkdir -p "$local_results"

    log "Copying results back..."
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        tar cf - -C ${REMOTE_DIR}/results/${scenario_id} . 2>/dev/null | \
        tar xf - -C "${local_results}" 2>/dev/null || true
    ok "Results saved to ${local_results}/"
    ls -lh "${local_results}/" 2>/dev/null || true
}

# ─── Run: attached mode ─────────────────────────────────────────────────────

run_attached() {
    local scenario_id="$1"
    local params
    params=$(get_scenario_params "$scenario_id")

    log "Running scenario ${scenario_id} (attached — live output)..."
    echo ""

    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        python3 ${REMOTE_DIR}/scripts/generator.py $params

    echo ""
    ok "Scenario ${scenario_id} finished"
}

# ─── Run: detached mode ─────────────────────────────────────────────────────

run_detached() {
    local scenario_id="$1"
    local params
    params=$(get_scenario_params "$scenario_id")

    log "Launching scenario ${scenario_id} in DETACHED mode..."
    log "The test runs inside the pod — safe to close your terminal."
    echo ""

    # Launch inside the pod with nohup, redirect output to a log file in the scenario subfolder.
    # After the generator finishes, a DONE marker is written so --status can detect completion.
    kubectl exec "$POD_NAME" -n "$NAMESPACE" -- \
        bash -c "
            mkdir -p ${REMOTE_DIR}/results/${scenario_id}
            echo '${scenario_id}' > ${REMOTE_DIR}/results/RUNNING
            echo \"\$(date -Iseconds)\" > ${REMOTE_DIR}/results/RUNNING_STARTED
            nohup bash -c '
                python3 ${REMOTE_DIR}/scripts/generator.py ${params} 2>&1
                echo \"\$(date -Iseconds)\" > ${REMOTE_DIR}/results/${scenario_id}/DONE
                rm -f ${REMOTE_DIR}/results/RUNNING ${REMOTE_DIR}/results/RUNNING_PID ${REMOTE_DIR}/results/RUNNING_STARTED
            ' > ${REMOTE_DIR}/results/${scenario_id}/run.log 2>&1 &
            PID=\$!
            echo \$PID > ${REMOTE_DIR}/results/RUNNING_PID
            echo \"Generator started with PID \$PID\"
        "

    echo ""
    ok "Test is running in the background inside the pod."
    echo ""
    echo "  Check status:     $0 --status"
    echo "  Follow live logs: $0 --logs ${scenario_id}"
    echo "  Copy results:     $0 --results ${scenario_id}"
    echo "  Shell into pod:   $0 --shell"
    echo ""
    echo "  You can now safely close this terminal."
    echo ""

    # Auto-copy: launch a local background process that waits for the test to finish
    # and then copies results back. Survives terminal close via nohup.
    local local_results="${PROJECT_DIR}/results/${scenario_id}"
    nohup bash -c "
        while true; do
            sleep 30
            done_marker=\$(kubectl exec ${POD_NAME} -n ${NAMESPACE} -- \
                cat ${REMOTE_DIR}/results/${scenario_id}/DONE 2>/dev/null) || true
            if [[ -n \"\$done_marker\" ]]; then
                mkdir -p '${local_results}'
                kubectl exec ${POD_NAME} -n ${NAMESPACE} -- \
                    tar cf - -C ${REMOTE_DIR}/results/${scenario_id} . 2>/dev/null | \
                    tar xf - -C '${local_results}' 2>/dev/null
                echo \"[auto-copy] Results for ${scenario_id} saved to ${local_results}/\" >> '${PROJECT_DIR}/results/auto_copy.log'
                exit 0
            fi
        done
    " >> "${PROJECT_DIR}/results/auto_copy.log" 2>&1 &
    local AUTO_PID=$!
    log "Auto-copy watcher started (PID ${AUTO_PID}) — results will be copied when test finishes."
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
if [[ "$DETACH" == true ]]; then
    echo -e "${GREEN}  In-Cluster Stress Test — Scenario ${SCENARIO_ID} (DETACHED)${NC}"
else
    echo -e "${GREEN}  In-Cluster Stress Test — Scenario ${SCENARIO_ID}${NC}"
fi
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

mkdir -p "${PROJECT_DIR}/results"

ensure_pod
sync_files

if [[ "$DETACH" == true ]]; then
    run_detached "$SCENARIO_ID"
else
    run_attached "$SCENARIO_ID"
    copy_results "$SCENARIO_ID"
    echo ""
    ok "Done! Results are in ${PROJECT_DIR}/results/${SCENARIO_ID}/"
    echo ""
fi
