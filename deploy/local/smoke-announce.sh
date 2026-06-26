#!/usr/bin/env bash
# Smoke: bewijst dat magazijn-a zich aanmeldt (announce) bij de directory ÉN dat
# dat via de :443-SNI-mesh gaat. Pollt de directory-DB tot de magazijn-a-OIN met
# een manager_address op :443 in peers.peers verschijnt.
# NB: de kolomnaam `id` + tabel `peers.peers` zijn een load-bearing schema-contract.
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
MAGA_OIN="00000001003214345000"
DIR_OIN="00000000000000000010"
TIMEOUT=120
INTERVAL=5

echo "smoke: wachten tot magazijn-a ($MAGA_OIN) announce't bij de directory (op :443)..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  rows=$("${COMPOSE[@]}" exec -T postgres \
    psql -U postgres -d fsc_directory -tA \
    -c "SELECT id FROM peers.peers WHERE manager_address LIKE '%:443';" 2>/dev/null || true)
  if printf '%s\n' "$rows" | grep -qx "$MAGA_OIN"; then
    echo "OK: magazijn-a is aangemeld bij de directory (manager_address op :443)."
    echo "Aangemelde peers:"
    "${COMPOSE[@]}" exec -T postgres \
      psql -U postgres -d fsc_directory \
      -c "SELECT id, name, manager_address FROM peers.peers;" || true
    exit 0
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet aangemeld (${elapsed}s)"
done

echo "FAIL: magazijn-a ($MAGA_OIN) niet aangemeld op :443 binnen ${TIMEOUT}s." >&2
# Positief-controle: staat de directory zélf in peers.peers? Zo niet, dan is de
# query/DB/het schema kapot (bv. kolomnaam), niet de announce.
if ! "${COMPOSE[@]}" exec -T postgres psql -U postgres -d fsc_directory -tA \
     -c "SELECT id FROM peers.peers WHERE manager_address LIKE '%:443';" 2>/dev/null \
     | grep -qx "$DIR_OIN"; then
  echo "  -> directory self-row ($DIR_OIN op :443) ontbreekt: query/DB/schema" \
       "(id/manager_address) kapot, niet de announce." >&2
fi
echo "Debug: logs (postgres + migrate + managers):" >&2
"${COMPOSE[@]}" logs --tail=50 \
  postgres manager-directory migrate-magazijn-a manager-magazijn-a >&2 || true
exit 1
