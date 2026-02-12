#!/bin/bash
###############################################################################
# Pushgateway 2.0 Scenario Runner
#
# Usage: ./run_scenario.sh <SCENARIO_ID>
#        ./run_scenario.sh --list
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results"
CLUSTERIP="http://10.96.242.191:9091"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCENARIOS=(
    "C0|${CLUSTERIP}|10|node+cluster+healthcheck|5|60|300|Sanity"
    "C20|${CLUSTERIP}|20|node+cluster+healthcheck|10|60|300|20 nodes"
    "C30|${CLUSTERIP}|30|node+cluster+healthcheck|10|60|300|30 nodes"
    "C50|${CLUSTERIP}|50|node+cluster+healthcheck|15|60|600|50 nodes"
    "C80|${CLUSTERIP}|80|node+cluster+healthcheck|15|60|600|80 nodes"
    "C1|${CLUSTERIP}|100|node+cluster+healthcheck|20|60|600|100 nodes"
    "C150|${CLUSTERIP}|150|node+cluster+healthcheck|20|60|600|150 nodes"
    "C200|${CLUSTERIP}|200|node+cluster+healthcheck|20|60|600|200 nodes"
    "C2|${CLUSTERIP}|250|node+cluster+healthcheck|20|60|600|250 nodes"
    "C300|${CLUSTERIP}|300|node+cluster+healthcheck|20|60|900|300 nodes"
    "C400|${CLUSTERIP}|400|node+cluster+healthcheck|20|60|900|400 nodes"
    "C3|${CLUSTERIP}|500|node+cluster+healthcheck|20|60|900|500 nodes"
    "C4|${CLUSTERIP}|750|node+cluster+healthcheck|20|60|900|750 nodes"
    "C5|${CLUSTERIP}|1000|node+cluster+healthcheck|20|60|1200|Target 1k"
    "C6|${CLUSTERIP}|1000|node+cluster+healthcheck|20|60|7200|Soak 2h"
    "C7|${CLUSTERIP}|1000|node+cluster+healthcheck|0|60|1200|Spike"
    "N1|${CLUSTERIP}|1000|node|20|60|1200|Node-only"
    "P1|${CLUSTERIP}|0|cluster|5|60|1800|Pod x1"
    "P2|${CLUSTERIP}|0|cluster|5|60|1800|Pod x10"
    "P3|${CLUSTERIP}|0|cluster|5|60|1800|Pod x50"
    "P4|${CLUSTERIP}|0|cluster|5|60|1800|Pod x100"
)

declare -A POD_MULTIPLIERS=(
    ["P1"]=1 ["P2"]=10 ["P3"]=50 ["P4"]=100
)

list_scenarios() {
    echo ""
    echo "Pushgateway 2.0 — Available Scenarios"
    echo "====================================="
    printf "%-4s %-10s %6s %-22s %6s %4s %8s  %s\n" \
        "ID" "Endpoint" "Nodes" "Jobs" "Jitter" "Int" "Duration" "Purpose"
    echo "---- ---------- ------ ---------------------- ------ ---- --------  -------"
    for entry in "${SCENARIOS[@]}"; do
        IFS='|' read -r id ep nodes jobs jitter interval dur purpose <<< "$entry"
        ep_short=$([[ "$ep" == *"10.96"* ]] && echo "ClusterIP" || echo "Ingress")
        (( dur >= 3600 )) && dur_human="$((dur/3600))h" || dur_human="$((dur/60))m"
        printf "%-4s %-10s %6s %-22s %5ss %3ss %8s  %s\n" \
            "$id" "$ep_short" "$nodes" "$jobs" "$jitter" "$interval" "$dur_human" "$purpose"
    done
    echo ""
}

find_scenario() {
    local target="$1"
    for entry in "${SCENARIOS[@]}"; do
        IFS='|' read -r id rest <<< "$entry"
        [[ "$id" == "$target" ]] && { echo "$entry"; return 0; }
    done
    return 1
}

stop_monitor() {
    local pid_file="${RESULTS_DIR}/${1}_monitor.pid"
    [[ -f "$pid_file" ]] && {
        local pid=$(cat "$pid_file")
        kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
    }
}

[[ "${1:-}" == "--list" || "${1:-}" == "-l" ]] && { list_scenarios; exit 0; }

SCENARIO_ID="${1:?Usage: $0 <SCENARIO_ID> or $0 --list}"

SCENARIO_DEF=$(find_scenario "$SCENARIO_ID" || true)
[[ -z "$SCENARIO_DEF" ]] && {
    echo -e "${RED}ERROR: Unknown scenario '$SCENARIO_ID'${NC}"
    echo "Use '$0 --list' to see available scenarios"
    exit 1
}

IFS='|' read -r _id ENDPOINT NODES JOBS JITTER INTERVAL DURATION PURPOSE <<< "$SCENARIO_DEF"
POD_MULT="${POD_MULTIPLIERS[$SCENARIO_ID]:-1}"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Pushgateway 2.0 — Scenario ${SCENARIO_ID}: ${PURPOSE}${NC}"
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

python3 -c "import aiohttp" 2>/dev/null || {
    echo -e "${YELLOW}[runner]${NC} Installing Python dependencies..."
    pip3 install -q -r "${SCRIPT_DIR}/requirements.txt"
}

mkdir -p "$RESULTS_DIR"

echo -e "${BLUE}[runner]${NC} Starting health monitor..."
bash "${SCRIPT_DIR}/monitor.sh" "$SCENARIO_ID" 30 &
trap "stop_monitor '$SCENARIO_ID'" EXIT

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

echo -e "${BLUE}[runner]${NC} Starting generator..."
python3 "${SCRIPT_DIR}/generator.py" "${GENERATOR_ARGS[@]}"
GEN_EXIT=$?

stop_monitor "$SCENARIO_ID"

echo ""
[[ $GEN_EXIT -eq 0 ]] && echo -e "${GREEN}[runner] Scenario ${SCENARIO_ID} completed${NC}" || echo -e "${RED}[runner] Scenario ${SCENARIO_ID} exited ${GEN_EXIT}${NC}"
echo ""
echo "Results in: ${RESULTS_DIR}/"
ls -lh "${RESULTS_DIR}/${SCENARIO_ID}"* 2>/dev/null || true
echo ""
