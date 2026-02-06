## Testing Plan - Pushgateway
### Step 1 — Get one real payload
Run the real plugin on **one node** once and capture either:
- the file it pushes, or
- `/metrics` from Pushgateway right after the push

Compute:
- payload bytes
- number of sample lines (non-`#` lines)
- count of unique label sets (approx by counting lines)

### Step 2 — Build the mock generator to match that payload

Your generator should:
- produce the same **bytes per node** (or same number of sample lines)
- include labels you saw (at least node + gpu_uuid; optionally test name)
- keep UUIDs stable per “GPU” across pushes
- add jitter (and also test no-jitter)

### Step 3 — Sweep scale
Run:
- 16 nodes @30s
- 64 nodes @30s
- 128 nodes @30s  
    Measure Pushgateway:
	- CPU/mem
	- push latency and error rate
	- `/metrics` response size & time

### Test dimensions and fixed assumptions

| Dimension               | Values / Rules                                                                                                                                                                                              |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Endpoints               | **ClusterIP (HTTP):** `http://10.96.230.201:9091` • **Ingress (HTTPS/TLS):** `https://pushgateway.150.230.181.224.nip.io`                                                                                   |
| Interval                | Default **60s** (matches current system). Optional stress variant: **30s**                                                                                                                                  |
| Jitter                  | **ON** for realistic runs (spread pushes within window). **OFF** for spike tests                                                                                                                            |
| Concurrency             | Generator should use keep-alive + connection pooling; cap in-flight requests (e.g., 200–1000)                                                                                                               |
| Payloads                | Use **real captured per-job payloads** (exact bodies pre-push). Pushgateway adds job/instance via URL                                                                                                       |
| Node identity stability | `instance=` must be stable across cycles (no random instance per push)                                                                                                                                      |
| Job categories          | **Node-level (scales with N):** amd-gpu-exporter, node-exporter, oci_lens_node_metrics, oci_lens_drhpc_metrics • **Cluster-level (constant):** oci_lens_pod_metrics • **Occasional:** oci_lens_healthchecks |

### Job modeling
| Job name                 | Category                |    Pushes per interval | Scales with N? | URL instance pattern             | Payload file                               |
| ------------------------ | ----------------------- | ---------------------: | -------------- | -------------------------------- | ------------------------------------------ |
| `amd-gpu-exporter`       | Node-level              |    1 / node / interval | ✅ yes          | `instance=<node-ip>`             | `sample-amd-gpu-payload.txt` (767KB)       |
| `node-exporter`          | Node-level              |    1 / node / interval | ✅ yes          | `instance=<node-ip>`             | `sample-node-exporter-payload.txt` (570KB) |
| `oci_lens_node_metrics`  | Node-level              |    1 / node / interval | ✅ yes          | `instance=<node-name>`           | `payload-oci-lens-node.txt` (26KB)         |
| `oci_lens_drhpc_metrics` | Node-level (worst-case) |    1 / node / interval | ✅ yes          | `instance=<node-name>`           | `payload-oci-lens-drhpc.txt` (17KB)        |
| `oci_lens_pod_metrics`   | Cluster-level           | 1 / cluster / interval | ❌ no           | `instance=<pod-node-mapper-pod>` | `payload-oci-lens-pod.txt` (21KB)          |
| `oci_lens_healthchecks`  | Occasional              |            per job run | depends        | `instance=<node-name or run>`    | `payload-oci-lens-healthcheck.txt` (37KB)  |
### Metrics to observe
| Category                                         | What to measure                                            | How to collect                                                 | Why it matters / failure signal                                 |
| ------------------------------------------------ | ---------------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------- |
| Generator — availability                         | HTTP status counts (2xx/4xx/5xx), timeouts, connect errors | Generator logs/csv per minute per job                          | Shows overload, ingress limits, TLS issues                      |
| Generator — latency                              | p50/p95/max latency per job per endpoint                   | Generator logs/csv                                             | Latency drift suggests CPU/GC pressure or ingress saturation    |
| Pushgateway pod health                           | CPU, memory (RSS), restarts/OOMKills                       | `kubectl top pod`, `kubectl describe pod`                      | Memory growth without plateau = too many groups/series or churn |
| Ingress controller health (when testing ingress) | CPU/mem, error logs (413, 502/504), resets                 | `kubectl top`, ingress logs                                    | Isolates bottleneck to ingress/TLS instead of Pushgateway       |
| `/metrics` endpoint “scrape proxy”               | response size (bytes), response time                       | `curl -w "bytes=%{size_download} time=%{time_total}"` once/min | If this explodes, Prometheus scraping will likely fail later    |
| Pushgateway internal symptoms                    | log errors, slow requests                                  | Pushgateway logs                                               | Helps attribute failures (parse issues, timeouts)               |
### Core scenario matrix (ClusterIP vs Ingress)
http://10.96.230.201:9091/
https://pushgateway.150.230.181.224.nip.io/

| Scenario ID | Endpoint      | Node count N | Jobs included              | Jitter     | Interval |           Duration | Purpose                                     |
| ----------- | ------------- | -----------: | -------------------------- | ---------- | -------: | -----------------: | ------------------------------------------- |
| C0          | ClusterIP     |           10 | Node-level + cluster-level | ON (0–5s)  |      60s |              5 min | Sanity: correctness, URLs, payload validity |
| C1          | ClusterIP     |          100 | Node-level + cluster-level | ON (0–20s) |      60s |             10 min | Early baseline, resource profile            |
| C2          | ClusterIP     |          250 | Node-level + cluster-level | ON (0–20s) |      60s |             10 min | Ramp step                                   |
| C3          | ClusterIP     |          500 | Node-level + cluster-level | ON (0–20s) |      60s |             15 min | Ramp step                                   |
| C4          | ClusterIP     |          750 | Node-level + cluster-level | ON (0–20s) |      60s |             15 min | Ramp step                                   |
| C5          | ClusterIP     |         1000 | Node-level + cluster-level | ON (0–20s) |      60s |             20 min | Target ramp: confirm stability at 1000      |
| C6          | ClusterIP     |         1000 | Node-level + cluster-level | ON (0–20s) |      60s |          2–6 hours | Soak: detect slow degradation/memory drift  |
| C7          | ClusterIP     |         1000 | Node-level + cluster-level | **OFF**    |      60s |          15–20 min | Spike: worst-case thundering herd           |
| Scenario ID | Endpoint      | Node count N | Jobs included              | Jitter     | Interval |           Duration | Purpose                                     |
| I0          | Ingress HTTPS |           10 | Node-level + cluster-level | ON (0–5s)  |      60s |              5 min | Sanity: TLS/cert, endpoint reachability     |
| I1          | Ingress HTTPS |          100 | Node-level + cluster-level | ON (0–20s) |      60s |             10 min | Baseline over TLS                           |
| I2          | Ingress HTTPS |          250 | Node-level + cluster-level | ON (0–20s) |      60s |             10 min | Ramp step                                   |
| I3          | Ingress HTTPS |          500 | Node-level + cluster-level | ON (0–20s) |      60s |             15 min | Ramp step                                   |
| I4          | Ingress HTTPS |          750 | Node-level + cluster-level | ON (0–20s) |      60s |             15 min | Ramp step                                   |
| I5          | Ingress HTTPS |         1000 | Node-level + cluster-level | ON (0–20s) |      60s |             20 min | Target ramp over TLS                        |
| I6          | Ingress HTTPS |         1000 | Node-level + cluster-level | ON (0–20s) |      60s | 2 hours (optional) | Soak over TLS if ramp looks healthy         |
| I7          | Ingress HTTPS |         1000 | Node-level + cluster-level | **OFF**    |      60s |          15–20 min | Spike over TLS (likely ingress-sensitive)   |
### Node-level vs Cluster-level isolation scenarios
#### Node level only (dominant write load)
|Scenario ID|Endpoint|N|Jobs included|Jitter|Interval|Duration|Purpose|
|---|---|--:|---|---|--:|--:|---|
|N1|ClusterIP|1000|amd-gpu-exporter, node-exporter, lens-node, drhpc|ON|60s|20 min|Isolate write-path load without pod-metrics|
|N2|Ingress HTTPS|1000|amd-gpu-exporter, node-exporter, lens-node, drhpc|ON|60s|20 min|Same isolation but with TLS/ingress|

#### Cluster level only (dominant series count//metrics growth)
| Scenario ID | Endpoint  |          N | Jobs included                          | Jitter | Interval | Duration | Purpose                                         |
| ----------- | --------- | ---------: | -------------------------------------- | ------ | -------: | -------: | ----------------------------------------------- |
| P1          | ClusterIP | 0 (ignore) | oci_lens_pod_metrics only              | ON     |      60s |   30 min | Baseline cluster-level impact                   |
| P2          | ClusterIP |          0 | oci_lens_pod_metrics **inflated ×10**  | ON     |      60s |   30 min | Simulate larger cluster pod count               |
| P3          | ClusterIP |          0 | oci_lens_pod_metrics **inflated ×50**  | ON     |      60s |   30 min | Stress payload size & cardinality               |
| P4          | ClusterIP |          0 | oci_lens_pod_metrics **inflated ×100** | ON     |      60s |   30 min | Find failure threshold for `/metrics` size/time |
### What to report back (deliverables)

For each scenario, produce:
1. **A per-job table**: success rate, p95 latency, max latency
2. Pushgateway **CPU/mem trend** (start/end + any spikes)
3. `/metrics` **bytes + time trend** (start/end + any spikes)
4. Any **restarts/OOM** and key log errors

### Suggested default durations
- **Ramp steps:** 10–20 min each (enough to stabilize)
- **Soak:** **2–6 hours** is strong evidence
- **24 hours** only if:
    - customer explicitly requires it, or
    - you see borderline drift and need confirmation
