#!/usr/bin/env bash
# Bring the M3a stack up, run the gated E2E, tear it down.
# Usage: scripts/m3a-e2e.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo ".env missing — copying from .env.example" >&2
  cp .env.example .env
  echo "EDIT .env to set MEMORY_BEARER_TOKEN, then re-run." >&2
  exit 1
fi

docker compose up -d --build

# wait for memory /healthz
for i in $(seq 1 60); do
  if curl -fsS http://localhost:8081/healthz >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS http://localhost:8081/healthz || { docker compose logs memory; exit 1; }

TOKEN=$(grep '^MEMORY_BEARER_TOKEN=' .env | cut -d= -f2-)
GEMMA_LIVE_DOCKER=1 \
MEMORY_BEARER_TOKEN="$TOKEN" \
xcodebuild test -scheme Gemma -project Gemma/Gemma.xcodeproj -destination 'platform=macOS' \
  -only-testing:GemmaTests/MemoryServiceLiveTests 2>&1 | tail -40

docker compose down
