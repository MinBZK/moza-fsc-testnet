#!/usr/bin/env bash
# Smoke: bewijst dat magazijn-a zich aanmeldt (announce) bij de directory.
# Pollt de directory-DB (peers.peers) tot de magazijn-a-OIN verschijnt.
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
MAGA_OIN="00000001003214345000"
DIR_OIN="00000000000000000010"
TIMEOUT=120
INTERVAL=5

echo "smoke: wachten tot magazijn-a ($MAGA_OIN) announce't bij de directory..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  rows=$("${COMPOSE[@]}" exec -T postgres \
    psql -U postgres -d fsc_directory -tA \
    -c "SELECT peer_id FROM peers.peers;" 2>/dev/null || true)
  if printf '%s\n' "$rows" | grep -qx "$MAGA_OIN"; then
    echo "OK: magazijn-a is aangemeld bij de directory."
    echo "Aangemelde peers:"
    "${COMPOSE[@]}" exec -T postgres \
      psql -U postgres -d fsc_directory \
      -c "SELECT peer_id, name, manager_address FROM peers.peers;"
    exit 0
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet aangemeld (${elapsed}s)"
done

echo "FAIL: magazijn-a ($MAGA_OIN) niet aangemeld binnen ${TIMEOUT}s." >&2
echo "Debug: directory-logs:" >&2
"${COMPOSE[@]}" logs --tail=50 manager-directory manager-magazijn-a >&2 || true
exit 1
