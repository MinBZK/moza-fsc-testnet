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

# Vang psql-stderr op i.p.v. weg te gooien: een persistente DB-fout (auth, ontbrekende
# kolom/tabel, dode container) mag niet als "nog niet aangemeld" maskeren — surface 'm
# op de FAIL-paden. Loop-stderr zelf blijft stil (transiënte boot-ruis).
ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

echo "smoke: wachten tot magazijn-a ($MAGA_OIN) announce't bij de directory (op :443)..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  rows=$("${COMPOSE[@]}" exec -T postgres \
    psql -U postgres -d fsc_directory -tA \
    -c "SELECT id FROM peers.peers WHERE manager_address LIKE '%:443';" 2>"$ERRLOG" || true)
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
# query/DB/het schema kapot (bv. kolomnaam), niet de announce. Laat stderr hier
# DOOR (in ERRLOG) zodat de conclusie op de échte psql-fout rust.
if ! "${COMPOSE[@]}" exec -T postgres psql -U postgres -d fsc_directory -tA \
     -c "SELECT id FROM peers.peers WHERE manager_address LIKE '%:443';" 2>"$ERRLOG" \
     | grep -qx "$DIR_OIN"; then
  echo "  -> directory self-row ($DIR_OIN op :443) ontbreekt: query/DB/schema" \
       "(id/manager_address) kapot, niet de announce." >&2
fi
# Surface de laatste psql-stderr (leeg = schoon, dus echt geen announce).
if [ -s "$ERRLOG" ]; then
  echo "  -> laatste psql-fout:" >&2
  tail -n 3 "$ERRLOG" >&2
fi
echo "Debug: logs (postgres + migrate + managers):" >&2
"${COMPOSE[@]}" logs --tail=50 \
  postgres manager-directory migrate-magazijn-a manager-magazijn-a >&2 || true
exit 1
