#!/usr/bin/env bash
# Smoke (#725): bewijst dat example-consumer (a) zich aanmeldt (announce) bij de directory
# ÉN (b) de door example-provider gepubliceerde example-service kan vinden (discovery).
# Pollt de directory-DB (zoals smoke-announce.sh). Vereist dat de provider eerst publiceerde
# (draai `publish-service.sh` of `smoke-publish.sh` vooraf).
# NB: tabel `peers.peers` + kolom `id`/`manager_address` zijn een load-bearing schema-contract
# (spiegelt smoke-announce.sh). De services-tabel wordt dynamisch geresolved (schema-agnostisch).
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
CONSUMER_OIN="00000000000000000020"
DIR_OIN="00000000000000000010"
SERVICE_NAME="example-service"
TIMEOUT=120
INTERVAL=5

# Vang psql-stderr op i.p.v. weg te gooien: een persistente DB-fout (auth, ontbrekende
# kolom/tabel, dode container) mag niet als "nog niet vindbaar" maskeren — surface 'm op
# de FAIL-paden (spiegelt smoke-announce.sh).
ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

psqlq() {
  "${COMPOSE[@]}" exec -T postgres psql -U postgres -d fsc_directory -tA -c "$1" 2>"$ERRLOG"
}

# --- 1. Announce: consumer-OIN in peers.peers met manager_address op :443 --------------
echo "smoke-discover: wachten tot example-consumer ($CONSUMER_OIN) announce't bij de directory (op :443)..."
elapsed=0
announced=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  rows=$(psqlq "SELECT id FROM peers.peers WHERE manager_address LIKE '%:443';" || true)
  if printf '%s\n' "$rows" | grep -qx "$CONSUMER_OIN"; then
    echo "OK: example-consumer is aangemeld bij de directory (manager_address op :443)."
    announced=1
    break
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet aangemeld (${elapsed}s)"
done

if [ "$announced" -eq 0 ]; then
  echo "FAIL: example-consumer ($CONSUMER_OIN) niet aangemeld op :443 binnen ${TIMEOUT}s." >&2
  # Positief-controle: staat de directory zélf in peers.peers? Zo niet, dan is de query/DB/
  # het schema kapot (bv. kolomnaam), niet de announce.
  if ! psqlq "SELECT id FROM peers.peers WHERE manager_address LIKE '%:443';" | grep -qx "$DIR_OIN"; then
    echo "  -> directory self-row ($DIR_OIN op :443) ontbreekt: query/DB/schema kapot, niet de announce." >&2
  fi
  [ -s "$ERRLOG" ] && { echo "  -> laatste psql-fout:" >&2; tail -n 3 "$ERRLOG" >&2; }
  "${COMPOSE[@]}" logs --tail=50 postgres manager-directory \
    migrate-example-consumer manager-example-consumer >&2 || true
  exit 1
fi

# --- 2. Discovery: example-service vindbaar in de directory-catalogus -------------------
# Resolve de services-tabel schema-agnostisch (directory-schema kan per versie verschillen).
SVC_TBL=$(psqlq "SELECT format('%I.%I', table_schema, table_name)
                 FROM information_schema.tables
                 WHERE table_name = 'services' ORDER BY table_schema LIMIT 1;" | head -n1 || true)
if [ -z "$SVC_TBL" ]; then
  echo "FAIL: geen 'services'-tabel in de directory-DB (schema-contract veranderd?)." >&2
  [ -s "$ERRLOG" ] && { echo "  -> psql-fout:" >&2; tail -n 3 "$ERRLOG" >&2; }
  exit 1
fi
echo "smoke-discover: services-tabel = ${SVC_TBL}; wachten tot ${SERVICE_NAME} vindbaar is..."

elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  cnt=$(psqlq "SELECT count(*) FROM ${SVC_TBL} WHERE name = '${SERVICE_NAME}';" || true)
  if [ "${cnt:-0}" -ge 1 ] 2>/dev/null; then
    echo "OK: ${SERVICE_NAME} is vindbaar in de directory (discovery)."
    echo "Catalogus:"
    psqlq "SELECT name FROM ${SVC_TBL};" || true
    echo "SMOKE-DISCOVER GROEN."
    exit 0
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet vindbaar (${elapsed}s)"
done

echo "FAIL: ${SERVICE_NAME} niet vindbaar in de directory binnen ${TIMEOUT}s (provider gepubliceerd?)." >&2
[ -s "$ERRLOG" ] && { echo "  -> laatste psql-fout:" >&2; tail -n 3 "$ERRLOG" >&2; }
"${COMPOSE[@]}" logs --tail=50 manager-directory manager-example-provider >&2 || true
exit 1
