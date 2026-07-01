#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Smoke (#728): bewijst de end-to-end afname MÉT verantwoording, tussen example-consumer en
# example-provider:
#   (1) een echte data-call loopt  consumer-app -> outway -> inway -> stub-upstream -> terug;
#   (2) toegang is afgedwongen via een certificate-bound token (Fsc-Authorization): een call
#       zónder geldig token wordt door de inway geweigerd (401 ERROR_CODE_ACCESS_TOKEN_MISSING);
#   (3) de keten is correleerbaar via één Fsc-Transaction-Id die zowel bij de outway (direction
#       out, consumer-txlog) als bij de inway (direction in, provider-txlog) gelogd wordt.
#
# Vereist een geldig contract (#727). smoke-e2e draait daarom eerst bootstrap.sh (idempotent).
# De outway resolvet grant-hash -> service -> inway native (auto-discovery via de eigen manager);
# ENABLE_GRANT_HASH_SUGGESTION laat 'm de bruikbare grant-hash teruggeven zodat we die kunnen
# ontdekken zonder 'm zelf te berekenen (de grant-hash != contract-content_hash).
#
# Volgorde: up -> publish-service.sh -> smoke-discover.sh -> smoke-contract.sh -> smoke-e2e.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
COMPOSE=(docker compose -f "${HERE}/docker-compose.yaml")

STUB_MARKER="${STUB_MARKER:-hello from example-provider stub-upstream}"
OUTWAY="http://outway.example-consumer.fsc-test.local:8080"
INWAY="https://inway.example-provider.fsc-test.local:443"
# Group-cert waarmee de outway (en dus onze directe negatief-test) zich mTLS naar de inway meldt.
GCERT=/pki/out/example-consumer/outway/cert.pem
GKEY=/pki/out/example-consumer/outway/key.pem
GROOT=/pki/ca/root.pem
TXDB_CONSUMER="${TXDB_CONSUMER:-fsc_txlog_example_consumer}"
TXDB_PROVIDER="${TXDB_PROVIDER:-fsc_txlog_example_provider}"
DISCOVER_TIMEOUT="${DISCOVER_TIMEOUT:-45}"; TXLOG_TIMEOUT="${TXLOG_TIMEOUT:-30}"; INTERVAL=3

ERRLOG=$(mktemp); trap 'rm -f "$ERRLOG"' EXIT

# curl in de toolbox (plain HTTP naar de outway; geen cert nodig voor de app->outway-hop).
tbx() { "${COMPOSE[@]}" exec -T toolbox curl -s "$@" 2>"$ERRLOG"; }
# psql tegen een txlog-DB.
psqltx() { "${COMPOSE[@]}" exec -T postgres psql -U postgres -d "$1" -tA -c "$2" 2>>"$ERRLOG"; }

# --- 0. Contract garanderen (idempotent) ------------------------------------------------------
echo "smoke-e2e: contract garanderen (bootstrap, idempotent)..."
bash "${REPO_ROOT}/contracts/bootstrap.sh"

# --- 1. Grant-hash ontdekken via de outway-suggestie (pollt tot de outway het contract kent) --
# Zonder geldige Fsc-Grant-Hash geeft de outway (met ENABLE_GRANT_HASH_SUGGESTION) de bruikbare
# grant-hash(es) terug. Grant-hash-formaat: `$1$<n>$<base64url>` (zie open-fsc walkthrough).
echo "smoke-e2e: grant-hash ontdekken via de outway (max ${DISCOVER_TIMEOUT}s; grant-links-cache-TTL=30s)..."
GH=""; elapsed=0
while [ "$elapsed" -lt "$DISCOVER_TIMEOUT" ]; do
  SUGG=$(tbx "$OUTWAY/" -H 'Fsc-Grant-Hash: discover' || true)
  # shellcheck disable=SC2016  # de `$1$<n>$...` is het letterlijke grant-hash-formaat, geen var.
  GH=$(printf '%s' "$SUGG" | grep -oE '\$1\$[0-9]+\$[A-Za-z0-9_/+=-]{20,}' | head -n1 || true)
  [ -n "$GH" ] && break
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...outway kent de grant nog niet (${elapsed}s)"
done
if [ -z "$GH" ]; then
  echo "FAIL: geen grant-hash uit de outway-suggestie binnen ${DISCOVER_TIMEOUT}s." >&2
  echo "  Laatste outway-respons:" >&2; printf '%s\n' "${SUGG:-<leeg>}" >&2
  [ -s "$ERRLOG" ] && { echo "  curl-fout: $(tail -n1 "$ERRLOG")" >&2; }
  "${COMPOSE[@]}" logs --tail=50 outway-example-consumer manager-example-consumer >&2 || true
  exit 1
fi
echo "  grant-hash = $GH"

# --- 2. Positieve data-call: consumer -> outway -> inway -> stub -> terug ----------------------
echo "smoke-e2e: data-call via de outway (verwacht 200 + stub-echo)..."
BODY=$(tbx -o - -w '\n%{http_code}' "$OUTWAY/" -H "Fsc-Grant-Hash: $GH" || true)
CODE=$(printf '%s' "$BODY" | tail -n1)
PAYLOAD=$(printf '%s' "$BODY" | sed '$d')
if [ "$CODE" = "200" ] && printf '%s' "$PAYLOAD" | grep -qF "$STUB_MARKER"; then
  echo "OK: data-call geslaagd (200) en stub-echo ontvangen: $(printf '%s' "$PAYLOAD" | head -n1)"
else
  echo "FAIL: data-call niet geslaagd (HTTP ${CODE:-<geen>}); verwacht 200 + \"$STUB_MARKER\"." >&2
  printf '  respons: %s\n' "$PAYLOAD" >&2
  [ -s "$ERRLOG" ] && echo "  curl-fout: $(tail -n1 "$ERRLOG")" >&2
  "${COMPOSE[@]}" logs --tail=60 outway-example-consumer inway-example-provider stub-upstream >&2 || true
  exit 1
fi

# --- 3. Token-afdwinging: directe inway-call ZONDER token -> 401 -------------------------------
# We omzeilen de outway en spreken de inway direct aan (group-mTLS, maar géén Fsc-Authorization).
# De inway hoort dit te weigeren met 401 ERROR_CODE_ACCESS_TOKEN_MISSING.
echo "smoke-e2e: token-afdwinging (directe inway-call zonder token, verwacht 401)..."
NEG=$("${COMPOSE[@]}" exec -T toolbox curl -s -o /dev/null -D - -w '%{http_code}' \
        --cert "$GCERT" --key "$GKEY" --cacert "$GROOT" "$INWAY/" 2>"$ERRLOG" || true)
NCODE=$(printf '%s' "$NEG" | tail -n1)
if [ "$NCODE" = "401" ] || printf '%s' "$NEG" | grep -qi 'ERROR_CODE_ACCESS_TOKEN_MISSING'; then
  echo "OK: inway weigert zonder token (HTTP ${NCODE}; ERROR_CODE_ACCESS_TOKEN_MISSING)."
else
  echo "FAIL: inway weigerde niet zoals verwacht (HTTP ${NCODE:-<geen>}, geen ACCESS_TOKEN_MISSING)." >&2
  printf '%s\n' "$NEG" >&2
  [ -s "$ERRLOG" ] && echo "  curl-fout: $(tail -n1 "$ERRLOG")" >&2
  exit 1
fi

# --- 4. Verantwoording: één Fsc-Transaction-Id bij zowel outway (out) als inway (in) -----------
# De outway logt de transactie (direction out) in de consumer-txlog; de inway (direction in) in
# de provider-txlog — met DEZELFDE transaction_id. Tabel/kolom schema-agnostisch opzoeken.
echo "smoke-e2e: transactie-correlatie (zelfde Fsc-Transaction-Id in beide txlogs)..."
find_tx_table() {  # $1=db ; echoot "schema.table" met een transaction_id-kolom
  psqltx "$1" "SELECT format('%I.%I', table_schema, table_name)
               FROM information_schema.columns
               WHERE column_name = 'transaction_id' AND table_schema NOT IN ('pg_catalog','information_schema')
               ORDER BY table_schema LIMIT 1;" | head -n1
}
CTBL=$(find_tx_table "$TXDB_CONSUMER" || true)
PTBL=$(find_tx_table "$TXDB_PROVIDER" || true)
if [ -z "$CTBL" ] || [ -z "$PTBL" ]; then
  echo "FAIL: geen transaction_id-tabel gevonden (consumer='${CTBL:-?}', provider='${PTBL:-?}')." >&2
  [ -s "$ERRLOG" ] && echo "  psql-fout: $(tail -n1 "$ERRLOG")" >&2
  exit 1
fi

elapsed=0; CORR=""
while [ "$elapsed" -lt "$TXLOG_TIMEOUT" ]; do
  # transaction_id's die in BEIDE txlogs voorkomen (= gecorreleerde end-to-end transactie).
  CIDS=$(psqltx "$TXDB_CONSUMER" "SELECT DISTINCT transaction_id FROM ${CTBL};" | sort -u || true)
  PIDS=$(psqltx "$TXDB_PROVIDER" "SELECT DISTINCT transaction_id FROM ${PTBL};" | sort -u || true)
  CORR=$(comm -12 <(printf '%s\n' "$CIDS") <(printf '%s\n' "$PIDS") | grep -v '^$' | head -n1 || true)
  [ -n "$CORR" ] && break
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog geen gecorreleerde transaction_id in beide txlogs (${elapsed}s)"
done

if [ -n "$CORR" ]; then
  echo "OK: Fsc-Transaction-Id $CORR gelogd bij zowel outway (out) als inway (in)."
  echo "SMOKE-E2E GROEN."
  exit 0
fi

echo "FAIL: geen gedeelde transaction_id in consumer- en provider-txlog binnen ${TXLOG_TIMEOUT}s." >&2
echo "  consumer-txlog (${CTBL}):" >&2; psqltx "$TXDB_CONSUMER" "SELECT transaction_id, direction FROM ${CTBL} LIMIT 10;" >&2 || true
echo "  provider-txlog (${PTBL}):" >&2; psqltx "$TXDB_PROVIDER" "SELECT transaction_id, direction FROM ${PTBL} LIMIT 10;" >&2 || true
"${COMPOSE[@]}" logs --tail=40 txlog-example-consumer txlog-example-provider >&2 || true
exit 1
