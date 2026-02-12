# Pushgateway Stress Test 2.0 — Full Report

**Date:** 2026-02-12  
**Target:** Prometheus Pushgateway in `oci-gpu-scanner-plugin` namespace  
**Endpoint:** ClusterIP `http://10.96.242.191:9091`  
**Generator:** In-cluster pod (`pushgateway-stress-test`) using async Python (aiohttp)

---

## Executive Summary

The Pushgateway **handles the reduced 4-component workload well up to ~150 nodes**. With only DRHPC, Active Healthcheck, Go Plugin, and Pod Node Mapper pushing (2N+4 pushes per 60s cycle, ~43 KB per node), the success rate remains **100%** through 150 nodes. Beyond 200 nodes, the Pushgateway becomes saturated: success drops to ~30–40%, dominated by 30-second timeouts and connection errors.

| Scale (nodes) | Success Rate | p50 (ms) | Verdict |
|:---:|:---:|---:|---|
| 10–100 | **100%** | 8–183 | Healthy |
| 150 | **100%** | 7,389 | Healthy (high latency) |
| 200 | 41.8% | 30,147 | Degraded |
| 250 | 29.5% | 30,215 | Severe degradation |
| 300 | 26.9% | 30,293 | Unusable |
| 400 | 12.2% | 18,352 | Unusable |

**Key finding:** The 4-component architecture (excluding AMD GPU, DCGM, Node Exporter) reduces payload size per node from ~1.4 MB to ~43 KB. This extends the viable scale from ~10 nodes (original test) to **~150 nodes** before degradation. The Pushgateway remains a serialization bottleneck beyond that point.

---

## 1. Architecture Under Test

Only **4 components** push to Pushgateway; AMD GPU Exporter, DCGM Exporter, and Node Exporter use Prometheus scrape instead.

| Component | Job Name | Pushes/Cycle | Payload |
|-----------|----------|:---:|---|
| DRHPC | oci_lens_drhpc_metrics | N | 17 KB |
| Go Plugin | oci_lens_node_metrics | N | 26 KB |
| Pod Node Mapper | oci_lens_pod_metrics | 1 | 21 KB |
| Active Healthcheck | oci_lens_healthchecks | 3 | 37 KB |

**Pushes per 60s cycle:** 2×N + 4  
**Payload per cycle:** ~43 KB × N + ~132 KB

---

## 2. ClusterIP Ramp Tests (C0–C400)

Direct HTTP to the Pushgateway ClusterIP. No Ingress.

### Results Matrix

| Scenario | Nodes | Duration | Jitter | Pushes | Success Rate | p50 (ms) | p95 (ms) | Max (ms) | /metrics Size | Dominant Error |
|:---:|---:|---:|:---:|---:|:---:|---:|---:|---:|---:|---|
| **C0** | 10 | 4 min | 0–5s | 120 | **100.0%** | 7.8 | 11.3 | 16.2 | 0.76 MB (stable) | — |
| **C20** | 20 | 4 min | 0–10s | 220 | **100.0%** | 12.4 | 15.6 | 21.8 | 1.37 MB | — |
| **C30** | 30 | 4 min | 0–10s | 320 | **100.0%** | 17.4 | 24.6 | 36.8 | 1.97 MB | — |
| **C50** | 50 | 9 min | 0–15s | 1,040 | **100.0%** | 31.0 | 54.5 | 92.7 | 3.18 MB | — |
| **C80** | 80 | 9 min | 0–15s | 1,640 | **100.0%** | 71.0 | 219.5 | 417.1 | 5.00 MB | — |
| **C1** | 100 | 9 min | 0–20s | 2,040 | **100.0%** | 139.8 | 467.3 | 983.1 | 6.21 MB | — |
| **C150** | 150 | 10 min | 0–20s | 3,040 | **100.0%** | 7,389 | 16,321 | 18,254 | 9.24 MB | — |
| **C200** | 200 | 10 min | 0–20s | 4,040 | **41.8%** | 30,147 | 30,915 | 31,001 | 12.26 MB | timeout (58%) |
| **C2** | 250 | 10 min | 0–20s | 5,040 | **29.5%** | 30,215 | 30,927 | 42,184 | 14–15 MB | timeout (70%) |
| **C300** | 300 | 15 min | 0–20s | 9,060 | **26.9%** | 30,293 | 44,895 | 46,250 | 12–16 MB | timeout (70%) |
| **C400** | 400 | 15 min | 0–20s | 12,060 | **12.2%** | 18,352 | 48,809 | 50,200 | ERROR (cycle 10) | timeout (88%) |

### Analysis

- **C0–C150: All passing.** Success rate is 100% through 150 nodes. Latency grows from ~8 ms at 10 nodes to ~7.4 s at 150 nodes, but all pushes complete within the 30-second client timeout.

- **C150 is at the edge.** p50 latency reaches 7.4 s; p95 is 16.3 s. The Pushgateway is close to saturation but still processes every request.

- **C200–C400: Progressive collapse.** At 200 nodes, ~58% of pushes hit the 30-second timeout. At 250, 300, and 400 nodes, success rates fall to 30%, 27%, and 12% respectively. Failed requests cluster at ~30 s (client timeout). C400 shows additional "Cannot connect to host" and "Server disconnected" errors, suggesting the Pushgateway pod may restart or drop connections under load.

- **/metrics endpoint:** Remains reachable and stable in passing scenarios. At C400, cycle 10 returned ERROR (0.9 ms, status 0), indicating momentary unavailability; later cycles recovered.

---

## 3. Per-Job Breakdown (C1 vs C200)

### C1 (100 nodes, 100% success)

| Job | Total | OK | Fail | Rate | p50 (ms) | p95 (ms) |
|-----|------:|---:|---:|:---:|---:|---:|---:|
| oci_lens_drhpc_metrics | 1,000 | 1,000 | 0 | 100% | 141.6 | 486.8 |
| oci_lens_node_metrics | 1,000 | 1,000 | 0 | 100% | 139.2 | 443.0 |
| oci_lens_pod_metrics | 10 | 10 | 0 | 100% | 139.3 | 252.8 |
| oci_lens_healthchecks | 30 | 30 | 0 | 100% | 117.0 | 366.5 |

### C200 (200 nodes, 41.8% success)

| Job | Total | OK | Fail | Rate | p50 (ms) | Dominant Error |
|-----|------:|---:|---:|:---:|---:|---:|---|
| oci_lens_drhpc_metrics | 2,000 | 853 | 1,147 | 42.6% | 30,128 | timeout |
| oci_lens_node_metrics | 2,000 | 818 | 1,182 | 40.9% | 30,165 | timeout |
| oci_lens_pod_metrics | 10 | 6 | 4 | 60.0% | 24,899 | timeout |
| oci_lens_healthchecks | 30 | 12 | 18 | 40.0% | 30,169 | timeout |

All job types are affected similarly; no single job is disproportionately responsible for failures.

---

## 4. HTTP Status / Error Breakdown

| Scenario | 200 | timeout | Connect Error | Server Disconnect |
|:---:|---:|---:|---:|---:|
| C0–C150 | 100% | — | — | — |
| C200 | 1,689 (41.8%) | 2,351 (58.2%) | — | — |
| C2 | 1,485 (29.5%) | 3,514 (69.7%) | 41 (0.8%) | — |
| C300 | 2,435 (26.9%) | 6,344 (70.0%) | 248 (2.7%) | 33 (0.4%) |
| C400 | 1,467 (12.2%) | 10,308 (85.5%) | 285 (2.4%) | — |

---

## 5. Summary Table — All Completed Scenarios

| ID | Nodes | Duration | Pushes | OK | Fail | Rate | p50 (ms) | p95 (ms) | Max (ms) |
|:---:|---:|---:|---:|---:|---:|:---:|---:|---:|---:|
| C0 | 10 | 4 min | 120 | 120 | 0 | **100.0%** | 7.8 | 11.3 | 16.2 |
| C20 | 20 | 4 min | 220 | 220 | 0 | **100.0%** | 12.4 | 15.6 | 21.8 |
| C30 | 30 | 4 min | 320 | 320 | 0 | **100.0%** | 17.4 | 24.6 | 36.8 |
| C50 | 50 | 9 min | 1,040 | 1,040 | 0 | **100.0%** | 31.0 | 54.5 | 92.7 |
| C80 | 80 | 9 min | 1,640 | 1,640 | 0 | **100.0%** | 71.0 | 219.5 | 417.1 |
| C1 | 100 | 9 min | 2,040 | 2,040 | 0 | **100.0%** | 139.8 | 467.3 | 983.1 |
| C150 | 150 | 10 min | 3,040 | 3,040 | 0 | **100.0%** | 7,389 | 16,321 | 18,254 |
| C200 | 200 | 10 min | 4,040 | 1,689 | 2,351 | **41.8%** | 30,147 | 30,915 | 31,001 |
| C2 | 250 | 10 min | 5,040 | 1,485 | 3,555 | **29.5%** | 30,215 | 30,927 | 42,184 |
| C300 | 300 | 15 min | 9,060 | 2,435 | 6,625 | **26.9%** | 30,293 | 44,895 | 46,250 |
| C400 | 400 | 15 min | 12,060 | 1,467 | 10,593 | **12.2%** | 18,352 | 48,809 | 50,200 |

*C3, C4, C5, C7, N1, P1–P4 were not completed or not yet copied at report generation.*

---

## 6. Recommendations

### Immediate

1. **Operational limit: ~150 nodes.** With the 4-component Pushgateway architecture, keep clusters at or below ~150 nodes for reliable metric delivery. At 200+ nodes, expect significant timeout and failure rates.

2. **Monitor latency at 100–150 nodes.** C150 shows p50 ~7.4 s and p95 ~16 s. If latencies trend upward in production, consider scaling actions before reaching 200 nodes.

### Architectural

3. **Shard the Pushgateway** for clusters above 150 nodes. Deploy multiple instances (e.g., per zone or per N nodes) and have Prometheus scrape all of them to distribute write load.

4. **Evaluate Prometheus remote-write** for higher throughput if scale must grow beyond the Pushgateway’s capacity.

5. **Tune Pushgateway resources** (CPU, memory) if not already optimized. The serialization bottleneck may be partially alleviated by more CPU.

6. **Retain the 4-component split.** Keeping AMD GPU, DCGM, and Node Exporter on Prometheus scrape reduces Pushgateway load and extends its usable range from ~10 nodes (original 7-component test) to ~150 nodes.

---

## 7. Test Environment

- **Pushgateway ClusterIP:** `http://10.96.242.191:9091`
- **Generator:** Python 3.10, aiohttp, in-cluster `pushgateway-stress-test` pod
- **Connection pool:** 500 concurrent connections
- **Client timeout:** 30 seconds per push
- **Payloads:**
  - oci_lens_drhpc_metrics: 17 KB
  - oci_lens_node_metrics: 26 KB
  - oci_lens_pod_metrics: 21 KB
  - oci_lens_healthchecks: 37 KB
