#!/usr/bin/env bash
# Restores an Azurite backup over the current data (DESTRUCTIVE).
#   ./scripts/restore.sh ./backups/cipp-azurite-2026-10-05-0200.tgz
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHIVE="$(realpath "${1:?archive path required}")"
read -rp "This replaces ALL current CIPP data with $ARCHIVE. Type RESTORE: " ok
[[ "$ok" == "RESTORE" ]] || { echo "Aborted"; exit 1; }
C="docker compose -f docker-compose.local.yml"
$C stop cipp-api cipp-api-build azurite 2>/dev/null || true
docker run --rm -v cipp-local_azurite-data:/d -v "$(dirname "$ARCHIVE")":/b:ro alpine \
  sh -c "rm -rf /d/* && tar xzf /b/$(basename "$ARCHIVE") -C /d"
$C up -d
echo "Restored."
