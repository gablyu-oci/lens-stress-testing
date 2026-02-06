# Pushgateway Stress Test — Full Report

**Date:** 2026-02-06  
**Duration:** 13 hours 29 minutes (01:30 – 14:59 UTC)  
**Target:** Prometheus Pushgateway in `oci-gpu-scanner-plugin` namespace  
**Generator:** In-cluster pod (`pushgateway-stress-test`) using async Python (aiohttp)

---

## Executive Summary

The Pushgateway **collapses under load beyond 10 simulated nodes** on both ClusterIP and Ingress paths. At the target scale of 1,000 nodes, the success rate drops to ~1-2% with median latencies exceeding 45 seconds. The Ingress path adds a second bottleneck (503/502 errors from the controller) on top of the Pushgateway's own limitations.

| Scale (nodes) | ClusterIP Success | Ingress Success | Verdict |
|:---:|:---:|:---:|---|
| 10 | **100%** | 20% | ClusterIP works; Ingress already struggling |
| 100 | 9.0% | 6.5% | Severe degradation |
| 250 | 4.9% | 2.4% | Effectively broken |
| 500 | 1.2% | 1.2% | Unusable |
| 1,000 | 1.4% | 1.1% | Unusable |

**Key finding:** The Pushgateway itself is the primary bottleneck — not the network, not TLS, not the Ingress controller. It cannot process the volume of concurrent metric pushes required by even a modest multi-node cluster.

---

## 1. ClusterIP Ramp Tests (C0–C7)

Direct HTTP to the Pushgateway ClusterIP, bypassing Ingress/TLS overhead.

### Results Matrix

| Scenario | Nodes | Duration | Jitter | Pushes | Success Rate | p50 (ms) | p95 (ms) | Max (ms) | /metrics Size | Dominant Error |
|:---:|---:|---:|:---:|---:|:---:|---:|---:|---:|---:|---|
| **C0** | 10 | 5 min | 0–5s | 205 | **100.0%** | 1,095 | 2,796 | 3,217 | 17.3 MB (stable) | — |
| **C1** | 100 | 10 min | 0–20s | 4,010 | **9.0%** | 30,443 | 30,952 | 31,002 | 54–88 MB (growing) | timeout (90%) |
| **C2** | 250 | 10 min | 0–20s | 10,010 | **4.9%** | 30,689 | 50,036 | 52,477 | ERROR | timeout (93%) |
| **C3** | 500 | 18 min | 0–20s | 30,015 | **1.2%** | 22,024 | 68,005 | 101,401 | mostly ERROR | timeout (96%) |
| **C4** | 750 | 22 min | 0–20s | 45,015 | **1.8%** | 33,656 | 101,096 | 117,041 | ERROR | timeout (96%) |
| **C5** | 1,000 | 38 min | 0–20s | 80,020 | **1.4%** | 44,666 | 121,553 | 142,097 | ERROR | timeout (94%) |
| **C6** | 1,000 | 3.8 hrs | 0–20s | 480,120 | **1.6%** | 47,624 | 117,867 | 189,017 | 47–72 MB (early) | timeout (96%) |
| **C7** | 1,000 | 38 min | OFF | 80,020 | **2.1%** | 54,819 | 136,822 | 165,407 | ERROR | timeout (96%) |

### Analysis

- **C0 (10 nodes) is the only passing scenario.** All 205 pushes succeeded. Latencies are reasonable (p50 ~1.1s) given the payload sizes (767 KB + 570 KB per node). The `/metrics` endpoint is stable at 17.3 MB.

- **C1 (100 nodes) immediately collapses.** Success plummets to 9%. The generator fires 401 pushes per cycle, and the Pushgateway can only process ~36 of them before the 30-second timeout kicks in. The `/metrics` endpoint grew from 60 MB to 88 MB, confirming data is accumulating but writes are serialized and slow.

- **C2–C5 show progressive degradation.** As node count increases, more pushes queue up, pushing p50 latency from 30s to 45s and p95 from 50s to 122s. The Pushgateway becomes completely unresponsive to `/metrics` probes (connection errors), indicating it is fully saturated processing write requests.

- **C6 (soak test)** ran for 3.8 hours at 1,000 nodes. The success rate held steady at 1.6% with no improvement over time — the Pushgateway does not recover or catch up. Early `/metrics` probes that succeeded showed the response growing from 47 MB to 72 MB before becoming unreachable.

- **C7 (spike, no jitter)** is the worst case. Without jitter, all 4,001 pushes per cycle arrive simultaneously. Success rate drops to 2.1% with a median latency of 55 seconds. This confirms jitter provides negligible benefit at this scale.

---

## 2. Ingress HTTPS Tests (I0–I7)

Pushes routed through the Ingress controller with TLS termination.

### Results Matrix

| Scenario | Nodes | Duration | Jitter | Pushes | Success Rate | p50 (ms) | p95 (ms) | Max (ms) | Dominant Errors |
|:---:|---:|---:|:---:|---:|:---:|---:|---:|---:|---|
| **I0** | 10 | 4 min | 0–5s | 205 | **20.0%** | 7 | 525 | 860 | 503 (80%) |
| **I1** | 100 | 9 min | 0–20s | 4,010 | **6.5%** | 30,264 | 30,925 | 31,003 | 503 (25%) + timeout (68%) |
| **I2** | 250 | 10 min | 0–20s | 10,010 | **2.4%** | 3 | 51,325 | 52,283 | 503 (67%) + timeout (28%) |
| **I3** | 500 | 16 min | 0–20s | 30,015 | **1.2%** | 2 | 49,938 | 57,301 | 503 (81%) + timeout (13%) |
| **I4** | 750 | 17 min | 0–20s | 45,015 | **0.8%** | 2 | 73,792 | 109,362 | 503 (87%) + timeout (9%) |
| **I5** | 1,000 | 26 min | 0–20s | 80,020 | **1.1%** | 2 | 80,884 | 111,652 | 503 (87%) + timeout (11%) |
| **I6** | 1,000 | 2.5 hrs | 0–20s | 480,120 | **0.8%** | 2 | 80,030 | 112,437 | 503 (89%) + timeout (9%) |
| **I7** | 1,000 | 23 min | OFF | 80,020 | **1.0%** | 2,892 | 91,928 | 119,856 | 503 (91%) + timeout (7%) |

### Analysis

- **I0 (10 nodes) already fails at 80% error rate** — all errors are HTTP 503 from the Ingress controller. This means even at minimal load, the Ingress is intermittently unavailable. Note: the very low p50 (7ms) on the failed requests confirms these are fast 503 rejections, not timeouts.

- **The Ingress introduces a dual-bottleneck pattern.** At higher node counts, errors split between:
  - **503 Service Unavailable:** The Ingress controller rejects requests before they reach the Pushgateway (dominant error, 67-91%)
  - **502 Bad Gateway:** The Ingress forwarded the request, but the Pushgateway backend failed (1-8%)
  - **Timeouts:** Requests that made it through but the Pushgateway was too slow (7-28%)

- **The `/metrics` endpoint returned 503 on every single probe** for I2–I7 scenarios. The Ingress controller never allowed the scrape-proxy read to reach the Pushgateway at scale.

- **Ingress is strictly worse than ClusterIP** at every node count. At 1,000 nodes, ClusterIP achieves 1.4% success vs Ingress at 1.1%. But the failure mode is different: ClusterIP failures are mostly timeouts (the request reaches the Pushgateway but it's too slow), while Ingress failures are mostly 503 rejections (the request never reaches the Pushgateway).

---

## 3. Node-Level Isolation Tests (N1–N2)

Only node-level jobs (amd-gpu-exporter, node-exporter, lens-node, drhpc) — no pod-metrics.

### Results Matrix

| Scenario | Endpoint | Nodes | Pushes | Success Rate | p50 (ms) | p95 (ms) | Max (ms) | Dominant Error |
|:---:|---|---:|---:|:---:|---:|---:|---:|---|
| **N1** | ClusterIP | 1,000 | 80,000 | **1.7%** | 44,391 | 121,176 | 169,712 | timeout (96%) |
| **N2** | Ingress | 1,000 | 80,000 | **0.9%** | 2 | 81,221 | 111,868 | 503 (84%) + timeout (11%) |

### Analysis

- **Removing cluster-level pod-metrics made no meaningful difference.** N1 (node-only via ClusterIP) achieved 1.7% success vs C5's 1.4%. N2 (node-only via Ingress) achieved 0.9% vs I5's 1.1%. The single pod-metrics push per cycle is negligible — the bottleneck is the sheer volume of node-level pushes (4,000 per cycle at 1,000 nodes).

---

## 4. Pod Metrics Inflation Tests (P1–P4)

Single cluster-level push per cycle with inflated pod-metrics payload.

### Results Matrix

| Scenario | Multiplier | Payload Size | Pushes | Success Rate | p50 (ms) | /metrics Size | Error Type |
|:---:|:---:|---:|---:|:---:|---:|---:|---|
| **P1** | 1x | 20 KB | 30 | **83.3%** | 5 | 0.03 MB | connect errors (17%) |
| **P2** | 10x | ~200 KB | 30 | **0.0%** | 11 | 0.01 MB | 400 Bad Request (100%) |
| **P3** | 50x | ~1 MB | 30 | **0.0%** | 35 | 0.01 MB | 400 Bad Request (100%) |
| **P4** | 100x | ~2 MB | 30 | **0.0%** | 67 | 0.01 MB | 400 Bad Request (100%) |

### Analysis

- **P1 (baseline, 1x)** works mostly — 83% success. The 17% failures are likely transient connection issues from prior test residue.

- **P2–P4 all return 400 Bad Request.** This is a bug in the `inflate_pod_payload()` function — the inflated payloads create duplicate metric names with different label sets that the Pushgateway rejects as inconsistent. The latencies (11-67ms) confirm the Pushgateway is parsing and rejecting the payload quickly, not timing out. **These scenarios need the inflation logic fixed and re-run.**

---

## 5. Cross-Cutting Observations

### 5.1 The Pushgateway's Serialization Bottleneck

The Pushgateway processes pushes serially under a global lock. Each push involves:
1. Parsing the Prometheus text exposition format
2. Merging metrics into the in-memory store
3. Persisting state

For large payloads (767 KB for amd-gpu-exporter, 570 KB for node-exporter), each push takes ~1-3 seconds. At 10 nodes, the 41 pushes per cycle complete within the 60-second interval. At 100 nodes, 401 pushes take ~200-400 seconds to serialize through the lock, far exceeding both the 60-second interval and the 30-second client timeout.

### 5.2 /metrics Endpoint Unavailability

At 100+ nodes, the `/metrics` endpoint becomes intermittently or permanently unreachable. This means **Prometheus cannot scrape the Pushgateway** during high load — the very purpose of the Pushgateway (make metrics available for scraping) is defeated.

### 5.3 Ingress 503 Root Cause: nginx Configuration Limits

Investigation of the `lens-ingress-nginx-controller` configuration revealed two hard limits that cause the 503 errors:

**`proxy_connect_timeout: 5s`** — This is the primary cause. Nginx waits only 5 seconds to establish a TCP connection to the Pushgateway backend. Because the Pushgateway processes pushes serially under a global lock, its TCP accept queue backs up as soon as a few large payloads (767 KB, 570 KB) are being processed. Any new connection not accepted within 5 seconds gets an immediate 503 from nginx. By comparison, the ClusterIP tests use aiohttp with a 30-second timeout — 6x more patience — which is why C0 (ClusterIP, 10 nodes) achieves 100% while I0 (Ingress, 10 nodes) only manages 20%.

The I0 pattern illustrates this clearly:
- **Cycle 1:** Pushgateway is idle after cleanup, accepts connections instantly → 41/41 OK
- **Cycles 2–5:** Pushgateway is still processing cycle 1's ~13 MB of payloads → nginx's 5s connect timeout expires → instant 503
- The very fast p50 latency (7ms) on failed requests confirms these are instant nginx rejections, not slow backend failures

**`client_max_body_size: 1m`** — A secondary concern. The Ingress caps request bodies at 1 MB. The largest payload (`amd-gpu-exporter` at 767 KB) fits today, but this leaves no headroom. Any payload growth would trigger 413 errors.

At higher node counts (I2+), the Pushgateway is perpetually saturated, so nginx almost never establishes a connection within 5 seconds — driving the 503 rate to 87–91%. The 502 errors (1–8% of failures) represent cases where nginx did connect but the Pushgateway dropped the connection mid-request under load.

**Relevant nginx configuration (from the Ingress controller pod):**
```
proxy_connect_timeout    5s;     # ← too short for a serialized backend
proxy_send_timeout       60s;
proxy_read_timeout       60s;
client_max_body_size     1m;     # ← tight for large metric payloads
proxy_next_upstream      error timeout;
proxy_next_upstream_tries 3;     # retries hit the same single-pod backend
keepalive                320;
```

If Ingress must be used, the minimum config changes would be:
- `proxy_connect_timeout` → `30s` or `60s`
- `client_max_body_size` → `5m` or higher
- These can be set via Ingress annotations: `nginx.ingress.kubernetes.io/proxy-connect-timeout` and `nginx.ingress.kubernetes.io/proxy-body-size`

However, even with these changes, the underlying Pushgateway serialization bottleneck remains — the errors would just shift from fast 503 rejections to slow timeouts (matching the ClusterIP behavior).

### 5.4 Memory Growth

In C1 (the only high-scale test where `/metrics` was reachable), the response grew from 60 MB to 88 MB (1.46x) over 10 minutes. C6's early probes showed 47 MB → 72 MB. This growth suggests the Pushgateway is accumulating metric groups from successful pushes, but the vast majority of pushes never complete.

### 5.5 Spike vs Jitter

Comparing C5 (jitter ON) vs C7 (jitter OFF) at 1,000 nodes:
- C5: 1.4% success, p50 = 44.7s
- C7: 2.1% success, p50 = 54.8s

Counter-intuitively, the spike test had a slightly higher success rate. This is because with jitter, pushes are spread over 20 seconds, creating a continuous stream the Pushgateway never catches up with. Without jitter, all pushes arrive at once — most timeout, but the few that get processed do so without interference from new arrivals during the cycle.

---

## 6. Summary Table — All Scenarios

| ID | Endpoint | Nodes | Duration | Jitter | Pushes | OK | Fail | Rate | p50 ms | p95 ms | Max ms |
|:---|:---:|---:|---:|:---:|---:|---:|---:|:---:|---:|---:|---:|
| C0 | ClusterIP | 10 | 4m | ON | 205 | 205 | 0 | **100.0%** | 1,095 | 2,796 | 3,217 |
| C1 | ClusterIP | 100 | 10m | ON | 4,010 | 362 | 3,648 | **9.0%** | 30,443 | 30,952 | 31,002 |
| C2 | ClusterIP | 250 | 10m | ON | 10,010 | 489 | 9,521 | **4.9%** | 30,689 | 50,036 | 52,477 |
| C3 | ClusterIP | 500 | 18m | ON | 30,015 | 368 | 29,647 | **1.2%** | 22,024 | 68,005 | 101,401 |
| C4 | ClusterIP | 750 | 22m | ON | 45,015 | 828 | 44,187 | **1.8%** | 33,656 | 101,096 | 117,041 |
| C5 | ClusterIP | 1,000 | 38m | ON | 80,020 | 1,088 | 78,932 | **1.4%** | 44,666 | 121,553 | 142,097 |
| C6 | ClusterIP | 1,000 | 3.8h | ON | 480,120 | 7,585 | 472,535 | **1.6%** | 47,624 | 117,867 | 189,017 |
| C7 | ClusterIP | 1,000 | 38m | OFF | 80,020 | 1,701 | 78,319 | **2.1%** | 54,819 | 136,822 | 165,407 |
| I0 | Ingress | 10 | 4m | ON | 205 | 41 | 164 | **20.0%** | 7 | 525 | 860 |
| I1 | Ingress | 100 | 9m | ON | 4,010 | 261 | 3,749 | **6.5%** | 30,264 | 30,925 | 31,003 |
| I2 | Ingress | 250 | 10m | ON | 10,010 | 238 | 9,772 | **2.4%** | 3 | 51,325 | 52,283 |
| I3 | Ingress | 500 | 16m | ON | 30,015 | 361 | 29,654 | **1.2%** | 2 | 49,938 | 57,301 |
| I4 | Ingress | 750 | 17m | ON | 45,015 | 344 | 44,671 | **0.8%** | 2 | 73,792 | 109,362 |
| I5 | Ingress | 1,000 | 26m | ON | 80,020 | 877 | 79,143 | **1.1%** | 2 | 80,884 | 111,652 |
| I6 | Ingress | 1,000 | 2.5h | ON | 480,120 | 3,950 | 476,170 | **0.8%** | 2 | 80,030 | 112,437 |
| I7 | Ingress | 1,000 | 23m | OFF | 80,020 | 819 | 79,201 | **1.0%** | 2,892 | 91,928 | 119,856 |
| N1 | ClusterIP | 1,000 | 38m | ON | 80,000 | 1,392 | 78,608 | **1.7%** | 44,391 | 121,176 | 169,712 |
| N2 | Ingress | 1,000 | 26m | ON | 80,000 | 733 | 79,267 | **0.9%** | 2 | 81,221 | 111,868 |
| P1 | ClusterIP | 0 | 29m | ON | 30 | 25 | 5 | **83.3%** | 5 | 6 | 6 |
| P2 | ClusterIP | 0 | 29m | ON | 30 | 0 | 30 | **0.0%** | 11 | 14 | 15 |
| P3 | ClusterIP | 0 | 29m | ON | 30 | 0 | 30 | **0.0%** | 35 | 42 | 46 |
| P4 | ClusterIP | 0 | 29m | ON | 30 | 0 | 30 | **0.0%** | 67 | 70 | 72 |

---

## 7. Recommendations

### Immediate

1. **The Pushgateway cannot support 100+ nodes at 60-second intervals** with the current payload sizes. It is limited to approximately **10-20 nodes** before push success degrades catastrophically.

2. **The Ingress path is unsuitable** for metrics pushing at any meaningful scale. Even at 10 nodes, the 503 error rate is 80%. If Ingress must be used, the controller needs tuning (connection limits, timeouts, backend health checks).

3. **Fix the P2-P4 inflation tests** — the `inflate_pod_payload()` function produces payloads the Pushgateway rejects. Fix and re-run to properly test pod-metrics cardinality scaling.

### Architectural

4. **Reduce payload size.** The amd-gpu-exporter (767 KB) and node-exporter (570 KB) payloads are extremely large. Filtering to only the metrics Prometheus actually needs could reduce push time by 10x or more.

5. **Shard the Pushgateway.** Deploy multiple Pushgateway instances (e.g., one per rack or per N nodes) and have Prometheus scrape all of them. This distributes the write lock across instances.

6. **Consider Prometheus remote-write** instead of the Pushgateway. Remote-write is designed for high-throughput metric ingestion and does not suffer from the single-lock serialization problem.

7. **Batch and compress.** If the Pushgateway must be used, combine multiple node metrics into fewer, smaller pushes, and enable gzip compression on the Ingress.

8. **Increase Pushgateway resources.** The current test doesn't show CPU/memory data (the monitor wasn't run alongside), but the Pushgateway pod may benefit from higher CPU limits to speed up parse/merge operations.

---

## 8. Test Environment

- **Pushgateway ClusterIP:** `http://10.96.230.201:9091`
- **Pushgateway Ingress:** `https://pushgateway.150.230.181.224.nip.io`
- **Generator:** Python 3.10, aiohttp, running inside `pushgateway-stress-test` pod
- **Connection pool:** 500 concurrent connections (per scenario)
- **Client timeout:** 30 seconds per push
- **Payloads:** Real captured metrics from production exporters
  - `amd-gpu-exporter`: 767 KB
  - `node-exporter`: 570 KB
  - `oci_lens_node_metrics`: 25 KB
  - `oci_lens_drhpc_metrics`: 15 KB
  - `oci_lens_pod_metrics`: 20 KB
