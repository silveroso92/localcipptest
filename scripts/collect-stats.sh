#!/usr/bin/env bash
# Samples container CPU/RAM + Azurite DB size every N seconds into a CSV.
# Run in the background for the whole test window:
#   nohup ./scripts/collect-stats.sh 60 > /dev/null 2>&1 &
# Output: ./stats/cipp-stats-YYYY-MM-DD.csv (one file per day)
set -euo pipefail
INTERVAL="${1:-60}"
cd "$(dirname "$0")/.."
mkdir -p stats
PROJECT=cipp-local

while true; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  OUT="stats/cipp-stats-$(date -u +%F).csv"
  [[ -f "$OUT" ]] || echo "timestamp,container,cpu_pct,mem_used_mib,mem_limit_mib,mem_pct,net_rx_mb,net_tx_mb,azurite_db_mb" > "$OUT"

  AZ_CID=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=azurite" | head -1)
  DB_MB=0
  if [[ -n "$AZ_CID" ]]; then
    DB_BYTES=$(docker exec "$AZ_CID" sh -c 'du -sb /workspace 2>/dev/null | cut -f1' || echo 0)
    DB_MB=$(awk -v b="$DB_BYTES" 'BEGIN{printf "%.1f", b/1048576}')
  fi

  docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}' \
    $(docker ps -q --filter "label=com.docker.compose.project=$PROJECT") 2>/dev/null |
  awk -F'|' -v ts="$TS" -v db="$DB_MB" '
    function mib(v,  n,u){ n=v+0; u=v; gsub(/[0-9. ]/,"",u)
      if(u~/^GiB|^GB/) return n*1024; if(u~/^KiB|^kB/) return n/1024; if(u~/^B/) return n/1048576; return n }
    function mb(v,  n,u){ n=v+0; u=v; gsub(/[0-9. ]/,"",u)
      if(u~/^GB/) return n*1000; if(u~/^kB/) return n/1000; if(u~/^B/) return n/1e6; return n }
    { split($3,m," / "); split($5,n," / "); cpu=$2; gsub("%","",cpu); mp=$4; gsub("%","",mp)
      printf "%s,%s,%s,%.1f,%.1f,%s,%.1f,%.1f,%s\n", ts,$1,cpu,mib(m[1]),mib(m[2]),mp,mb(n[1]),mb(n[2]),db }' >> "$OUT"
  sleep "$INTERVAL"
done
