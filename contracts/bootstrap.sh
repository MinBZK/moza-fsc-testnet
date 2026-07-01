#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Contract-bootstrap (#727): zet idempotent een geldig, wederzijds ondertekend
# ServiceConnectionGrant-contract op tussen een consumer en een provider.
#
# Stroom (OpenFSC Manager Internal-API, bewezen patroon uit deploy/local/publish-service.sh):
#   1. bereken de outway-group-public-key-thumbprint (SPKI SHA-256 hex);
#   2. idempotentie: bestaat er al een geaccepteerd serviceConnection-contract voor deze
#      (service, outway)? -> no-op;
#   3. POST /v1/contracts (contract_content) op de EIGEN (consumer-)manager -> die tekent
#      server-side namens de consumer en synct het contract via de mesh naar de provider;
#   4. poll de provider-manager tot het contract (op content_hash) gesynct is, dan
#      PUT /v1/contracts/{hash}/accept op de PROVIDER-manager -> provider-handtekening.
#   5. best-effort (non-fataal): token-fetch als bonus-signaal. Harde token-afdwinging +
#      transactie-logging = #728 (de outway haalt tokens native op tijdens egress).
#
# De provider tekent NIET automatisch: AUTO_SIGN_GRANTS dekt alleen (delegated)servicePublication,
# dus de serviceConnection-accept is een expliciete PUT (zie docs/.../contract-bootstrap-design.md).
#
# Generiek: alles is via env te overrulen (defaults = de example-peers). Draai vanuit de repo-root
# ná `docker compose up` + `publish-service.sh` (de dienst moet bestaan om op te contracteren).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
COMPOSE=(docker compose -f "${REPO_ROOT}/deploy/local/docker-compose.yaml")

# --- Parameters (defaults = example-peers; override via env voor andere peers) --------------
CONSUMER_OIN="${CONSUMER_OIN:-00000000000000000020}"
PROVIDER_OIN="${PROVIDER_OIN:-00000000000000000030}"
SERVICE_NAME="${SERVICE_NAME:-example-service}"
GROUP_ID="${GROUP_ID:-moza-fbs-test}"

# Outway-group-cert (host-pad): hiervan de public-key-thumbprint. De outway presenteert dit cert
# naar de provider-inway; de thumbprint bindt het contract aan de sleutel (stabiel bij cert-rotatie).
OUTWAY_CERT_HOST="${OUTWAY_CERT_HOST:-${REPO_ROOT}/pki/out/example-consumer/outway/cert.pem}"

# Consumer-manager (indienen) + provider-manager (accepteren): Internal-API :9443, internal-certs.
CONSUMER_MANAGER="${CONSUMER_MANAGER:-https://manager.example-consumer.fsc-test.local:9443}"
CONSUMER_CERT="${CONSUMER_CERT:-/pki/internal/example-consumer/manager/cert.pem}"
CONSUMER_KEY="${CONSUMER_KEY:-/pki/internal/example-consumer/manager/key.pem}"
CONSUMER_CA="${CONSUMER_CA:-/pki/internal/example-consumer/ca/root.pem}"

PROVIDER_MANAGER="${PROVIDER_MANAGER:-https://manager.example-provider.fsc-test.local:9443}"
PROVIDER_CERT="${PROVIDER_CERT:-/pki/internal/example-provider/manager/cert.pem}"
PROVIDER_KEY="${PROVIDER_KEY:-/pki/internal/example-provider/manager/key.pem}"
PROVIDER_CA="${PROVIDER_CA:-/pki/internal/example-provider/ca/root.pem}"

SYNC_TIMEOUT="${SYNC_TIMEOUT:-60}"; SYNC_INTERVAL="${SYNC_INTERVAL:-3}"

# Vang toolbox-/curl-stderr op i.p.v. weg te gooien: een mTLS-/netwerk-/dode-container-fout mag
# niet als "nog niet klaar" maskeren (spiegelt publish-service.sh). Surface 'm op de FAIL-paden.
ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

# curl in de toolbox met het opgegeven client-cert. $1=cert $2=key $3=ca, rest = curl-args.
tb() { local c="$1" k="$2" a="$3"; shift 3
       "${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
         --cert "$c" --key "$k" --cacert "$a" "$@" 2>"$ERRLOG"; }

cons() { tb "$CONSUMER_CERT" "$CONSUMER_KEY" "$CONSUMER_CA" "$@"; }
prov() { tb "$PROVIDER_CERT" "$PROVIDER_KEY" "$PROVIDER_CA" "$@"; }

# --- 0. Outway-public-key-thumbprint (host-side openssl; de toolbox heeft geen openssl-CLI) ----
command -v openssl >/dev/null 2>&1 || { echo "FAIL: openssl niet gevonden op de host (zie pki/README.md)." >&2; exit 1; }
[ -r "$OUTWAY_CERT_HOST" ] || { echo "FAIL: outway-cert niet leesbaar: $OUTWAY_CERT_HOST (draai pki/issue.sh?)" >&2; exit 1; }
THUMB=$(openssl x509 -in "$OUTWAY_CERT_HOST" -pubkey -noout \
          | openssl pkey -pubin -outform DER \
          | openssl dgst -sha256 -r | cut -d' ' -f1) || THUMB=""
case "$THUMB" in
  [0-9a-f]*) [ "${#THUMB}" -eq 64 ] || { echo "FAIL: thumbprint geen 64 hex-tekens: '$THUMB'" >&2; exit 1; } ;;
  *) echo "FAIL: kon outway-public-key-thumbprint niet berekenen uit $OUTWAY_CERT_HOST." >&2; exit 1 ;;
esac
echo "bootstrap: outway public-key-thumbprint = $THUMB"

# --- 1. Idempotentie: bestaat er al een geaccepteerd serviceConnection-contract? --------------
# Een geaccepteerd contract bevat de thumbprint + servicenaam ÉN een provider-accept-signature.
# We greppen (geen jq in de toolbox); het POST-antwoord levert later de exacte hash voor de accept.
echo "bootstrap: bestaand contract checken op de provider-manager..."
EXISTING=$(prov "$PROVIDER_MANAGER/v1/contracts" || true)
if [ -s "$ERRLOG" ]; then echo "  WARN: contracts-GET-fout: $(tail -n1 "$ERRLOG")" >&2; : >"$ERRLOG"; fi
if printf '%s' "$EXISTING" | grep -q "$THUMB" \
   && printf '%s' "$EXISTING" | grep -q "\"$SERVICE_NAME\"" \
   && printf '%s' "$EXISTING" | grep -q '"accept"'; then
  echo "OK: er is al een serviceConnection-contract met deze outway + dienst (idempotent, skip)."
  echo "BOOTSTRAP OK (bestaand contract)."
  exit 0
fi

# --- 2. Contract opstellen + indienen bij de eigen (consumer-)manager -------------------------
IV=$(cat /proc/sys/kernel/random/uuid)   # UUID v4; bij 400 op iv-formaat -> UUID v7 genereren
NBF=$(date -u +%s)
NAF=$((NBF + 315360000))                 # +10 jaar
echo "bootstrap: serviceConnection-contract indienen bij de consumer-manager..."
RESP=$(cons -X POST "$CONSUMER_MANAGER/v1/contracts" -H 'Content-Type: application/json' -d "{
  \"contract_content\": {
    \"iv\": \"$IV\",
    \"group_id\": \"$GROUP_ID\",
    \"hash_algorithm\": \"HASH_ALGORITHM_SHA3_512\",
    \"created_at\": $NBF,
    \"validity\": { \"not_before\": $((NBF - 60)), \"not_after\": $NAF },
    \"grants\": [ {
      \"type\": \"GRANT_TYPE_SERVICE_CONNECTION\",
      \"service\": { \"peer_id\": \"$PROVIDER_OIN\", \"name\": \"$SERVICE_NAME\" },
      \"outway\": {
        \"peer_id\": \"$CONSUMER_OIN\",
        \"identification\": {
          \"type\": \"OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT\",
          \"public_key_thumbprint\": \"$THUMB\"
        }
      }
    } ]
  }
}") || { echo "FAIL: POST /v1/contracts geweigerd: ${RESP:-<leeg>} $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }

# --fail-with-body vangt HTTP-4xx/5xx; een 2xx zónder content_hash duidt op een geweigerd formaat
# (bv. service dat toch een protocol eist, of een afwijkend outway-blok). Surface de respons.
HASH=$(printf '%s' "$RESP" | grep -o '"content_hash"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]*"' \
        | head -n1 | grep -o '[0-9a-fA-F]\{16,\}' | head -n1 || true)
[ -n "$HASH" ] || { echo "FAIL: contract-respons zonder content_hash (formaat geweigerd?): $RESP" >&2; exit 1; }
echo "  consumer-handtekening gezet + gesynct; content_hash=$HASH"

# --- 3. Provider laat het contract accepteren -------------------------------------------------
echo "bootstrap: wachten tot het contract naar de provider-manager gesynct is..."
elapsed=0; synced=0
while [ "$elapsed" -lt "$SYNC_TIMEOUT" ]; do
  if prov "$PROVIDER_MANAGER/v1/contracts" | grep -q "$HASH"; then synced=1; break; fi
  [ -s "$ERRLOG" ] && { echo "  WARN: poll-fout: $(tail -n1 "$ERRLOG")" >&2; : >"$ERRLOG"; }
  sleep "$SYNC_INTERVAL"; elapsed=$((elapsed + SYNC_INTERVAL))
  echo "  ...nog niet gesynct (${elapsed}s)"
done
[ "$synced" -eq 1 ] || { echo "FAIL: contract $HASH niet gesynct naar de provider binnen ${SYNC_TIMEOUT}s." >&2
  "${COMPOSE[@]}" logs --tail=50 manager-example-consumer manager-example-provider >&2 || true; exit 1; }

echo "bootstrap: provider accepteert (PUT .../accept)..."
prov -X PUT "$PROVIDER_MANAGER/v1/contracts/$HASH/accept" -H 'Content-Type: application/json' \
  || { echo "FAIL: PUT accept geweigerd: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }
echo "  provider-handtekening gezet."

# --- 4. Verifieer: wederzijds ondertekend (accept-signatures van beide OIN's) ------------------
FINAL=$(prov "$PROVIDER_MANAGER/v1/contracts" || true)
if printf '%s' "$FINAL" | grep -q "$CONSUMER_OIN" && printf '%s' "$FINAL" | grep -q "$PROVIDER_OIN" \
   && printf '%s' "$FINAL" | grep -q '"accept"'; then
  echo "OK: wederzijds ondertekend serviceConnection-contract ($CONSUMER_OIN <-> $PROVIDER_OIN)."
else
  echo "WARN: kon de wederzijdse accept-signatures niet bevestigen in de respons; check handmatig:" >&2
  printf '%s\n' "$FINAL" >&2
fi

# --- 5. Best-effort token (bonus; echte afdwinging + logging = #728) --------------------------
echo "bootstrap: (best-effort) token-fetch als bonus-signaal — echte afdwinging is #728."
TOK=$("${COMPOSE[@]}" exec -T toolbox curl -s -o /dev/null -w '%{http_code}' \
        --cert /pki/out/example-consumer/outway/cert.pem \
        --key  /pki/out/example-consumer/outway/key.pem \
        --cacert /pki/ca/root.pem \
        -X POST "https://example-provider.fsc-test.local:443/token" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "scope=$HASH" \
        --data-urlencode "client_id=$CONSUMER_OIN" 2>/dev/null || true)
echo "  token-endpoint HTTP-status: ${TOK:-<geen>} (200 = bonus; anders → outway doet dit native in #728)."

echo "BOOTSTRAP OK."
