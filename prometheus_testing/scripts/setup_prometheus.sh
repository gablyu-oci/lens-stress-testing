#!/bin/bash
###############################################################################
# Setup Prometheus Scrape Config
#
# Adds the 4 scale-test scrape jobs to Prometheus and mounts the target
# files ConfigMap. Run once before starting scenarios.
#
# Prerequisites: setup_emitters.sh has been run.
#
# Usage:
#   ./setup_prometheus.sh
#   ./setup_prometheus.sh --revert   # restore original config
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NAMESPACE="lens"
CM_NAME="lens-prometheus-server"
DEPLOY_NAME="lens-prometheus-server"
TARGETS_CM="prom-scale-targets"
BACKUP_FILE="${PROJECT_DIR}/results/prometheus-cm-backup.yaml"

# ─── Revert mode ────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--revert" ]]; then
    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo "ERROR: backup not found at ${BACKUP_FILE}"
        echo "Cannot revert without backup."
        exit 1
    fi
    echo "Reverting Prometheus config from backup..."
    kubectl apply -f "$BACKUP_FILE"

    echo "Removing targets ConfigMap..."
    kubectl -n "$NAMESPACE" delete cm "$TARGETS_CM" --ignore-not-found

    echo "Removing targets volume mount from Deployment..."
    # Remove the volume and volumeMount we added (best-effort)
    kubectl -n "$NAMESPACE" patch deploy "$DEPLOY_NAME" --type='json' -p='[
        {"op": "test", "path": "/spec/template/spec/volumes/2/name", "value": "scale-targets"},
        {"op": "remove", "path": "/spec/template/spec/volumes/2"}
    ]' 2>/dev/null || echo "  (volume already removed or index changed — check manually)"

    echo "Restarting Prometheus..."
    kubectl -n "$NAMESPACE" rollout restart deploy "$DEPLOY_NAME"
    kubectl -n "$NAMESPACE" rollout status deploy "$DEPLOY_NAME" --timeout=180s
    echo "Revert complete."
    exit 0
fi

# ─── Backup current config ──────────────────────────────────────────────────

mkdir -p "$(dirname "$BACKUP_FILE")"
echo "Backing up current ConfigMap to ${BACKUP_FILE}..."
kubectl -n "$NAMESPACE" get cm "$CM_NAME" -o yaml > "$BACKUP_FILE"

# ─── Check if already configured ────────────────────────────────────────────

CURRENT_YML=$(kubectl -n "$NAMESPACE" get cm "$CM_NAME" -o jsonpath='{.data.prometheus\.yml}')
if echo "$CURRENT_YML" | grep -q "scale-test-scrape.yml"; then
    echo "Scale test scrape config already present in prometheus.yml."
    echo "To reconfigure, run: $0 --revert  then re-run $0"
    exit 0
fi

# ─── Add scrape_config_files directive to prometheus.yml ─────────────────────

echo "Adding scrape_config_files directive to prometheus.yml..."

# Prometheus v3.5.0 supports scrape_config_files — we use it to keep
# the scale-test jobs in a separate file without modifying the main config.
UPDATED_YML="${CURRENT_YML}

# --- Prometheus Scale Test (added by setup_prometheus.sh) ---
scrape_config_files:
  - /etc/config/scale-test-scrape.yml
"

# The scale-test scrape config file (4 jobs)
SCRAPE_CONFIG='scrape_configs:
  - job_name: "lens-scale-test-node-exporter"
    scrape_interval: 60s
    scrape_timeout: 10s
    metrics_path: /metrics
    file_sd_configs:
      - files:
          - /etc/config/targets-node-exporter.json
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [node_id]
        target_label: instance

  - job_name: "lens-scale-test-amd-gpu"
    scrape_interval: 60s
    scrape_timeout: 10s
    metrics_path: /metrics
    file_sd_configs:
      - files:
          - /etc/config/targets-amd-gpu.json
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [node_id]
        target_label: instance

  - job_name: "lens-scale-test-lens-node"
    scrape_interval: 60s
    scrape_timeout: 10s
    metrics_path: /metrics
    file_sd_configs:
      - files:
          - /etc/config/targets-lens-node.json
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [node_id]
        target_label: instance

  - job_name: "lens-scale-test-drhpc"
    scrape_interval: 60s
    scrape_timeout: 10s
    metrics_path: /metrics
    file_sd_configs:
      - files:
          - /etc/config/targets-drhpc.json
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [node_id]
        target_label: instance
'

# Empty initial targets (Prometheus needs the files to exist)
EMPTY_TARGETS='[]'

# ─── Patch the ConfigMap ────────────────────────────────────────────────────

echo "Patching ConfigMap with scrape config and empty target files..."

# Write to temp files so Python can read them without shell quoting issues
echo "$UPDATED_YML" > /tmp/_prom_updated_yml
echo "$SCRAPE_CONFIG" > /tmp/_prom_scrape_config

python3 << 'PYEOF'
import json, subprocess, sys

cm = json.loads(subprocess.check_output([
    "kubectl", "-n", "lens", "get", "cm", "lens-prometheus-server", "-o", "json"
], stderr=subprocess.DEVNULL))

# Read the updated files from environment / heredoc
import os

# Update data keys
with open("/tmp/_prom_updated_yml") as f:
    cm["data"]["prometheus.yml"] = f.read()
with open("/tmp/_prom_scrape_config") as f:
    cm["data"]["scale-test-scrape.yml"] = f.read()
cm["data"]["targets-node-exporter.json"] = "[]"
cm["data"]["targets-amd-gpu.json"] = "[]"
cm["data"]["targets-lens-node.json"] = "[]"
cm["data"]["targets-drhpc.json"] = "[]"

# Clean metadata for apply
for key in ["resourceVersion", "uid", "creationTimestamp", "managedFields"]:
    cm["metadata"].pop(key, None)
cm["metadata"].pop("annotations", None)

proc = subprocess.run(
    ["kubectl", "apply", "-f", "-"],
    input=json.dumps(cm).encode(),
    capture_output=True
)
if proc.returncode != 0:
    print("ERROR applying ConfigMap:", proc.stderr.decode(), file=sys.stderr)
    sys.exit(1)
print(proc.stdout.decode().strip())
PYEOF

rm -f /tmp/_prom_updated_yml /tmp/_prom_scrape_config

# ─── Wait for config reload ────────────────────────────────────────────────

echo "Waiting for Prometheus config-reloader to pick up changes..."
sleep 10

# Check if Prometheus reloaded successfully
echo "Verifying Prometheus has the new scrape jobs..."
kubectl -n "$NAMESPACE" exec deploy/"$DEPLOY_NAME" -c prometheus-server -- \
    wget -qO- "http://localhost:9090/api/v1/status/config" 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
yml = data.get('data', {}).get('yaml', '')
jobs = [l.strip() for l in yml.split('\n') if 'lens-scale-test' in l]
if jobs:
    print('  Found scale-test jobs in active config:')
    for j in jobs:
        print(f'    {j}')
else:
    print('  WARNING: scale-test jobs NOT found in active config.')
    print('  Prometheus may need a restart.')
    sys.exit(1)
"

echo ""
echo "Prometheus setup complete."
echo "Next: run generate_targets.sh <N> to set the target count."
