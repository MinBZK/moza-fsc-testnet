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
export LC_ALL=C   # pin de sort/comm-ordening (correlatie leunt op consistente `comm`-invoer)

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
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
DISCOVER_TIMEOUT="${DISCOVER_TIMEOUT:-10}"; TXLOG_TIMEOUT="${TXLOG_TIMEOUT:-10}"; INTERVAL=2

ERRLOG=$(mktemp); trap 'rm -f "$ERRLOG"' EXIT

# curl in de toolbox (plain HTTP naar de outway; geen cert nodig voor de app->outway-hop).
tbx() { "${COMPOSE[@]}" exec -T toolbox curl -s "$@" 2>"$ERRLOG"; }
# psql tegen een txlog-DB (stderr -> ERRLOG zodat een DB-fout niet als "geen rijen" maskeert).
psqltx() { "${COMPOSE[@]}" exec -T postgres psql -U postgres -d "$1" -tA -c "$2" 2>>"$ERRLOG"; }
surface_err() { [ -s "$ERRLOG" ] && { echo "  -> laatste fout: $(tail -n1 "$ERRLOG")" >&2; }; return 0; }

# --- 0. Contract garanderen (idempotent) ------------------------------------------------------
echo "smoke-e2e: contract garanderen (bootstrap, idempotent)..."
bash "${REPO_ROOT}/contracts/bootstrap.sh"

# --- 1. Grant-hash ontdekken via de outway-suggestie (pollt tot de outway het contract kent) --
# Zonder geldige Fsc-Grant-Hash geeft de outway (met ENABLE_GRANT_HASH_SUGGESTION) de bruikbare
# grant-hash(es) terug. Grant-hash-formaat: `$1$<n>$<base64url>` (zie open-fsc walkthrough).
# `-i` neemt de headers mee, mocht de outway de suggestie in een header i.p.v. de body zetten.
echo "smoke-e2e: grant-hash ontdekken via de outway (max ${DISCOVER_TIMEOUT}s; grant-links-cache-TTL=5s)..."
GH=""; elapsed=0
while [ "$elapsed" -lt "$DISCOVER_TIMEOUT" ]; do
  SUGG=$(tbx -i "$OUTWAY/" -H 'Fsc-Grant-Hash: discover' || true)
  # shellcheck disable=SC2016  # de `$1$<n>$...` is het letterlijke grant-hash-formaat, geen var.
  # head -n1: aanname = de consumer heeft precies één contract/grant (example-service). Bij meerdere
  # zou een verkeerde gekozen kunnen worden -> stap 3 faalt dan op de 200/stub-check (geen false green).
  GH=$(printf '%s' "$SUGG" | grep -oE '\$1\$[0-9]+\$[A-Za-z0-9_/+=-]{20,}' | head -n1 || true)
  [ -n "$GH" ] && break
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...outway kent de grant nog niet (${elapsed}s)"
done
if [ -z "$GH" ]; then
  echo "FAIL: geen grant-hash uit de outway-suggestie binnen ${DISCOVER_TIMEOUT}s." >&2
  echo "  Laatste outway-respons:" >&2; printf '%s\n' "${SUGG:-<leeg>}" >&2
  surface_err
  "${COMPOSE[@]}" logs --tail=50 outway-example-consumer manager-example-consumer >&2 || true
  exit 1
fi
echo "  grant-hash = $GH"

# --- 2. txlog-tabellen resolven + baseline (vóór de call) -------------------------------------
# Schema-agnostisch: de tabel met een `transaction_id`-kolom (zoals smoke-discover de services-tabel).
# We nemen een baseline van bestaande out-transacties in de consumer-txlog, zodat we in stap 4
# alléén de transactie van DEZE call correleren (de txlog-volumes zijn persistent -> anders
# false-green op een gedeelde id uit een eerdere run).
find_tx_table() {  # $1=db ; echoot "schema.table" met een transaction_id-kolom
  psqltx "$1" "SELECT format('%I.%I', table_schema, table_name)
               FROM information_schema.columns
               WHERE column_name = 'transaction_id' AND table_schema NOT IN ('pg_catalog','information_schema')
               ORDER BY table_schema LIMIT 1;" | head -n1
}
# Exacte direction-encoding-lijst i.p.v. een substring-LIKE: `%in%` zou óók `outgoing` matchen
# (out-g-o-i-n-g bevat "in"). Dek de plausibele fsc-logging-encodings af; wijkt v1.43.7 af, dan
# faalt de correlatie luid (FAIL-dump toont de echte direction-waarden) — nooit stil groen.
OUT_PRED="lower(direction::text) IN ('out','outgoing','outbound','direction_out')"
IN_PRED="lower(direction::text) IN ('in','incoming','inbound','direction_in')"
CTBL=$(find_tx_table "$TXDB_CONSUMER" || true)
PTBL=$(find_tx_table "$TXDB_PROVIDER" || true)
if [ -z "$CTBL" ] || [ -z "$PTBL" ]; then
  echo "FAIL: geen transaction_id-tabel gevonden (consumer='${CTBL:-?}', provider='${PTBL:-?}')." >&2
  surface_err; exit 1
fi
# Baseline hard valideren: een stil-gefaalde (leeg-gemaskeerde) baseline zou in stap 5 ELKE
# bestaande out-id als "nieuw" tellen -> false green op een oude id uit een eerdere run.
: >"$ERRLOG"
BASELINE=$(psqltx "$TXDB_CONSUMER" "SELECT transaction_id FROM ${CTBL} WHERE ${OUT_PRED};" | sort -u || true)
[ -s "$ERRLOG" ] && { echo "FAIL: baseline-query (consumer-txlog) faalde — correlatie niet betrouwbaar." >&2; surface_err; exit 1; }

# --- 3. Positieve data-call: consumer -> outway -> inway -> stub -> terug ----------------------
echo "smoke-e2e: data-call via de outway (verwacht 200 + stub-echo)..."
BODY=$(tbx -o - -w '\n%{http_code}' "$OUTWAY/" -H "Fsc-Grant-Hash: $GH" || true)
CODE=$(printf '%s' "$BODY" | tail -n1)
PAYLOAD=$(printf '%s' "$BODY" | sed '$d')
if [ "$CODE" = "200" ] && printf '%s' "$PAYLOAD" | grep -qF "$STUB_MARKER"; then
  echo "OK: data-call geslaagd (200) en stub-echo ontvangen: $(printf '%s' "$PAYLOAD" | head -n1)"
else
  echo "FAIL: data-call niet geslaagd (HTTP ${CODE:-<geen>}); verwacht 200 + \"$STUB_MARKER\"." >&2
  printf '  respons: %s\n' "$PAYLOAD" >&2; surface_err
  "${COMPOSE[@]}" logs --tail=60 outway-example-consumer inway-example-provider stub-upstream >&2 || true
  exit 1
fi

# --- 4. Token-afdwinging: directe inway-call ZONDER token -> 401 -------------------------------
# We omzeilen de outway en spreken de inway direct aan (group-mTLS, maar géén Fsc-Authorization).
# De inway hoort dit te weigeren met 401 ERROR_CODE_ACCESS_TOKEN_MISSING. `-i` -> we greppen zowel
# de Fsc-Error-Code-header als de body; eis 401 ÉN de marker (niet OR — een kale 401 uit een andere
# oorzaak mag geen token-afdwinging voorwenden).
echo "smoke-e2e: token-afdwinging (directe inway-call zonder token, verwacht 401 + ACCESS_TOKEN_MISSING)..."
NEG=$("${COMPOSE[@]}" exec -T toolbox curl -s -i -w '\n%{http_code}' \
        --cert "$GCERT" --key "$GKEY" --cacert "$GROOT" "$INWAY/" 2>"$ERRLOG" || true)
NCODE=$(printf '%s' "$NEG" | tail -n1)
if [ "$NCODE" = "401" ] && printf '%s' "$NEG" | grep -qi 'ACCESS_TOKEN_MISSING'; then
  echo "OK: inway weigert zonder token (HTTP 401 + ERROR_CODE_ACCESS_TOKEN_MISSING)."
else
  echo "FAIL: verwacht 401 MÉT ERROR_CODE_ACCESS_TOKEN_MISSING (kreeg HTTP ${NCODE:-<geen>})." >&2
  printf '%s\n' "$NEG" >&2; surface_err
  exit 1
fi

# --- 5. Verantwoording: DEZELFDE Fsc-Transaction-Id bij outway (out) én inway (in) -------------
# De transactie van stap 3 = de NIEUWE out-id in de consumer-txlog (t.o.v. de baseline). Die id
# moet óók in de provider-txlog staan mét direction=in. Het direction-predicaat sluit uit dat een
# gedeelde id uit de token-/mesh-uitwisseling (managers dragen óók TX_LOG_API_ADDRESS) als
# data-plane-correlatie telt.
echo "smoke-e2e: transactie-correlatie (nieuwe out-id ook als in-id bij de provider)..."
elapsed=0; CORR=""
while [ "$elapsed" -lt "$TXLOG_TIMEOUT" ]; do
  NOW=$(psqltx "$TXDB_CONSUMER" "SELECT transaction_id FROM ${CTBL} WHERE ${OUT_PRED};" | sort -u || true)
  NEW=$(comm -13 <(printf '%s\n' "$BASELINE") <(printf '%s\n' "$NOW") | grep -v '^$' || true)
  for id in $NEW; do
    # Guard: alleen UUID-vormige id's in de query (defensief tegen een rare waarde met quote/glob).
    case "$id" in *[!0-9a-fA-F-]*|"") continue ;; esac
    HIT=$(psqltx "$TXDB_PROVIDER" "SELECT 1 FROM ${PTBL} WHERE transaction_id = '${id}' AND ${IN_PRED} LIMIT 1;" || true)
    if [ "$HIT" = "1" ]; then CORR="$id"; break; fi
  done
  [ -n "$CORR" ] && break
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog geen gecorreleerde transactie (${elapsed}s)"
done

if [ -n "$CORR" ]; then
  echo "OK: Fsc-Transaction-Id $CORR gelogd bij outway (direction out) én inway (direction in)."
  echo "SMOKE-E2E GROEN."
  exit 0
fi

echo "FAIL: de nieuwe out-transactie is niet als in-transactie bij de provider gecorreleerd binnen ${TXLOG_TIMEOUT}s." >&2
surface_err
echo "  nieuwe consumer-out-id's t.o.v. baseline: ${NEW:-<geen>}" >&2
echo "  consumer-txlog (${CTBL}):" >&2; psqltx "$TXDB_CONSUMER" "SELECT transaction_id, direction FROM ${CTBL} LIMIT 10;" >&2 || true
echo "  provider-txlog (${PTBL}):" >&2; psqltx "$TXDB_PROVIDER" "SELECT transaction_id, direction FROM ${PTBL} LIMIT 10;" >&2 || true
"${COMPOSE[@]}" logs --tail=40 txlog-example-consumer txlog-example-provider >&2 || true
exit 1
