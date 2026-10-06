#!/usr/bin/env bash
# Summarizes collected stats: avg / p95 / max CPU and RAM per container, plus
# Azurite growth and request volume through Caddy. Compare against the plan
# you're simulating (README sizing table) to pick the Azure SKU.
#   ./scripts/summarize-stats.sh            # all days
#   ./scripts/summarize-stats.sh 2026-10-0  # files matching a date prefix
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=$(ls stats/cipp-stats-${1:-}*.csv 2>/dev/null) || { echo "No stats files found"; exit 1; }

echo "== Container usage ($(echo "$FILES" | wc -l) day file(s)) =="
printf "%-34s %8s %8s %8s %10s %10s %10s %8s\n" CONTAINER CPU_AVG CPU_P95 CPU_MAX MEM_AVG MEM_P95 MEM_MAX LIMIT
for c in $(tail -q -n +2 $FILES | cut -d, -f2 | sort -u); do
  tail -q -n +2 $FILES | awk -F, -v c="$c" '$2==c' > /tmp/.cipp_c.$$
  n=$(wc -l < /tmp/.cipp_c.$$); p=$(( (n*95+99)/100 )); [[ $p -lt 1 ]] && p=1
  cpu_avg=$(awk -F, '{s+=$3}END{printf "%.1f",s/NR}' /tmp/.cipp_c.$$)
  cpu_p95=$(cut -d, -f3 /tmp/.cipp_c.$$ | sort -g | sed -n "${p}p")
  cpu_max=$(cut -d, -f3 /tmp/.cipp_c.$$ | sort -g | tail -1)
  mem_avg=$(awk -F, '{s+=$4}END{printf "%.0f",s/NR}' /tmp/.cipp_c.$$)
  mem_p95=$(cut -d, -f4 /tmp/.cipp_c.$$ | sort -g | sed -n "${p}p")
  mem_max=$(cut -d, -f4 /tmp/.cipp_c.$$ | sort -g | tail -1)
  lim=$(tail -1 /tmp/.cipp_c.$$ | cut -d, -f5)
  printf "%-34s %7s%% %7s%% %7s%% %8sMiB %8sMiB %8sMiB %6.0fMiB\n" "$c" "$cpu_avg" "$cpu_p95" "$cpu_max" "$mem_avg" "$mem_p95" "$mem_max" "$lim"
done
rm -f /tmp/.cipp_c.$$
echo "(docker CPU% is per-core: 200% = both vCPUs of a B2 fully busy)"

echo
echo "== Azurite storage (proxy for Storage Account capacity) =="
tail -q -n +2 $FILES | awk -F, 'NR==1{f=$9;ft=$1}{l=$9;lt=$1}END{printf "first %s MB (%s)  last %s MB (%s)\n",f,ft,l,lt}'

if docker compose -f docker-compose.local.yml ps caddy -q >/dev/null 2>&1; then
  echo
  echo "== Requests through Caddy (UI/API usage by techs) =="
  docker compose -f docker-compose.local.yml exec -T caddy sh -c 'cat /data/access.log* 2>/dev/null' |
    awk -F'"ts":' '{split($2,a,","); d=strftime("%Y-%m-%d",a[1]); c[d]++} END{for(k in c) print k, c[k]}' | sort || true
fi
