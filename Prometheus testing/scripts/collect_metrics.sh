#!/bin/bash
###############################################################################
# Collect Metrics
#
# Queries Prometheus API for all stress-test metrics and appends a row
# to the scenario CSV. Designed to be called repeatedly (every 30–60s)
# during a scenario run.
#
# Requires: port-forward to Prometheus active on localhost:9090
#           (or set PROM_URL environment variable)
#
# Usage:
#   ./collect_metrics.sh <SCENARIO_ID> <N>
#   ./collect_metrics.sh R0 10
###############################################################################

set -euo pipefail

SCENARIO_ID="${1:?Usage: $0 <SCENARIO_ID> <N>}"
N="${2:?Usage: $0 <SCENARIO_ID> <N>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_DIR}/results/${SCENARIO_ID}"
mkdir -p "$RESULTS_DIR"

PROM_URL="${PROM_URL:-http://localhost:9090}"
CSV_FILE="${RESULTS_DIR}/${SCENARIO_ID}_metrics.csv"
EXPECTED_TARGETS=$(( N * 4 ))

# ─── Helper: query Prometheus ───────────────────────────────────────────────

prom_query() {
    local query="$1"
    local encoded
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")
    local result
    result=$(curl -sfg --max-time 10 \
        "${PROM_URL}/api/v1/query?query=${encoded}" 2>/dev/null || echo '{"status":"error"}')
    echo "$result"
}

# Extract scalar value from Prometheus instant query response
extract_value() {
    local json="$1"
    python3 -c "
import json, sys
try:
    data = json.loads('''${json}''')
    if data.get('status') != 'success':
        print('')
        sys.exit(0)
    result = data['data']['result']
    if not result:
        print('')
    elif data['data']['resultType'] == 'scalar':
        print(result[1])
    else:
        print(result[0]['value'][1])
except:
    print('')
"
}

# ─── Write CSV header if file doesn't exist ─────────────────────────────────

if [[ ! -f "$CSV_FILE" ]]; then
    echo "timestamp,targets_discovered,targets_up,targets_down,scrape_success_pct,scrape_duration_p50,scrape_duration_p95,scrape_duration_max,samples_per_sec,head_series,memory_bytes,cpu_cores,out_of_order_rate" \
        > "$CSV_FILE"
fi

# ─── Collect all metrics ────────────────────────────────────────────────────

ts=$(date -Iseconds)

# A) Scrape success
targets_total_json=$(prom_query 'count(up{job=~"lens-scale-test.*"})')
targets_up_json=$(prom_query 'count(up{job=~"lens-scale-test.*"} == 1)')
targets_down_json=$(prom_query 'count(up{job=~"lens-scale-test.*"} == 0)')

targets_total=$(extract_value "$targets_total_json")
targets_up=$(extract_value "$targets_up_json")
targets_down=$(extract_value "$targets_down_json")

# Success percentage
if [[ -n "$targets_total" && "$targets_total" != "0" ]]; then
    success_pct=$(python3 -c "print(round(float('${targets_up:-0}') / float('${targets_total}') * 100, 1))")
else
    success_pct=""
fi

# B) Scrape duration (across all scale-test targets)
dur_p50_json=$(prom_query 'quantile(0.5, scrape_duration_seconds{job=~"lens-scale-test.*"})')
dur_p95_json=$(prom_query 'quantile(0.95, scrape_duration_seconds{job=~"lens-scale-test.*"})')
dur_max_json=$(prom_query 'max(scrape_duration_seconds{job=~"lens-scale-test.*"})')

dur_p50=$(extract_value "$dur_p50_json")
dur_p95=$(extract_value "$dur_p95_json")
dur_max=$(extract_value "$dur_max_json")

# D) Ingestion throughput
samples_sec_json=$(prom_query 'rate(prometheus_tsdb_head_samples_appended_total[5m])')
head_series_json=$(prom_query 'prometheus_tsdb_head_series')

samples_sec=$(extract_value "$samples_sec_json")
head_series=$(extract_value "$head_series_json")

# E) Resource saturation
memory_json=$(prom_query 'process_resident_memory_bytes{job="prometheus"}')
cpu_json=$(prom_query 'rate(process_cpu_seconds_total{job="prometheus"}[5m])')

memory_bytes=$(extract_value "$memory_json")
cpu_cores=$(extract_value "$cpu_json")

# F) Data correctness
ooo_json=$(prom_query 'rate(prometheus_tsdb_out_of_order_samples_total[5m])')
ooo_rate=$(extract_value "$ooo_json")

# ─── Write CSV row ──────────────────────────────────────────────────────────

echo "${ts},${targets_total:-},${targets_up:-},${targets_down:-},${success_pct:-},${dur_p50:-},${dur_p95:-},${dur_max:-},${samples_sec:-},${head_series:-},${memory_bytes:-},${cpu_cores:-},${ooo_rate:-}" \
    >> "$CSV_FILE"

# ─── Print summary ──────────────────────────────────────────────────────────

mem_gb=""
if [[ -n "$memory_bytes" ]]; then
    mem_gb=$(python3 -c "print(f'{float(\"${memory_bytes}\") / 1073741824:.1f}')")
fi

printf "[%s] targets=%s/%s up=%s (%.0f%%) | dur_p50=%.3fs p95=%.3fs | series=%s mem=%sGB cpu=%s\n" \
    "$ts" \
    "${targets_total:-?}" "$EXPECTED_TARGETS" \
    "${targets_up:-?}" "${success_pct:-0}" \
    "${dur_p50:-0}" "${dur_p95:-0}" \
    "${head_series:-?}" "${mem_gb:-?}" "${cpu_cores:-?}"
