#!/bin/bash
###############################################################################
# Generate Targets
#
# Generates file_sd JSON target files for N simulated nodes and patches
# the Prometheus ConfigMap. Prometheus picks up changes via file_sd refresh.
#
# Usage:
#   ./generate_targets.sh <N>
#   ./generate_targets.sh 100    # 100 nodes = 400 targets
#   ./generate_targets.sh 0      # remove all targets
###############################################################################

set -euo pipefail

N="${1:?Usage: $0 <N>  (number of simulated nodes)}"
NAMESPACE="lens"
CM_NAME="lens-prometheus-server"

EMITTERS=("node-exporter" "amd-gpu" "lens-node" "drhpc")

echo "Generating targets for N=${N} nodes ($(( N * 4 )) total targets)..."

# ─── Generate JSON target files ─────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for emitter in "${EMITTERS[@]}"; do
    FILE="${TMPDIR}/targets-${emitter}.json"
    if [[ "$N" -eq 0 ]]; then
        echo "[]" > "$FILE"
    else
        python3 -c "
import json
targets = []
for i in range(1, ${N} + 1):
    targets.append({
        'targets': ['emitter-${emitter}:8080'],
        'labels': {'node_id': f'node-{i:06d}'}
    })
print(json.dumps(targets, indent=2))
" > "$FILE"
    fi
    lines=$(wc -l < "$FILE")
    echo "  targets-${emitter}.json: ${lines} lines"
done

# ─── Patch the ConfigMap ────────────────────────────────────────────────────

echo "Patching ConfigMap ${CM_NAME} with new target files..."
python3 -c "
import json, subprocess, sys

cm = json.loads(subprocess.check_output([
    'kubectl', '-n', '${NAMESPACE}', 'get', 'cm', '${CM_NAME}', '-o', 'json'
]))

for emitter in ['node-exporter', 'amd-gpu', 'lens-node', 'drhpc']:
    filepath = '${TMPDIR}/targets-' + emitter + '.json'
    with open(filepath) as f:
        cm['data']['targets-' + emitter + '.json'] = f.read()

for key in ['resourceVersion', 'uid', 'creationTimestamp', 'managedFields']:
    cm['metadata'].pop(key, None)

proc = subprocess.run(
    ['kubectl', 'apply', '-f', '-'],
    input=json.dumps(cm).encode(),
    capture_output=True
)
if proc.returncode != 0:
    print('ERROR:', proc.stderr.decode(), file=sys.stderr)
    sys.exit(1)
print(proc.stdout.decode().strip())
"

echo ""
if [[ "$N" -eq 0 ]]; then
    echo "Targets cleared. Prometheus will drop targets on next file_sd refresh."
else
    echo "Targets set to N=${N} ($(( N * 4 )) total)."
    echo "Prometheus will discover them within ~15–60 seconds (file_sd refresh + kubelet sync)."
fi
