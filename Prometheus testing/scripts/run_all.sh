#!/bin/bash
###############################################################################
# Run All Scenarios
#
# Runs R0 through R4 sequentially, with cleanup between each.
# Optionally runs R5 (soak) at the highest stable N.
#
# Usage:
#   ./run_all.sh
#   ./run_all.sh --with-soak        # include R5 soak at best stable N
#   ./run_all.sh --from R2           # resume from R2
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results"
MASTER_LOG="${RESULTS_DIR}/run_all.log"

mkdir -p "$RESULTS_DIR"

WITH_SOAK=false
START_FROM="R0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-soak) WITH_SOAK=true; shift ;;
        --from) START_FROM="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCENARIOS=("R0" "R1" "R2" "R3" "R4")
SOAK_N=0  # will be set to highest stable N

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$MASTER_LOG"
}

clear_targets() {
    log "Clearing targets (N=0)..."
    bash "${SCRIPT_DIR}/generate_targets.sh" 0 >> "$MASTER_LOG" 2>&1
    log "Waiting 90s for targets to drain and Prometheus to stabilize..."
    sleep 90
}

# ─── Main ────────────────────────────────────────────────────────────────────

ALL_START=$(date +%s)

log "╔══════════════════════════════════════════════════════════════╗"
log "║       PROMETHEUS STRESS TEST SUITE — STARTING               ║"
log "║       $(date '+%Y-%m-%d %H:%M:%S')                                  ║"
log "║       Start from: ${START_FROM}                                     ║"
log "╚══════════════════════════════════════════════════════════════╝"
log ""

STARTED=false
for SCENARIO in "${SCENARIOS[@]}"; do
    # Skip until we reach START_FROM
    if [[ "$STARTED" == false && "$SCENARIO" != "$START_FROM" ]]; then
        log "Skipping ${SCENARIO} (starting from ${START_FROM})"
        continue
    fi
    STARTED=true

    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "STARTING ${SCENARIO}"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    SCENARIO_START=$(date +%s)
    bash "${SCRIPT_DIR}/run_scenario.sh" "$SCENARIO" 2>&1 | tee -a "$MASTER_LOG"
    EXIT_CODE=${PIPESTATUS[0]}
    SCENARIO_END=$(date +%s)
    SCENARIO_ELAPSED=$(( SCENARIO_END - SCENARIO_START ))

    if [[ $EXIT_CODE -eq 0 ]]; then
        log "COMPLETED ${SCENARIO} in $((SCENARIO_ELAPSED / 60))m"
        # Track highest stable N for soak
        # Read N from the scenario's metrics CSV (targets_discovered / 4)
        CSV="${RESULTS_DIR}/${SCENARIO}/${SCENARIO}_metrics.csv"
        if [[ -f "$CSV" ]]; then
            last_success=$(tail -1 "$CSV" | cut -d, -f5)
            if python3 -c "exit(0 if float('${last_success:-0}') >= 95 else 1)" 2>/dev/null; then
                # Extract N from scenario definition
                case "$SCENARIO" in
                    R0) SOAK_N=10 ;;
                    R1) SOAK_N=50 ;;
                    R2) SOAK_N=100 ;;
                    R3) SOAK_N=200 ;;
                    R4) SOAK_N=250 ;;
                esac
            fi
        fi
    else
        log "FAILED ${SCENARIO} (exit ${EXIT_CODE}) after $((SCENARIO_ELAPSED / 60))m"
    fi

    # Clear targets between scenarios
    if [[ "$SCENARIO" != "${SCENARIOS[-1]}" ]]; then
        clear_targets
    fi

    log ""
done

# ─── Optional soak test ─────────────────────────────────────────────────────

if [[ "$WITH_SOAK" == true && "$SOAK_N" -gt 0 ]]; then
    clear_targets

    SOAK_DURATION=21600  # 6 hours
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "STARTING R5 (soak) — N=${SOAK_N}, duration=${SOAK_DURATION}s (6h)"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    bash "${SCRIPT_DIR}/run_scenario.sh" R5 "$SOAK_N" "$SOAK_DURATION" 2>&1 | tee -a "$MASTER_LOG"
fi

# ─── Done ────────────────────────────────────────────────────────────────────

ALL_END=$(date +%s)
ALL_ELAPSED=$(( ALL_END - ALL_START ))
ALL_HOURS=$(( ALL_ELAPSED / 3600 ))
ALL_MINS=$(( (ALL_ELAPSED % 3600) / 60 ))

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║       PROMETHEUS STRESS TEST SUITE — COMPLETE               ║"
log "║       Total time: ${ALL_HOURS}h ${ALL_MINS}m                                 ║"
log "║       Highest stable N: ${SOAK_N}                                   ║"
log "╚══════════════════════════════════════════════════════════════╝"

echo "$(date -Iseconds)" > "${RESULTS_DIR}/ALL_DONE"
