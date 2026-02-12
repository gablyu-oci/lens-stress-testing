#!/usr/bin/env python3
"""
Pushgateway Stress Test 2.0 Generator

Simulates N nodes pushing metrics to the pushgateway.
Only 4 components push to Pushgateway: DRHPC, Active Healthcheck, Go Plugin, Pod Node Mapper.
(AMD GPU, DCGM, Node Exporter use Prometheus scrape — excluded.)

Uses async I/O with connection pooling and concurrency limits.
"""

import aiohttp
import asyncio
import argparse
import csv
import math
import os
import random
import signal
import ssl
import statistics
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ─── Constants ───────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent
PAYLOADS_DIR = PROJECT_DIR / "payloads"
RESULTS_DIR = PROJECT_DIR / "results"

CLUSTERIP_ENDPOINT = "http://10.96.242.191:9091"

# ─── Job Definitions (4 Pushgateway Components Only) ────
# DRHPC, Active Healthcheck, Go Plugin, Pod Node Mapper
# (AMD GPU, DCGM, Node Exporter use Prometheus scrape — excluded)

NODE_LEVEL_JOBS = [
    {"name": "oci_lens_drhpc_metrics", "file": "payload-oci-lens-drhpc.txt", "instance_type": "node-name"},
    {"name": "oci_lens_node_metrics", "file": "payload-oci-lens-node.txt", "instance_type": "node-name"},
]

CLUSTER_LEVEL_JOBS = [
    {"name": "oci_lens_pod_metrics", "file": "payload-oci-lens-pod.txt", "instance_type": "pod-name"},
]

HEALTHCHECK_JOBS = [
    {"name": "oci_lens_healthchecks", "file": "payload-oci-lens-healthcheck.txt", "instance_type": "node-name", "replicas": 3},
]


# ─── Stable Node Identity Generation ────────────────────────────────────────

def generate_node_identities(n: int) -> list[dict]:
    """Generate N stable simulated node identities."""
    nodes = []
    for i in range(n):
        subnet = 10 + (i // 254)
        host = 1 + (i % 254)
        nodes.append({
            "node_ip": f"10.0.{subnet}.{host}",
            "node_name": f"stress-node-{i:04d}",
        })
    return nodes


# ─── Payload Loading ────────────────────────────────────────────────────────

def load_payloads(jobs: list[dict]) -> dict[str, bytes]:
    """Load payload files into memory as bytes."""
    payloads = {}
    for job in jobs:
        path = PAYLOADS_DIR / job["file"]
        if not path.exists():
            print(f"ERROR: Payload file not found: {path}", file=sys.stderr)
            sys.exit(1)
        payloads[job["name"]] = path.read_bytes()
        size_kb = len(payloads[job["name"]]) / 1024
        print(f"  Loaded {job['name']}: {path.name} ({size_kb:.1f} KB)")
    return payloads


def inflate_pod_payload(payload: bytes, multiplier: int) -> bytes:
    """Inflate pod metrics payload by replicating lines with unique pod names."""
    lines = payload.decode("utf-8").strip().split("\n")
    inflated = []
    for m in range(multiplier):
        for line in lines:
            if line.startswith("#") or not line.strip():
                if m == 0:
                    inflated.append(line)
                continue
            new_line = line.replace(
                'namespace="oci-gpu-scanner-plugin"',
                f'namespace="ns-batch-{m:03d}"',
            )
            new_line = new_line.replace('pod="', f'pod="inflated-{m:03d}-')
            inflated.append(new_line)
    return "\n".join(inflated).encode("utf-8")


# ─── Results Tracking ───────────────────────────────────────────────────────

@dataclass
class PushResult:
    timestamp: float
    cycle: int
    job: str
    instance: str
    status_code: int
    latency_ms: float
    payload_bytes: int
    error: str = ""


@dataclass
class MetricsProbeResult:
    timestamp: float
    cycle: int
    response_bytes: int
    response_time_ms: float
    status_code: int
    error: str = ""


# ─── Core Push Logic ────────────────────────────────────────────────────────

async def push_single(
    session: aiohttp.ClientSession,
    semaphore: asyncio.Semaphore,
    endpoint: str,
    job_name: str,
    instance: str,
    payload: bytes,
    cycle: int,
) -> PushResult:
    """Push a single payload to the pushgateway."""
    url = f"{endpoint}/metrics/job/{job_name}/instance/{instance}"
    start = time.monotonic()
    try:
        async with semaphore:
            async with session.post(
                url,
                data=payload,
                timeout=aiohttp.ClientTimeout(total=30, connect=10),
            ) as resp:
                latency = (time.monotonic() - start) * 1000
                await resp.read()
                return PushResult(
                    timestamp=time.time(),
                    cycle=cycle,
                    job=job_name,
                    instance=instance,
                    status_code=resp.status,
                    latency_ms=round(latency, 2),
                    payload_bytes=len(payload),
                )
    except asyncio.TimeoutError:
        latency = (time.monotonic() - start) * 1000
        return PushResult(
            timestamp=time.time(), cycle=cycle, job=job_name, instance=instance,
            status_code=0, latency_ms=round(latency, 2), payload_bytes=len(payload),
            error="timeout",
        )
    except aiohttp.ClientError as e:
        latency = (time.monotonic() - start) * 1000
        return PushResult(
            timestamp=time.time(), cycle=cycle, job=job_name, instance=instance,
            status_code=0, latency_ms=round(latency, 2), payload_bytes=len(payload),
            error=str(e)[:120],
        )
    except Exception as e:
        latency = (time.monotonic() - start) * 1000
        return PushResult(
            timestamp=time.time(), cycle=cycle, job=job_name, instance=instance,
            status_code=0, latency_ms=round(latency, 2), payload_bytes=len(payload),
            error=f"unexpected: {str(e)[:100]}",
        )


async def push_with_jitter(
    session: aiohttp.ClientSession,
    semaphore: asyncio.Semaphore,
    endpoint: str,
    job_name: str,
    instance: str,
    payload: bytes,
    cycle: int,
    jitter_max: float,
) -> PushResult:
    """Push with optional random jitter delay."""
    if jitter_max > 0:
        await asyncio.sleep(random.uniform(0, jitter_max))
    return await push_single(
        session, semaphore, endpoint, job_name, instance, payload, cycle
    )


# ─── Metrics Endpoint Probe ─────────────────────────────────────────────────

async def probe_metrics_endpoint(
    session: aiohttp.ClientSession,
    endpoint: str,
    cycle: int,
) -> MetricsProbeResult:
    """Probe the /metrics endpoint for size and response time."""
    url = f"{endpoint}/metrics"
    start = time.monotonic()
    try:
        async with session.get(
            url, timeout=aiohttp.ClientTimeout(total=60, connect=10)
        ) as resp:
            body = await resp.read()
            latency = (time.monotonic() - start) * 1000
            return MetricsProbeResult(
                timestamp=time.time(),
                cycle=cycle,
                response_bytes=len(body),
                response_time_ms=round(latency, 2),
                status_code=resp.status,
            )
    except Exception as e:
        latency = (time.monotonic() - start) * 1000
        return MetricsProbeResult(
            timestamp=time.time(),
            cycle=cycle,
            response_bytes=0,
            response_time_ms=round(latency, 2),
            status_code=0,
            error=str(e)[:120],
        )


# ─── Cycle Execution ────────────────────────────────────────────────────────

async def run_cycle(
    session: aiohttp.ClientSession,
    semaphore: asyncio.Semaphore,
    endpoint: str,
    nodes: list[dict],
    node_jobs: list[dict],
    cluster_jobs: list[dict],
    healthcheck_jobs: list[dict],
    payloads: dict[str, bytes],
    cycle: int,
    jitter_max: float,
) -> list[PushResult]:
    """Execute all pushes for a single cycle."""
    tasks = []

    for node in nodes:
        for job in node_jobs:
            if job["instance_type"] == "node-ip":
                instance = node["node_ip"]
            else:
                instance = node["node_name"]
            tasks.append(
                push_with_jitter(
                    session, semaphore, endpoint,
                    job["name"], instance, payloads[job["name"]],
                    cycle, jitter_max,
                )
            )

    for job in cluster_jobs:
        instance = "pod-node-mapper-stress-test"
        tasks.append(
            push_with_jitter(
                session, semaphore, endpoint,
                job["name"], instance, payloads[job["name"]],
                cycle, jitter_max,
            )
        )

    for job in healthcheck_jobs:
        replicas = job.get("replicas", 1)
        for r in range(replicas):
            instance = nodes[r % len(nodes)]["node_name"] if nodes else f"healthcheck-pod-{r}"
            tasks.append(
                push_with_jitter(
                    session, semaphore, endpoint,
                    job["name"], instance, payloads[job["name"]],
                    cycle, jitter_max,
                )
            )

    results = await asyncio.gather(*tasks)
    return list(results)


# ─── Summary & Reporting ────────────────────────────────────────────────────

def compute_percentile(data: list[float], p: float) -> float:
    if not data:
        return 0.0
    sorted_data = sorted(data)
    k = (len(sorted_data) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_data[int(k)]
    return sorted_data[f] * (c - k) + sorted_data[c] * (k - f)


def print_cycle_summary(results: list[PushResult], cycle: int, elapsed: float):
    success = sum(1 for r in results if 200 <= r.status_code < 300)
    failed = len(results) - success
    latencies = [r.latency_ms for r in results]
    p50 = compute_percentile(latencies, 50)
    p95 = compute_percentile(latencies, 95)
    max_lat = max(latencies) if latencies else 0
    status = "OK" if failed == 0 else f"FAIL({failed})"
    print(
        f"  Cycle {cycle:4d} | {len(results):5d} pushes | "
        f"{success} ok / {failed} err | "
        f"p50={p50:7.1f}ms p95={p95:7.1f}ms max={max_lat:7.1f}ms | "
        f"cycle_time={elapsed:.1f}s | {status}"
    )


def print_final_report(
    all_results: list[PushResult],
    probe_results: list[MetricsProbeResult],
    scenario_id: str,
    endpoint: str,
    num_nodes: int,
    duration_actual: float,
):
    """Print final summary report."""
    print("\n" + "=" * 90)
    print(f"FINAL REPORT — Scenario {scenario_id} (Pushgateway 2.0)")
    print("=" * 90)
    print(f"Endpoint:       {endpoint}")
    print(f"Nodes:          {num_nodes}")
    print(f"Total duration: {duration_actual:.1f}s ({duration_actual/60:.1f} min)")
    print(f"Total pushes:   {len(all_results)}")

    print("\n--- Per-Job Summary ---")
    print(f"{'Job':<30} {'Total':>7} {'OK':>7} {'Fail':>7} {'Rate':>7} "
          f"{'p50ms':>8} {'p95ms':>8} {'p99ms':>8} {'MaxMs':>8}")
    print("-" * 110)

    by_job = defaultdict(list)
    for r in all_results:
        by_job[r.job].append(r)

    for job_name in sorted(by_job.keys()):
        results = by_job[job_name]
        total = len(results)
        ok = sum(1 for r in results if 200 <= r.status_code < 300)
        fail = total - ok
        rate = (ok / total * 100) if total > 0 else 0
        lats = [r.latency_ms for r in results]
        p50 = compute_percentile(lats, 50)
        p95 = compute_percentile(lats, 95)
        p99 = compute_percentile(lats, 99)
        mx = max(lats) if lats else 0
        print(f"{job_name:<30} {total:>7} {ok:>7} {fail:>7} {rate:>6.1f}% "
              f"{p50:>8.1f} {p95:>8.1f} {p99:>8.1f} {mx:>8.1f}")

    total = len(all_results)
    ok = sum(1 for r in all_results if 200 <= r.status_code < 300)
    fail = total - ok
    rate = (ok / total * 100) if total > 0 else 0
    all_lats = [r.latency_ms for r in all_results]
    print("-" * 110)
    print(f"{'TOTAL':<30} {total:>7} {ok:>7} {fail:>7} {rate:>6.1f}% "
          f"{compute_percentile(all_lats, 50):>8.1f} "
          f"{compute_percentile(all_lats, 95):>8.1f} "
          f"{compute_percentile(all_lats, 99):>8.1f} "
          f"{max(all_lats) if all_lats else 0:>8.1f}")

    print("\n--- HTTP Status Codes ---")
    status_counts = defaultdict(int)
    for r in all_results:
        key = r.status_code if r.status_code > 0 else f"ERR:{r.error[:30]}"
        status_counts[key] += 1
    for code, count in sorted(status_counts.items(), key=lambda x: str(x[0])):
        print(f"  {code}: {count}")

    if probe_results:
        print("\n--- /metrics Endpoint Probe ---")
        print(f"{'Cycle':>6} {'Bytes':>12} {'Time_ms':>10} {'Status':>8}")
        for p in probe_results:
            size_str = f"{p.response_bytes/1024/1024:.2f} MB" if p.response_bytes > 0 else "ERROR"
            print(f"{p.cycle:>6} {size_str:>12} {p.response_time_ms:>10.1f} {p.status_code:>8}")
        if len(probe_results) >= 2:
            first, last = probe_results[0], probe_results[-1]
            if first.response_bytes > 0 and last.response_bytes > 0:
                growth = last.response_bytes / first.response_bytes
                print(f"\n  /metrics size growth: {first.response_bytes/1024:.0f} KB → "
                      f"{last.response_bytes/1024:.0f} KB ({growth:.2f}x)")

    print("\n" + "=" * 90)


# ─── CSV Writer ──────────────────────────────────────────────────────────────

class CSVWriter:
    def __init__(self, output_dir: Path, scenario_id: str):
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)

        push_path = output_dir / f"{scenario_id}_pushes.csv"
        self.push_file = open(push_path, "w", newline="")
        self.push_writer = csv.writer(self.push_file)
        self.push_writer.writerow([
            "timestamp", "cycle", "job", "instance",
            "status_code", "latency_ms", "payload_bytes", "error",
        ])

        probe_path = output_dir / f"{scenario_id}_probes.csv"
        self.probe_file = open(probe_path, "w", newline="")
        self.probe_writer = csv.writer(self.probe_file)
        self.probe_writer.writerow([
            "timestamp", "cycle", "response_bytes", "response_time_ms",
            "status_code", "error",
        ])

    def write_push(self, r: PushResult):
        self.push_writer.writerow([
            f"{r.timestamp:.3f}", r.cycle, r.job, r.instance,
            r.status_code, r.latency_ms, r.payload_bytes, r.error,
        ])

    def write_probe(self, p: MetricsProbeResult):
        self.probe_writer.writerow([
            f"{p.timestamp:.3f}", p.cycle, p.response_bytes,
            p.response_time_ms, p.status_code, p.error,
        ])

    def flush(self):
        self.push_file.flush()
        self.probe_file.flush()

    def close(self):
        self.push_file.close()
        self.probe_file.close()


# ─── Main Loop ───────────────────────────────────────────────────────────────

async def run_test(args):
    scenario_id = args.scenario
    endpoint = args.endpoint
    num_nodes = args.nodes
    interval = args.interval
    duration = args.duration
    jitter_max = args.jitter
    max_inflight = args.max_inflight
    pod_multiplier = args.pod_multiplier
    jobs_filter = args.jobs

    print(f"\n{'='*70}")
    print(f"Pushgateway Stress Test 2.0 — Scenario {scenario_id}")
    print(f"{'='*70}")
    print(f"Endpoint:        {endpoint}")
    print(f"Nodes:           {num_nodes}")
    print(f"Interval:        {interval}s")
    print(f"Duration:        {duration}s ({duration/60:.0f} min)")
    print(f"Jitter:          {jitter_max}s {'(OFF)' if jitter_max == 0 else '(ON)'}")
    print(f"Max in-flight:   {max_inflight}")
    print(f"Jobs filter:     {jobs_filter}")
    print(f"Pod multiplier:  {pod_multiplier}x")

    node_jobs = []
    cluster_jobs = []
    healthcheck_jobs = []

    if jobs_filter in ("all", "node", "node+cluster", "node+cluster+healthcheck"):
        node_jobs = NODE_LEVEL_JOBS
    if jobs_filter in ("all", "cluster", "node+cluster", "node+cluster+healthcheck"):
        cluster_jobs = CLUSTER_LEVEL_JOBS
    if jobs_filter in ("all", "node+cluster+healthcheck"):
        healthcheck_jobs = HEALTHCHECK_JOBS

    if jobs_filter not in ("all", "node", "cluster", "node+cluster", "node+cluster+healthcheck"):
        job_names = [j.strip() for j in jobs_filter.split(",")]
        for j in NODE_LEVEL_JOBS:
            if j["name"] in job_names:
                node_jobs.append(j)
        for j in CLUSTER_LEVEL_JOBS:
            if j["name"] in job_names:
                cluster_jobs.append(j)
        for j in HEALTHCHECK_JOBS:
            if j["name"] in job_names:
                healthcheck_jobs.append(j)

    all_jobs = node_jobs + cluster_jobs + healthcheck_jobs
    if not all_jobs:
        print("ERROR: No jobs selected", file=sys.stderr)
        sys.exit(1)

    nodes = generate_node_identities(num_nodes)
    healthcheck_pushes = sum(j.get("replicas", 1) for j in healthcheck_jobs)
    pushes_per_cycle = (len(node_jobs) * num_nodes) + len(cluster_jobs) + healthcheck_pushes

    print(f"\nJobs per cycle:")
    for j in node_jobs:
        print(f"  [node-level]    {j['name']} × {num_nodes} = {num_nodes} pushes")
    for j in cluster_jobs:
        mult_str = f" (inflated {pod_multiplier}x)" if pod_multiplier > 1 else ""
        print(f"  [cluster-level] {j['name']} × 1{mult_str} = 1 push")
    for j in healthcheck_jobs:
        r = j.get("replicas", 1)
        print(f"  [healthcheck]   {j['name']} × {r} = {r} pushes")
    print(f"  Total: {pushes_per_cycle} pushes/cycle")

    print(f"\nLoading payloads...")
    payloads = load_payloads(all_jobs)

    if pod_multiplier > 1 and "oci_lens_pod_metrics" in payloads:
        original_size = len(payloads["oci_lens_pod_metrics"])
        payloads["oci_lens_pod_metrics"] = inflate_pod_payload(
            payloads["oci_lens_pod_metrics"], pod_multiplier
        )
        new_size = len(payloads["oci_lens_pod_metrics"])
        print(f"  Inflated oci_lens_pod_metrics: "
              f"{original_size/1024:.1f} KB → {new_size/1024:.1f} KB ({pod_multiplier}x)")

    output_dir = RESULTS_DIR / scenario_id
    output_dir.mkdir(parents=True, exist_ok=True)
    csv_writer = CSVWriter(output_dir, scenario_id)

    ssl_ctx = None
    if endpoint.startswith("https"):
        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE

    connector = aiohttp.TCPConnector(
        limit=max_inflight,
        limit_per_host=max_inflight,
        keepalive_timeout=30,
        enable_cleanup_closed=True,
        ssl=ssl_ctx,
    )
    semaphore = asyncio.Semaphore(max_inflight)

    stop_event = asyncio.Event()

    def handle_signal(sig, frame):
        print(f"\n\nReceived signal {sig}, stopping after current cycle...")
        stop_event.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    all_results = []
    probe_results = []
    num_cycles = max(1, duration // interval)
    test_start = time.monotonic()

    print(f"\nStarting test: {num_cycles} cycles × {pushes_per_cycle} pushes = "
          f"{num_cycles * pushes_per_cycle} total pushes")
    print(f"{'='*70}\n")

    async with aiohttp.ClientSession(connector=connector) as session:
        for cycle in range(1, num_cycles + 1):
            if stop_event.is_set():
                print(f"\nStopping at cycle {cycle - 1}")
                break

            cycle_start = time.monotonic()

            results = await run_cycle(
                session, semaphore, endpoint,
                nodes, node_jobs, cluster_jobs, healthcheck_jobs, payloads,
                cycle, jitter_max,
            )

            cycle_elapsed = time.monotonic() - cycle_start

            for r in results:
                csv_writer.write_push(r)
                all_results.append(r)

            print_cycle_summary(results, cycle, cycle_elapsed)

            if cycle == 1 or cycle == num_cycles or cycle % 5 == 0:
                probe = await probe_metrics_endpoint(session, endpoint, cycle)
                csv_writer.write_probe(probe)
                probe_results.append(probe)
                if probe.response_bytes > 0:
                    print(f"         /metrics probe: {probe.response_bytes/1024:.0f} KB "
                          f"in {probe.response_time_ms:.0f}ms")

            csv_writer.flush()

            if cycle < num_cycles and not stop_event.is_set():
                wait_time = max(0, interval - cycle_elapsed)
                if wait_time > 0:
                    try:
                        await asyncio.wait_for(stop_event.wait(), timeout=wait_time)
                    except asyncio.TimeoutError:
                        pass

    test_duration = time.monotonic() - test_start
    csv_writer.close()

    print_final_report(
        all_results, probe_results,
        scenario_id, endpoint, num_nodes, test_duration,
    )

    summary_path = output_dir / f"{scenario_id}_summary.txt"
    with open(summary_path, "w") as f:
        import io
        old_stdout = sys.stdout
        sys.stdout = io.StringIO()
        print_final_report(
            all_results, probe_results,
            scenario_id, endpoint, num_nodes, test_duration,
        )
        summary_text = sys.stdout.getvalue()
        sys.stdout = old_stdout
        f.write(summary_text)

    print(f"\nResults written to: {output_dir}/")
    print(f"  {scenario_id}_pushes.csv  — per-push detail")
    print(f"  {scenario_id}_probes.csv  — /metrics endpoint probes")
    print(f"  {scenario_id}_summary.txt — this summary")


# ─── CLI ─────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Pushgateway Stress Test 2.0 Generator (Updated Architecture)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Examples:
  python3 generator.py --scenario C0 --endpoint http://10.96.230.201:9091 \\
      --nodes 10 --jitter 5 --duration 300 --jobs node+cluster+healthcheck

  python3 generator.py --scenario C5 --endpoint http://10.96.230.201:9091 \\
      --nodes 1000 --jitter 20 --duration 1200 --jobs node+cluster+healthcheck
""",
    )
    parser.add_argument("--scenario", "-s", required=True, help="Scenario ID")
    parser.add_argument("--endpoint", "-e", required=True, help="Pushgateway URL")
    parser.add_argument("--nodes", "-n", type=int, required=True, help="Number of simulated nodes")
    parser.add_argument("--interval", "-i", type=int, default=60, help="Push interval (s)")
    parser.add_argument("--duration", "-d", type=int, required=True, help="Duration (s)")
    parser.add_argument("--jitter", "-j", type=float, default=0, help="Max jitter (s)")
    parser.add_argument("--max-inflight", type=int, default=500, help="Max concurrent requests")
    parser.add_argument(
        "--jobs",
        default="node+cluster+healthcheck",
        help="Jobs: node, cluster, node+cluster, node+cluster+healthcheck, or comma-separated",
    )
    parser.add_argument("--pod-multiplier", type=int, default=1, help="Pod metrics inflation factor")
    return parser.parse_args()


def main():
    args = parse_args()
    asyncio.run(run_test(args))


if __name__ == "__main__":
    main()
