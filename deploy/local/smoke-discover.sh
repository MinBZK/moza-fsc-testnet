#!/usr/bin/env bash
# Smoke: bewijst dat example-consumer (a) zich aanmeldt (announce) bij de directory
# ÉN (b) de door example-provider gepubliceerde example-service kan vinden (discovery).
# Announce: pollt de directory-DB (peers.peers, zoals smoke-announce.sh). Discovery: bevraagt de
# consumer-manager via de mesh-API (GET /v1/peers/{dir}/services, zoals smoke-publish.sh) — geen
# koppeling aan een directory-tabelnaam. Vereist dat de provider eerst publiceerde
# (`publish-service.sh` / `smoke-publish.sh` vooraf).
# NB: tabel `peers.peers` + kolom `id`/`manager_address` zijn een load-bearing schema-contract.
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
CONSUMER_OIN="00000000000000000020"
DIR_OIN="00000000000000000010"
SERVICE_NAME="example-service"
TIMEOUT=10
INTERVAL=2

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

# --- 2. Discovery: example-service vindbaar via de consumer-manager (mesh-API) ----------
# De consumer bevraagt de directory via zijn EIGEN manager (internal-cert) naar de door
# example-provider gepubliceerde diensten — spiegelt smoke-publish.sh's vindbaarheids-check,
# maar vanaf de consumer-kant. Robuuster dan de directory-DB pollen (geen tabelnaam-koppeling).
PROVIDER_OIN="00000000000000000030"
CONS_MANAGER="https://manager.example-consumer.fsc-test.local:9443"
CERT=/pki/internal/example-consumer/manager/cert.pem
KEY=/pki/internal/example-consumer/manager/key.pem
CA=/pki/internal/example-consumer/ca/root.pem

echo "smoke-discover: wachten tot ${SERVICE_NAME} vindbaar is via de consumer-manager..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  out=$("${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
          --cert "$CERT" --key "$KEY" --cacert "$CA" \
          "$CONS_MANAGER/v1/peers/$DIR_OIN/services?peer_id=$PROVIDER_OIN" 2>"$ERRLOG" || true)
  [ -s "$ERRLOG" ] && { echo "  WARN: query-fout: $(tail -n1 "$ERRLOG")" >&2; : >"$ERRLOG"; }
  if printf '%s' "$out" | grep -q "\"$SERVICE_NAME\""; then
    echo "OK: ${SERVICE_NAME} is vindbaar via de consumer-manager (discovery)."
    printf 'Catalogus: %s\n' "$out"
    echo "SMOKE-DISCOVER GROEN."
    exit 0
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet vindbaar (${elapsed}s)"
done

echo "FAIL: ${SERVICE_NAME} niet vindbaar via de consumer-manager binnen ${TIMEOUT}s (provider gepubliceerd?)." >&2
[ -s "$ERRLOG" ] && { echo "  -> laatste query-fout:" >&2; tail -n 3 "$ERRLOG" >&2; }
"${COMPOSE[@]}" logs --tail=50 manager-directory manager-example-consumer manager-example-provider >&2 || true
exit 1
