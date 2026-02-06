#!/bin/bash
###############################################################################
# Cleanup
#
# Removes all stress-test resources: emitters, scrape config, targets.
# Optionally restores Prometheus to its original configuration.
#
# Usage:
#   ./cleanup.sh              # remove emitters + clear targets
#   ./cleanup.sh --full       # also revert Prometheus config to backup
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="lens"

FULL=false
if [[ "${1:-}" == "--full" ]]; then
    FULL=true
fi

echo "Prometheus Stress Test — Cleanup"
echo "================================"
echo ""

# ─── Clear targets ───────────────────────────────────────────────────────────

echo "1. Clearing targets (N=0)..."
bash "${SCRIPT_DIR}/generate_targets.sh" 0 2>/dev/null || echo "   (skipped — generate_targets.sh failed)"

# ─── Remove emitters ────────────────────────────────────────────────────────

echo ""
echo "2. Removing emitter Deployments, Services, ConfigMaps..."
bash "${SCRIPT_DIR}/setup_emitters.sh" --delete 2>/dev/null || echo "   (skipped — setup_emitters.sh --delete failed)"

# ─── Revert Prometheus config ───────────────────────────────────────────────

if [[ "$FULL" == true ]]; then
    echo ""
    echo "3. Reverting Prometheus config to backup..."
    bash "${SCRIPT_DIR}/setup_prometheus.sh" --revert 2>/dev/null || {
        echo "   WARNING: auto-revert failed."
        echo "   Manual steps:"
        echo "     kubectl apply -f ${PROJECT_DIR}/results/prometheus-cm-backup.yaml"
        echo "     kubectl -n ${NAMESPACE} rollout restart deploy/lens-prometheus-server"
    }
else
    echo ""
    echo "3. Skipping Prometheus config revert (use --full to revert)."
    echo "   The 4 scale-test scrape jobs remain configured but have 0 targets."
fi

# ─── Kill leftover port-forwards ────────────────────────────────────────────

echo ""
echo "4. Killing leftover port-forward processes..."
pkill -f "port-forward.*lens-prometheus-server.*9090" 2>/dev/null && echo "   Killed." || echo "   None found."

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Cleanup complete."
if [[ "$FULL" == false ]]; then
    echo ""
    echo "Note: Prometheus still has the scale-test scrape config."
    echo "Run './cleanup.sh --full' to fully revert, or keep it for future test runs."
fi
