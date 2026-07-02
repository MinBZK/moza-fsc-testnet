#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Contract-bootstrap (#727): zet idempotent een geldig, wederzijds ondertekend
# ServiceConnectionGrant-contract op tussen een consumer en een provider.
#
# Stroom (OpenFSC Manager Internal-API, bewezen patroon uit deploy/local/publish-service.sh):
#   1. bereken de outway-GROUP-public-key-thumbprint (SPKI SHA-256 hex);
#   2. idempotentie: draagt een eerder geaccepteerd contract (state-file-hash) NOG de
#      provider-accept op de provider? -> no-op;
#   3. POST /v1/contracts (contract_content) op de EIGEN (consumer-)manager -> die tekent
#      server-side namens de consumer (2xx + content_hash = consumer-handtekening) en synct
#      het contract via de mesh naar de provider;
#   4. poll de provider-manager tot het contract (op content_hash) gesynct is, dan
#      PUT /v1/contracts/{hash}/accept op de PROVIDER-manager (2xx = provider-handtekening);
#   5. verifieer onafhankelijk (re-GET provider-lijst) dat ons contract nu de provider-accept
#      draagt (accept-STAAT via jq, niet blote aanwezigheid);
#   6. best-effort (non-fataal): token-probe als bonus-signaal. Harde token-afdwinging +
#      transactie-logging = #728 (de outway haalt tokens native op tijdens egress).
#
# WAAROM 2xx-gating + accept-STAAT i.p.v. de contractenlijst grepppen: op de provider-manager staat
# óók het auto-geaccepteerde servicePublication-contract voor dezelfde `example-service`. Een losse
# grep op servicenaam/OIN/"accept" over de hele lijst matcht dus altijd (false green); en blote
# aanwezigheid van de content_hash bewijst geen accept (de consumer stelt 't contract zélf op).
# Daarom:
#   - consumer-handtekening  = POST gaf 2xx + content_hash;
#   - provider-handtekening  = PUT .../accept gaf 2xx (scoped op exact die hash);
#   - idempotentie/verify     = jq accept-STAAT-check (signatures.accept bevat de provider-OIN),
#     gescoped op de GLOBAAL UNIEKE content_hash. Zonder jq: fallback op aanwezigheid (de PUT-2xx
#     bewees de accept dan al).
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

# Outway-GROUP-cert (host-pad): hiervan de public-key-thumbprint voor de grant. BEVESTIGD via de
# OpenFSC-source: de outway registreert bij zijn controller met zijn GROUP-cert (externalCert) en
# stuurt datzelfde group-thumbprint (externalCert.PublicKeyThumbprint()) naar GetOutwayServices; de
# manager matcht dat tegen gsc.outway_public_key_thumbprint. Dus het GROUP-cert, niet het internal.
# Thumbprint = SPKI-SHA256-hex van de publieke sleutel (stabiel bij cert-rotatie).
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

SYNC_TIMEOUT="${SYNC_TIMEOUT:-10}"; SYNC_INTERVAL="${SYNC_INTERVAL:-2}"

# State-file: content_hash van een eerder succesvol geaccepteerd contract. Bron van waarheid voor
# idempotentie (gitignored; hash is niet-geheim maar host-lokaal). Zie contracts/.bootstrap-state/.
STATE_DIR="${STATE_DIR:-${REPO_ROOT}/contracts/.bootstrap-state}"
STATE_FILE="${STATE_DIR}/${CONSUMER_OIN}-${PROVIDER_OIN}-${SERVICE_NAME}.hash"

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

# Haalt de contractenlijst van de provider-manager op; surfacet een GET-fout i.p.v. 'm te slikken.
provider_contracts() {
  local out; out=$(prov "$PROVIDER_MANAGER/v1/contracts") || {
    echo "  WARN: GET /v1/contracts (provider) faalde: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; : >"$ERRLOG"; }
  printf '%s' "$out"
}

# jq (host-side) laat ons de accept-STAAT checken i.p.v. blote hash-aanwezigheid: de consumer
# heeft het contract zélf opgesteld, dus de content_hash staat in de lijst vanaf creatie —
# aanwezigheid bewijst dus géén provider-accept. Alleen een provider-handtekening onder
# signatures.accept doet dat. jq is een bestaande repo-dependency (deploy/zad/upsert-directory.sh).
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# Echoot "yes" | "no" | "unknown": draagt het contract met content_hash $2 een accept-handtekening
# van OIN $3? Shape-tolerant (recursieve `..`; content_hash op top-niveau óf onder .content).
# Faalt bewust NAAR "unknown" (i.p.v. "no") bij twijfel, zodat een afwijkende JSON-vorm nooit een
# al-geaccepteerd contract ten onrechte afkeurt (de PUT-2xx bewees de accept al):
#   - contract niet gevonden op deze hash        -> unknown (val terug op aanwezigheid)
#   - geen herkenbaar signatures.accept-object   -> unknown (vorm wijkt af)
#   - accept-object bevat provider-OIN           -> yes
#   - accept-object aanwezig, zónder provider-OIN -> no  (échte pending/afgewezen -> opnieuw opzetten)
# "unknown" ook als jq ontbreekt. In dit gesloten testnet volstaat de aanwezigheids-fallback.
accept_state() {  # $1=json $2=content_hash $3=oin
  [ "$HAVE_JQ" -eq 1 ] || { echo unknown; return; }
  printf '%s' "$1" | jq -r --arg h "$2" --arg oin "$3" '
    [.. | objects | select((.hash? // .content_hash? // .content?.content_hash?) == $h)] as $c
    | if ($c | length) == 0 then "unknown"
      elif ([ $c[] | .signatures?.accept? | objects ] | length) == 0 then "unknown"
      elif ($c | any((.signatures?.accept? // {}) | has($oin))) then "yes"
      else "no" end' 2>/dev/null || echo unknown
}

# Echoot de lifecycle-state (lowercased) van het contract met content_hash $2, of "unknown".
# valid_contracts eist dat de state 'valid' is (beide accept-sigs fysiek in DÍT manager's DB).
contract_state() {  # $1=json $2=content_hash
  [ "$HAVE_JQ" -eq 1 ] || { echo unknown; return; }
  printf '%s' "$1" | jq -r --arg h "$2" '
    [.. | objects | select((.hash? // .content_hash? // .content?.content_hash?) == $h) | .state?]
    | map(select(. != null)) | (first // "unknown") | ascii_downcase' 2>/dev/null || echo unknown
}

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

# --- 1. Idempotentie: is een eerder geaccepteerd contract (state-file-hash) NOG geaccepteerd? -----
# Scoped op de GLOBAAL UNIEKE content_hash. We checken de accept-STAAT (niet blote aanwezigheid):
# een ge-revoke't/afgewezen contract staat óók nog in de lijst, dus presence != geaccepteerd.
if [ -f "$STATE_FILE" ]; then
  SAVED=$(cat "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$SAVED" ]; then
    LIST=$(provider_contracts)
    case "$(accept_state "$LIST" "$SAVED" "$PROVIDER_OIN")" in
      yes)
        echo "OK: eerder geaccepteerd contract $SAVED draagt nog de provider-accept (idempotent, skip)."
        echo "BOOTSTRAP OK (bestaand contract)."; exit 0 ;;
      unknown)
        # Geen jq (of afwijkende JSON-vorm): val terug op aanwezigheid. De state-file wordt pas ná
        # een geslaagde accept geschreven, dus in dit gesloten testnet (geen revoke-pad) volstaat dat.
        if printf '%s' "$LIST" | grep -qF "$SAVED"; then
          echo "OK: eerder geaccepteerd contract $SAVED nog aanwezig (idempotent, skip; jq afwezig → geen staat-check)."
          echo "BOOTSTRAP OK (bestaand contract)."; exit 0
        fi ;;
      no) echo "bootstrap: state-file-contract $SAVED draagt geen provider-accept meer." ;;
    esac
  fi
  echo "bootstrap: geen bruikbaar bestaand contract — opnieuw opzetten."
fi

# --- 2. Contract opstellen + indienen bij de eigen (consumer-)manager -------------------------
# UUID v4: /proc is Linux-only, op macOS valt 'ie terug op uuidgen (lowercase).
# Bij 400 op iv-formaat -> UUID v7 genereren.
IV=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
# Docker Desktop (macOS) draait in een VM waarvan de klok op de host kan achterlopen; de manager
# weigert dan created_at "in the future" (HTTP 500). Backdate met een skew-marge — op Linux is de
# skew ~0, dus onschadelijk. Blijft persistent falen? Herstart de Docker-VM (klok resynct).
NBF=$(( $(date -u +%s) - 60 ))
NAF=$((NBF + 315360000))                 # +10 jaar
# De connection-grant's `service` VEREIST de discriminator `type: SERVICE_TYPE_SERVICE` (anders
# 500 "invalid service type"; de publicatie-grant defaultte 'm, de connection-grant niet). Géén
# `protocol` (dat hoort bij de service-PUBLICATIE, niet bij de connection).
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
      \"service\": { \"type\": \"SERVICE_TYPE_SERVICE\", \"peer_id\": \"$PROVIDER_OIN\", \"name\": \"$SERVICE_NAME\" },
      \"outway\": {
        \"peer_id\": \"$CONSUMER_OIN\",
        \"public_key_thumbprint\": \"$THUMB\"
      }
    } ]
  }
}") || { echo "FAIL: POST /v1/contracts geweigerd: ${RESP:-<leeg>} $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }

# --fail-with-body vangt HTTP-4xx/5xx; een 2xx zónder content_hash duidt op een geweigerd formaat
# (bv. service dat toch een protocol eist, of een afwijkend outway-blok). Surface de respons.
# De content_hash is GÉÉN hex maar het crypt-stijl SHA3-512-formaat `$1$<n>$<base64url>` (zoals
# smoke-publish's respons); pak dus de volledige JSON-stringwaarde (geen `"` erin) i.p.v. hex.
HASH=$(printf '%s' "$RESP" | sed -n 's/.*"content_hash"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
[ -n "$HASH" ] || { echo "FAIL: contract-respons zonder content_hash (formaat geweigerd?): $RESP" >&2; exit 1; }
echo "  consumer-handtekening gezet (2xx); mesh-sync gestart; content_hash=$HASH"

# --- 3. Provider laat het contract accepteren -------------------------------------------------
echo "bootstrap: wachten tot het contract naar de provider-manager gesynct is..."
elapsed=0; synced=0
while [ "$elapsed" -lt "$SYNC_TIMEOUT" ]; do
  if printf '%s' "$(provider_contracts)" | grep -qF "$HASH"; then synced=1; break; fi
  sleep "$SYNC_INTERVAL"; elapsed=$((elapsed + SYNC_INTERVAL))
  echo "  ...nog niet gesynct (${elapsed}s)"
done
[ "$synced" -eq 1 ] || { echo "FAIL: contract $HASH niet gesynct naar de provider binnen ${SYNC_TIMEOUT}s." >&2
  "${COMPOSE[@]}" logs --tail=50 manager-example-consumer manager-example-provider >&2 || true; exit 1; }

echo "bootstrap: provider accepteert (PUT .../accept)..."
prov -X PUT "$PROVIDER_MANAGER/v1/contracts/$HASH/accept" -H 'Content-Type: application/json' \
  || { echo "FAIL: PUT accept ($HASH) geweigerd: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }
echo "  provider-handtekening gezet (2xx)."

# --- 4. Wacht tot de CONSUMER-manager het contract als 'valid' ziet ---------------------------
# contracts.valid_contracts (bron: OpenFSC migratie 011) eist BEIDE accept-sigs fysiek in de
# consumer-DB. De provider-accept-sig wordt async/best-effort naar de consumer gepusht (bounded
# backoff, GÉÉN cron-retry); landt die niet, dan blijft het contract 'proposed' op de consumer en
# ziet de outway 'm nooit (grant_links: []). Dus pollen we op state=valid en forceren we anders de
# provider-side her-distributie (het canonieke herstel voor een gestrande failed_distribution).
consumer_valid() {  # 0=valid, 1=nog niet, 2=onbekend (geen jq)
  local st; st=$(contract_state "$(cons "$CONSUMER_MANAGER/v1/contracts" || true)" "$HASH")
  case "$st" in valid|contract_state_valid) return 0 ;; unknown) return 2 ;; *) return 1 ;; esac
}
wait_valid() {  # pollt de consumer tot valid; 0=valid, 1=timeout, 2=onbekend (geen jq)
  local elapsed=0 rc
  while [ "$elapsed" -lt "$SYNC_TIMEOUT" ]; do
    rc=0; consumer_valid || rc=$?   # niet `consumer_valid; rc=$?` -> set -e killt bij non-zero
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 2 ] && return 2
    sleep "$SYNC_INTERVAL"; elapsed=$((elapsed + SYNC_INTERVAL))
    echo "  ...contract nog niet 'valid' op de consumer (${elapsed}s)"
  done
  return 1
}
redistribute_accept() {  # her-push de provider-accept-sig naar de consumer (idempotent, best-effort)
  echo "bootstrap: forceer provider-side her-distributie van de accept-sig naar de consumer..."
  prov -X POST "$PROVIDER_MANAGER/v1/contracts/$HASH/distributions/$CONSUMER_OIN/DISTRIBUTION_ACTION_SUBMIT_ACCEPT_SIGNATURE/retry" \
    -H 'Content-Type: application/json' >/dev/null \
    || echo "  WARN: retry-call fout (mogelijk geen gestrande distributie): $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2
}

echo "bootstrap: wachten tot de consumer-manager het contract '$HASH' als 'valid' ziet..."
wv=0; wait_valid || wv=$?   # niet `wait_valid; wv=$?` -> set -e killt bij non-zero return
if [ "$wv" -eq 2 ]; then
  # Geen jq op de host -> kan de state niet lezen. Forceer één her-distributie zodat de accept-sig
  # zeker naar de consumer gaat, en ga door (installeer jq voor een harde valid-verificatie).
  echo "WARN: kan contract-state niet lezen (geen jq, of onbekende JSON-vorm) → forceer her-distributie. Installeer jq / check de contract-shape voor een harde verificatie." >&2
  redistribute_accept
elif [ "$wv" -ne 0 ]; then
  # Wel jq, maar niet valid binnen de timeout -> gestrande push. Her-distribueer en poll opnieuw.
  redistribute_accept
  if ! wait_valid; then
    echo "FAIL: contract $HASH werd niet 'valid' op de consumer-manager (provider-accept-sig niet gesynct)." >&2
    "${COMPOSE[@]}" logs --tail=60 manager-example-provider manager-example-consumer >&2 || true
    exit 1
  fi
  echo "OK: contract $HASH is 'valid' op de consumer-manager (na her-distributie)."
else
  echo "OK: contract $HASH is 'valid' op de consumer-manager (wederzijds ondertekend)."
fi

# State-file pas NA succesvolle accept schrijven (bron van waarheid voor idempotentie).
mkdir -p "$STATE_DIR" && printf '%s\n' "$HASH" > "$STATE_FILE"

# --- 5. Best-effort token (bonus; echte afdwinging + logging = #728) --------------------------
# LET OP: FSC's /token verwacht scope=<GRANT-hash> (de `gth`-claim), niet de contract-content_hash.
# We hebben alleen de content_hash, dus een NIET-200 is hier VERWACHT — geen rode vlag. De echte,
# grant-hash-gebonden token haalt de outway native op tijdens egress in #728 (canonicalisatie +
# SHA3-512 over enkel het grant-object is versiegevoelig; daarom hier niet nagebouwd).
echo "bootstrap: (best-effort) token-probe — een niet-200 is verwacht (scope=content_hash); echte token = #728."
: >"$ERRLOG"
TOK=$("${COMPOSE[@]}" exec -T toolbox curl -s -o /dev/null -w '%{http_code}' \
        --cert /pki/out/example-consumer/outway/cert.pem \
        --key  /pki/out/example-consumer/outway/key.pem \
        --cacert /pki/ca/root.pem \
        -X POST "https://example-provider.fsc-test.local:443/token" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "scope=$HASH" \
        --data-urlencode "client_id=$CONSUMER_OIN" 2>"$ERRLOG" || true)
echo "  token-endpoint HTTP-status: ${TOK:-<geen>} (niet-200 verwacht; grant-hash-token = #728)."
[ "${TOK:-}" = "200" ] || { [ -s "$ERRLOG" ] && echo "  (info) token-diagnostiek: $(tail -n1 "$ERRLOG")" >&2; }

echo "BOOTSTRAP OK."
