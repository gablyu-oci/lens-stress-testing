#!/bin/bash
###############################################################################
# Setup Emitters
#
# Deploys 4 emitter Deployments + Services in the lens namespace.
# Each emitter serves a static Prometheus metrics payload via nginx.
#
# Usage:
#   ./setup_emitters.sh
#   ./setup_emitters.sh --delete   # tear down emitters only
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PAYLOADS_DIR="${PROJECT_DIR}/payloads"
NAMESPACE="lens"

# Emitter definitions: name|payload_file|replicas
EMITTERS=(
    "node-exporter|sample-node-exporter-payload.txt|3"
    "amd-gpu|sample-amd-gpu-payload.txt|3"
    "lens-node|payload-oci-lens-node.txt|3"
    "drhpc|payload-oci-lens-drhpc.txt|3"
)

# ─── Delete mode ─────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--delete" ]]; then
    echo "Deleting emitter resources..."
    for entry in "${EMITTERS[@]}"; do
        IFS='|' read -r name _ _ <<< "$entry"
        kubectl -n "$NAMESPACE" delete deploy "emitter-${name}" --ignore-not-found
        kubectl -n "$NAMESPACE" delete svc "emitter-${name}" --ignore-not-found
        kubectl -n "$NAMESPACE" delete cm "emitter-payload-${name}" --ignore-not-found
    done
    kubectl -n "$NAMESPACE" delete cm emitter-nginx-conf --ignore-not-found
    echo "Done."
    exit 0
fi

# ─── Create nginx config ────────────────────────────────────────────────────

echo "Creating nginx config ConfigMap..."
kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: emitter-nginx-conf
  namespace: lens
  labels:
    app: emitter
data:
  default.conf: |
    server {
        listen 8080;
        server_name _;
        root /data;

        location = /metrics {
            types { }
            default_type "text/plain; version=0.0.4; charset=utf-8";
        }

        location = /healthz {
            return 200 "ok\n";
            default_type text/plain;
        }
    }
EOF

# ─── Create payload ConfigMaps + Deployments + Services ─────────────────────

for entry in "${EMITTERS[@]}"; do
    IFS='|' read -r name payload_file replicas <<< "$entry"
    payload_path="${PAYLOADS_DIR}/${payload_file}"

    if [[ ! -f "$payload_path" ]]; then
        echo "ERROR: payload file not found: ${payload_path}"
        exit 1
    fi

    payload_size=$(du -h "$payload_path" | cut -f1)
    echo ""
    echo "── emitter-${name} (${payload_size}) ──"

    # Payload ConfigMap (use create/replace to avoid annotation size limit on large payloads)
    echo "  Creating payload ConfigMap..."
    if kubectl -n "$NAMESPACE" get cm "emitter-payload-${name}" >/dev/null 2>&1; then
        kubectl -n "$NAMESPACE" create configmap "emitter-payload-${name}" \
            --from-file="metrics=${payload_path}" \
            --dry-run=client -o yaml | kubectl -n "$NAMESPACE" replace -f -
    else
        kubectl -n "$NAMESPACE" create configmap "emitter-payload-${name}" \
            --from-file="metrics=${payload_path}"
    fi

    # Label the ConfigMap
    kubectl -n "$NAMESPACE" label cm "emitter-payload-${name}" app=emitter --overwrite

    # Deployment + Service
    echo "  Creating Deployment (${replicas} replicas) + Service..."
    kubectl -n "$NAMESPACE" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: emitter-${name}
  namespace: ${NAMESPACE}
  labels:
    app: emitter
    emitter-type: ${name}
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: emitter
      emitter-type: ${name}
  template:
    metadata:
      labels:
        app: emitter
        emitter-type: ${name}
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 8080
          name: metrics
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 200m
            memory: 64Mi
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 5
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: default.conf
          readOnly: true
        - name: payload
          mountPath: /data/metrics
          subPath: metrics
          readOnly: true
      volumes:
      - name: nginx-conf
        configMap:
          name: emitter-nginx-conf
      - name: payload
        configMap:
          name: emitter-payload-${name}
---
apiVersion: v1
kind: Service
metadata:
  name: emitter-${name}
  namespace: ${NAMESPACE}
  labels:
    app: emitter
    emitter-type: ${name}
spec:
  selector:
    app: emitter
    emitter-type: ${name}
  ports:
  - port: 8080
    targetPort: 8080
    name: metrics
YAML
done

# ─── Wait for rollout ───────────────────────────────────────────────────────

echo ""
echo "Waiting for all emitters to be ready..."
for entry in "${EMITTERS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    kubectl -n "$NAMESPACE" rollout status deploy "emitter-${name}" --timeout=120s
done

# ─── Sanity check ───────────────────────────────────────────────────────────

echo ""
echo "Sanity check — fetching /metrics from each emitter:"
for entry in "${EMITTERS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    echo -n "  emitter-${name}: "
    lines=$(kubectl -n "$NAMESPACE" exec deploy/"emitter-${name}" -- \
        wget -qO- "http://127.0.0.1:8080/metrics" 2>/dev/null | wc -l)
    echo "${lines} lines"
done

echo ""
echo "Emitter setup complete."
