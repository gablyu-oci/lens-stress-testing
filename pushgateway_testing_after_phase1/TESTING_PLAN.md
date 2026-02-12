# Pushgateway Stress Test 2.0 — Testing Plan

## Overview

This folder contains stress tests for the **Pushgateway**. Only 4 components push to Pushgateway; the rest use Prometheus scrape.

## Components Under Test (4 push to Pushgateway only)

| Plugin | Metric Name | Pushes to Pushgateway | Job in Test |
|--------|-------------|-----------------------|-------------|
| DRHPC | oci_lens_drhpc_metrics | direct | ✅ |
| Active Healthcheck | oci_lens_healthchecks | direct (Job, parallelism 3) | ✅ |
| Go Plugin | oci_lens_node_metrics | direct | ✅ |
| Pod Node Mapper | oci_lens_pod_metrics | direct | ✅ |
| AMD GPU, DCGM, Node Exporter | — | Prometheus scrape | ❌ excluded |
| Node problem detector | — | Prometheus scrape | ❌ excluded |

## Job Model (per 60s cycle)

| Job | Category | Pushes/cycle | Scales with N? |
|-----|----------|--------------|----------------|
| oci_lens_drhpc_metrics | Node-level | N | ✅ |
| oci_lens_node_metrics | Node-level | N | ✅ |
| oci_lens_pod_metrics | Cluster-level | 1 | ❌ |
| oci_lens_healthchecks | Occasional | 3 | ❌ |

**Pushes per cycle:** `2×N + 4` (e.g. 1000 nodes → 2004 pushes/cycle)

## Scenario Matrix

### ClusterIP Ramp (C0–C7 + granular steps)
| ID | Nodes | Jitter | Duration |
|----|-------|--------|----------|
| C0 | 10 | 5s | 5 min |
| C20 | 20 | 10s | 5 min |
| C30 | 30 | 10s | 5 min |
| C50 | 50 | 15s | 10 min |
| C80 | 80 | 15s | 10 min |
| C1 | 100 | 20s | 10 min |
| C150 | 150 | 20s | 10 min |
| C200 | 200 | 20s | 10 min |
| C2 | 250 | 20s | 10 min |
| C300 | 300 | 20s | 15 min |
| C400 | 400 | 20s | 15 min |
| C3 | 500 | 20s | 15 min |
| C4 | 750 | 20s | 15 min |
| C5 | 1000 | 20s | 20 min |
| C6 | 1000 | 20s | 2h (soak) |
| C7 | 1000 | 0 | 20 min (spike) |

### Node-level Isolation (N1)
Node-level jobs only, no cluster/healthcheck.

### Pod Metrics Inflation (P1–P4)
Cluster-level only, pod payload inflated ×1, ×10, ×50, ×100.

## Endpoint

- **ClusterIP:** `http://10.96.242.191:9091` (Ingress scenarios excluded)

## How to Run

```bash
# Single scenario (attached)
./scripts/run_in_cluster.sh C0

# Single scenario (detached)
./scripts/run_in_cluster.sh C0 --detach

# Full suite (skip soak)
./scripts/run_in_cluster.sh --all --skip-soak

# Full suite (includes 2h soak)
./scripts/run_in_cluster.sh --all
```

## Metrics to Observe

- Push success rate, p50/p95/max latency per job
- Pushgateway CPU/memory, restarts, OOMKills
- `/metrics` response size and time
