#!/bin/bash
###############################################################################
# Scenario Runner
#
# Maps scenario IDs to generator.py parameters, starts the monitor,
# runs the test, and collects results.
#
# Usage:
#   ./run_scenario.sh <SCENARIO_ID>
#   ./run_scenario.sh C0
#   ./run_scenario.sh I3
#   ./run_scenario.sh --list     # show all scenarios
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results"
CLUSTERIP="http://10.96.230.201:9091"
INGRESS="https://pushgateway.150.230.181.224.nip.io"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Scenario Definitions ───────────────────────────────────────────────────
# Format: scenario_id|endpoint|nodes|jobs|jitter|interval|duration|purpose

SCENARIOS=(
    # ── ClusterIP ramp ──────────────────────────────────────────────────────
    "C0|${CLUSTERIP}|10|node+cluster|5|60|300|Sanity: correctness, URLs, payload validity"
    "C1|${CLUSTERIP}|100|node+cluster|20|60|600|Early baseline, resource profile"
    "C2|${CLUSTERIP}|250|node+cluster|20|60|600|Ramp step"
    "C3|${CLUSTERIP}|500|node+cluster|20|60|900|Ramp step"
    "C4|${CLUSTERIP}|750|node+cluster|20|60|900|Ramp step"
    "C5|${CLUSTERIP}|1000|node+cluster|20|60|1200|Target ramp: stability at 1000"
    "C6|${CLUSTERIP}|1000|node+cluster|20|60|7200|Soak: detect slow degradation (2h)"
    "C7|${CLUSTERIP}|1000|node+cluster|0|60|1200|Spike: worst-case thundering herd"

    # ── Ingress HTTPS ramp ──────────────────────────────────────────────────
    "I0|${INGRESS}|10|node+cluster|5|60|300|Sanity: TLS/cert, endpoint reachability"
    "I1|${INGRESS}|100|node+cluster|20|60|600|Baseline over TLS"
    "I2|${INGRESS}|250|node+cluster|20|60|600|Ramp step"
    "I3|${INGRESS}|500|node+cluster|20|60|900|Ramp step"
    "I4|${INGRESS}|750|node+cluster|20|60|900|Ramp step"
    "I5|${INGRESS}|1000|node+cluster|20|60|1200|Target ramp over TLS"
    "I6|${INGRESS}|1000|node+cluster|20|60|7200|Soak over TLS (2h)"
    "I7|${INGRESS}|1000|node+cluster|0|60|1200|Spike over TLS"

    # ── Node-level isolation ────────────────────────────────────────────────
    "N1|${CLUSTERIP}|1000|node|20|60|1200|Node-level only, ClusterIP"
    "N2|${INGRESS}|1000|node|20|60|1200|Node-level only, Ingress"

    # ── Cluster-level / pod metrics isolation ───────────────────────────────
    "P1|${CLUSTERIP}|0|cluster|5|60|1800|Baseline cluster-level impact"
    "P2|${CLUSTERIP}|0|cluster|5|60|1800|Pod metrics inflated x10"
    "P3|${CLUSTERIP}|0|cluster|5|60|1800|Pod metrics inflated x50"
    "P4|${CLUSTERIP}|0|cluster|5|60|1800|Pod metrics inflated x100"
)

# Pod multiplier lookup for P-scenarios
declare -A POD_MULTIPLIERS=(
    ["P1"]=1
    ["P2"]=10
    ["P3"]=50
    ["P4"]=100
)

# ─── Functions ───────────────────────────────────────────────────────────────

list_scenarios() {
    echo ""
    echo "Available Scenarios"
    echo "==================="
    printf "%-4s %-10s %6s %-14s %6s %4s %8s  %s\n" \
        "ID" "Endpoint" "Nodes" "Jobs" "Jitter" "Int" "Duration" "Purpose"
    echo "---  --------  -----  ------------  ------  ---  --------  -------"
    for entry in "${SCENARIOS[@]}"; do
        IFS='|' read -r id ep nodes jobs jitter interval dur purpose <<< "$entry"
        local ep_short
        if [[ "$ep" == *"10.96"* ]]; then
            ep_short="ClusterIP"
        else
            ep_short="Ingress"
        fi
        local dur_human
        if (( dur >= 3600 )); then
            dur_human="$((dur/3600))h"
        else
            dur_human="$((dur/60))m"
        fi
        printf "%-4s %-10s %6s %-14s %5ss %3ss %8s  %s\n" \
            "$id" "$ep_short" "$nodes" "$jobs" "$jitter" "$interval" "$dur_human" "$purpose"
    done
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

stop_monitor() {
    local pid_file="${RESULTS_DIR}/${1}_monitor.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            echo -e "${BLUE}[runner]${NC} Monitor stopped (PID $pid)"
        fi
        rm -f "$pid_file"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    list_scenarios
    exit 0
fi

SCENARIO_ID="${1:?Usage: $0 <SCENARIO_ID> or $0 --list}"

# Find scenario definition
SCENARIO_DEF=$(find_scenario "$SCENARIO_ID" || true)
if [[ -z "$SCENARIO_DEF" ]]; then
    echo -e "${RED}ERROR: Unknown scenario '$SCENARIO_ID'${NC}"
    echo "Use '$0 --list' to see available scenarios"
    exit 1
fi

IFS='|' read -r _id ENDPOINT NODES JOBS JITTER INTERVAL DURATION PURPOSE <<< "$SCENARIO_DEF"

# Pod multiplier for P-scenarios
POD_MULT="${POD_MULTIPLIERS[$SCENARIO_ID]:-1}"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Scenario ${SCENARIO_ID}: ${PURPOSE}${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Endpoint:       ${ENDPOINT}"
echo -e "  Nodes:          ${NODES}"
echo -e "  Jobs:           ${JOBS}"
echo -e "  Jitter:         ${JITTER}s"
echo -e "  Interval:       ${INTERVAL}s"
echo -e "  Duration:       ${DURATION}s ($((DURATION / 60)) min)"
echo -e "  Pod multiplier: ${POD_MULT}x"
echo ""

# Ensure dependencies
if ! python3 -c "import aiohttp" 2>/dev/null; then
    echo -e "${YELLOW}[runner]${NC} Installing Python dependencies..."
    pip3 install -q -r "${SCRIPT_DIR}/requirements.txt"
fi

mkdir -p "$RESULTS_DIR"

# Start monitor in background
echo -e "${BLUE}[runner]${NC} Starting health monitor..."
bash "${SCRIPT_DIR}/monitor.sh" "$SCENARIO_ID" 30 &
MONITOR_PID=$!
echo -e "${BLUE}[runner]${NC} Monitor PID: $MONITOR_PID"

# Ensure monitor stops on exit
trap "stop_monitor '$SCENARIO_ID'" EXIT

# Build generator args
GENERATOR_ARGS=(
    --scenario "$SCENARIO_ID"
    --endpoint "$ENDPOINT"
    --nodes "$NODES"
    --interval "$INTERVAL"
    --duration "$DURATION"
    --jitter "$JITTER"
    --jobs "$JOBS"
    --pod-multiplier "$POD_MULT"
)

# Run generator
echo -e "${BLUE}[runner]${NC} Starting generator..."
echo ""
python3 "${SCRIPT_DIR}/generator.py" "${GENERATOR_ARGS[@]}"
GEN_EXIT=$?

# Stop monitor
stop_monitor "$SCENARIO_ID"

echo ""
if [[ $GEN_EXIT -eq 0 ]]; then
    echo -e "${GREEN}[runner] Scenario ${SCENARIO_ID} completed successfully${NC}"
else
    echo -e "${RED}[runner] Scenario ${SCENARIO_ID} exited with code ${GEN_EXIT}${NC}"
fi

echo ""
echo "Results in: ${RESULTS_DIR}/"
ls -lh "${RESULTS_DIR}/${SCENARIO_ID}"* 2>/dev/null || true
echo ""
