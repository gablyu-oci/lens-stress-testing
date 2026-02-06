# Prometheus Server Stress Test — Testing Plan

## 1) Test procedure

### Step 0 — Pre-flight: disable Pushgateway scrape

Remove the Pushgateway scrape job so results only reflect the new scrape load.

Back up current Prometheus config:
```bash
kubectl -n lens get cm lens-prometheus-server -o yaml > /tmp/lens-prometheus-server.cm.yaml
```

Edit the ConfigMap and delete the Pushgateway scrape job:
```bash
kubectl -n lens edit cm lens-prometheus-server
```

Find and delete this block:
```yaml
- honor_labels: true
  job_name: prometheus-pushgateway
  kubernetes_sd_configs:
  - role: service
  relabel_configs:
  - action: keep
    regex: pushgateway
    source_labels:
    - __meta_kubernetes_service_annotation_prometheus_io_probe
```

Restart Prometheus:
```bash
kubectl -n lens rollout restart deploy/lens-prometheus-server
kubectl -n lens rollout status deploy/lens-prometheus-server
```

Verify the job is gone:
```bash
kubectl -n lens port-forward deploy/lens-prometheus-server 9090:9090
```
Query: `count(up{job="prometheus-pushgateway"})` — expect 0 or "no data".

---

### Step 1 — Deploy emitters (4 types, real payloads)

Simulate 4 exporter endpoints per node using real payload sizes, without needing N pods per type.

Deploy 4 Services, each fronting a small Deployment (2–5 replicas) that serves a static metrics file:

| Service | Endpoint | Payload size |
|---|---|---|
| `emitter-node-exporter` | `:8080/metrics` | ~572 KB |
| `emitter-amd-gpu` | `:8080/metrics` | ~768 KB |
| `emitter-lens-node` | `:8080/metrics` | ~28 KB |
| `emitter-drhpc` | `:8080/metrics` | ~16 KB |

Sanity check:
```bash
kubectl -n lens run -it --rm curl --image=curlimages/curl -- \
  curl -sS http://emitter-node-exporter:8080/metrics | head
```

---

### Step 2 — Add 4 Prometheus scrape jobs with file-based SD targets

Generate target files (e.g. `targets-node-exporter.json`) with N entries. Each entry points to the same Service but carries a unique `node_id` label. Relabel `node_id` → `instance` so Prometheus treats each as a distinct target.

Result: Prometheus performs 4N scrapes per interval and ingests unique series per virtual node.

---

### Step 3 — Run scenarios (ramp + optional soak)

Per scenario:
1. Set N by updating target files.
2. Wait until `count(up{job=~"lens-scale-test.*"}) == 4N`.
3. Run for the specified duration.
4. Record Prometheus self-metrics + scrape metrics.

---

## 2) Scenarios

All cases use ClusterIP (Prometheus scrapes inside cluster; no Ingress).

| Case | Nodes (N) | Targets (4N) | Interval | Timeout | Duration | Purpose |
|---|---|---|---|---|---|---|
| R0 | 10 | 40 | 60s | 10s | 10–15 min | Sanity baseline |
| R1 | 50 | 200 | 60s | 10s | 15–20 min | Early scaling |
| R2 | 100 | 400 | 60s | 10s | 20–30 min | Mid-scale pressure |
| R3 | 200 | 800 | 60s | 10s | 30–45 min | Near target scale |
| R4 | 250 | 1,000 | 60s | 10s | 30–45 min | Push ceiling |
| R5 | max stable N | 4N | 60s | 10s | 2–6 h | Soak / stability (optional) |

**Stop rule:** scrape success < 95% for 3 consecutive intervals, or Prometheus OOM/restart → record result and stop or ramp down.

---

## 3) Metrics to collect

### A) Scrape success / failure

| Metric | What it tells you |
|---|---|
| `up{job=~"lens-scale-test.*"}` | 1 = scrape succeeded, 0 = failed |
| `count(up{job=~"lens-scale-test.*"})` | Targets discovered (should equal 4N) |
| `count(up{job=~"lens-scale-test.*"} == 0)` | Targets currently failing |

### B) Scrape latency / timeouts

| Metric | What it tells you |
|---|---|
| `scrape_duration_seconds{job=~"lens-scale-test.*"}` | Time per scrape (seconds) |
| `scrape_timeout_seconds{job=~"lens-scale-test.*"}` | Configured timeout (should be 10s) |

If `scrape_duration_seconds` p95 approaches 10s → hitting timeout.

### C) Payload realism / sample volume

| Metric | What it tells you |
|---|---|
| `scrape_samples_scraped{job=~"lens-scale-test.*"}` | Samples per scrape; should match payload profile |
| `scrape_body_size_bytes{job=~"lens-scale-test.*"}` | Response size per scrape (if present; depends on Prometheus build) |

### D) Ingestion throughput

| Metric | What it tells you |
|---|---|
| `rate(prometheus_tsdb_head_samples_appended_total[5m])` | Samples/sec ingested into head block |
| `prometheus_tsdb_head_series` | Active series in memory (main memory driver) |

### E) Prometheus resource saturation

| Metric | What it tells you |
|---|---|
| `process_resident_memory_bytes{job="prometheus"}` | Memory usage → OOM risk |
| `rate(process_cpu_seconds_total{job="prometheus"}[5m])` | CPU cores used (1.0 = 1 full core) |

### F) Data correctness

| Metric | What it tells you |
|---|---|
| `rate(prometheus_tsdb_out_of_order_samples_total[5m])` | Should be ~0; spikes indicate scrape-loop delays |
