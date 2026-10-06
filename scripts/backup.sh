#!/usr/bin/env bash
# Backs up the Azurite volume (= the whole CIPP database incl. DevSecrets).
# Briefly stops cipp-api + azurite so the LokiJS file is consistent.
#   ./scripts/backup.sh [/path/to/backup/dir]
# The archive contains secrets (SAM app secret, refresh token) – store it like one.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${1:-./backups}"; mkdir -p "$DEST"
C="docker compose -f docker-compose.local.yml"
FILE="cipp-azurite-$(date +%F-%H%M).tgz"

$C stop cipp-api cipp-api-build azurite 2>/dev/null || true
docker run --rm -v cipp-local_azurite-data:/d:ro -v "$(realpath "$DEST")":/b alpine \
  tar czf "/b/$FILE" -C /d .
$C start azurite
$C start cipp-api 2>/dev/null || $C start cipp-api-build 2>/dev/null || true
chmod 600 "$DEST/$FILE"
echo "Backup written: $DEST/$FILE"
# keep last 14
ls -1t "$DEST"/cipp-azurite-*.tgz | tail -n +15 | xargs -r rm -f
