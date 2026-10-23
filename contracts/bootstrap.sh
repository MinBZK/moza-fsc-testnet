#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Contract-bootstrap: zet idempotent een geldig, wederzijds ondertekend
# ServiceConnectionGrant-contract op tussen een consumer en een provider.
#
# Stroom (OpenFSC Manager Internal-API, bewezen patroon uit deploy/local/publish-service.sh):
#   1. bereken de outway-GROUP-public-key-thumbprint (SPKI SHA-256 hex);
#   2. idempotentie: zoek in de contractenlijst van de CONSUMER-manager het contract van precies
#      deze combinatie (service, provider, consumer-outway, thumbprint):
#        - geldig en door de provider getekend -> no-op (overtollige duplicaten intrekken);
#        - ingediend maar nog niet geldig       -> dát contract afmaken, geen nieuwe indienen;
#        - niets                                -> nieuw contract indienen (stap 3);
#   3. POST /v1/contracts (contract_content) op de EIGEN (consumer-)manager -> die tekent
#      server-side namens de consumer en synct het contract via de mesh naar de provider;
#   4. poll de provider-manager tot het contract (op hash) gesynct is, dan
#      PUT /v1/contracts/{hash}/accept op de PROVIDER-manager (overgeslagen als die al getekend heeft);
#   5. wacht tot de consumer-manager het contract als 'valid' ziet (anders her-distributie forceren);
#   6. best-effort (non-fataal): token-probe als bonus-signaal.
#
# WAAROM GEEN STATE-FILE: een deploy start met een lege schijf, dus een onthouden hash is daar elke
# run weg en elke run maakte er een contract bij. Het bestaan volgt nu uit de contracten zelf.
# WAAROM DE CONSUMER-KANT: daar resolvet de outway de grant, en `valid_contracts` eist beide
# accept-handtekeningen in díe database. Op de provider kan het contract al VALID zijn terwijl de
# push van de provider-handtekening naar de consumer gestrand is; dat is dan geen "bestaand
# contract" maar een her-distributie.
# WAAROM DE VOLLEDIGE COMBINATIE: op beide managers staat ook het servicePublication-contract voor
# dezelfde dienst. Matchen op alleen servicenaam/OIN zou dat altijd laten meetellen (false green).
#
# Check en POST zijn niet atomair: twee gelijktijdige runs kunnen elk een contract indienen. Dat is
# zonder gedeeld lock niet te voorkomen, wel te herstellen: de volgende run trekt de overtollige in.
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

# shellcheck source-path=SCRIPTDIR source=contracten.sh
. "${HERE}/contracten.sh"

# --- Parameters (defaults = example-peers; override via env voor andere peers) --------------
CONSUMER_OIN="${CONSUMER_OIN:-00000000000000000020}"
PROVIDER_OIN="${PROVIDER_OIN:-00000000000000000030}"
SERVICE_NAME="${SERVICE_NAME:-example-service}"
GROUP_ID="${GROUP_ID:-moza-fbs-test}"

# Outway-GROUP-cert (host-pad): hiervan de public-key-thumbprint voor de grant (zie
# outway_thumbprint in contracten.sh voor waarom het group-cert).
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

# Volledige contractenlijst (alle pagina's) van een manager; surfacet een fout i.p.v. 'm te slikken.
consumer_contracts() {
  contracten_paginas cons "$CONSUMER_MANAGER/v1/contracts?limit=1000" || {
    echo "FAIL: contractenlijst van de consumer-manager niet op te halen: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2
    return 1; }
}
provider_contracts() {
  contracten_paginas prov "$PROVIDER_MANAGER/v1/contracts?limit=1000" || {
    echo "FAIL: contractenlijst van de provider-manager niet op te halen: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2
    return 1; }
}

# Contracten van deze combinatie op de consumer-manager, als regels uit contract_voor_combinatie.
eigen_contracten() {
  local json; json=$(consumer_contracts) || return 1
  contract_voor_combinatie "$json" "$SERVICE_NAME" "$PROVIDER_OIN" "$CONSUMER_OIN" "$THUMB" || {
    echo "FAIL: contractenlijst van de consumer-manager niet te lezen." >&2; return 1; }
}

# Echoot "ontbreekt" | "open" | "getekend": hoe staat contract $1 op de provider-manager?
provider_status() {
  local json; json=$(provider_contracts) || return 1
  printf '%s' "$json" | jq -r --arg h "$1" --arg oin "$PROVIDER_OIN" '
    [.contracts[] | objects | select(.hash == $h)] as $c
    | if ($c | length) == 0 then "ontbreekt"
      elif ($c | any((.signatures.accept // {}) | has($oin))) then "getekend"
      else "open" end'
}

# --- 0. Host-dependencies + outway-public-key-thumbprint -------------------------------------
# jq is hier geen optie maar de idempotentie zelf: zonder het uitlezen van de contract-JSON zou
# elke run een nieuw contract indienen in plaats van het bestaande te herkennen.
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq niet gevonden op de host (zie deploy/local/README.md)." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "FAIL: openssl niet gevonden op de host (zie pki/README.md)." >&2; exit 1; }
[ -r "$OUTWAY_CERT_HOST" ] || { echo "FAIL: outway-cert niet leesbaar: $OUTWAY_CERT_HOST (draai pki/issue.sh?)" >&2; exit 1; }
THUMB=$(outway_thumbprint "$OUTWAY_CERT_HOST") \
  || { echo "FAIL: kon outway-public-key-thumbprint niet berekenen uit $OUTWAY_CERT_HOST." >&2; exit 1; }
echo "bootstrap: outway public-key-thumbprint = $THUMB"

# --- 1. Idempotentie: staat er al een contract voor deze combinatie? -------------------------
REGELS=$(eigen_contracten) || exit 1
GELDIG=$(geldige_contracten "$REGELS")

if [ -n "$GELDIG" ]; then
  HASH=$(printf '%s\n' "$GELDIG" | head -n1)
  echo "OK: geldig contract $HASH voor $SERVICE_NAME ($CONSUMER_OIN -> $PROVIDER_OIN) bestaat al."

  # Duplicaten (gelijktijdige runs) zijn functioneel inwisselbaar; houd de gesorteerd-eerste aan
  # zodat de keuze stabiel is over runs heen, en trek de rest in.
  DUPS=$(printf '%s\n' "$GELDIG" | tail -n +2)
  if [ -n "$DUPS" ]; then
    echo "  $(printf '%s\n' "$DUPS" | grep -c .) overtollig(e) contract(en) voor dezelfde combinatie; intrekken..."
    while IFS= read -r dup; do
      # </dev/null: `compose exec` leest anders de rest van de duplicatenlijst van stdin op.
      cons -X PUT "$CONSUMER_MANAGER/v1/contracts/$dup/revoke" -H 'Content-Type: application/json' </dev/null >/dev/null \
        || { echo "FAIL: kon duplicaat $dup niet intrekken: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }
      echo "  ingetrokken: $dup"
    done <<<"$DUPS"
  fi

  echo "BOOTSTRAP OK (bestaand contract)."; exit 0
fi

# Een afgewezen contract maken we niet af: dat is het antwoord van de provider. Een eerder
# ingediend, nog lopend contract wél — een nieuw indienen zou er een tweede naast zetten.
if printf '%s' "$REGELS" | awk '$4 == "afgewezen" { f = 1 } END { exit !f }'; then
  echo "WARN: de provider heeft minstens één contract voor deze combinatie afgewezen:" >&2
  printf '%s\n' "$REGELS" | awk '$4 == "afgewezen"' | sed 's/^/  /' >&2
fi
HASH=$(printf '%s' "$REGELS" | awk '$4 == "-" { print $1; exit }')

if [ -n "$HASH" ]; then
  echo "bootstrap: eerder ingediend contract $HASH is nog niet geldig; dat contract afmaken."
else
  # --- 2. Contract opstellen + indienen bij de eigen (consumer-)manager -----------------------
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
  # Het `outway`-blok is sinds OpenFSC v2.0.0 een union: de outway wordt geïdentificeerd op
  # public-key-thumbprint óf op domeinnaam, met `type` als discriminator. De platte v1-vorm
  # (`outway.public_key_thumbprint`) wordt niet meer geaccepteerd. Wij houden het thumbprint aan
  # (stabiel bij cert-rotatie binnen hetzelfde sleutelpaar).
  # `fsc_version` zetten we NIET zelf: de POST neemt `createContractContent`, waar dat veld ontbreekt
  # — de manager vult 'm en neemt 'm mee in de content-hash.
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
  HASH=$(printf '%s' "$RESP" | jq -r '.content_hash // empty' 2>/dev/null) || HASH=""
  [ -n "$HASH" ] || { echo "FAIL: contract-respons zonder content_hash (formaat geweigerd?): $RESP" >&2; exit 1; }
  echo "  consumer-handtekening gezet (2xx); mesh-sync gestart; content_hash=$HASH"
fi

# --- 3. Provider laat het contract accepteren -------------------------------------------------
echo "bootstrap: wachten tot het contract naar de provider-manager gesynct is..."
elapsed=0
while :; do
  PSTAT=$(provider_status "$HASH") || exit 1
  [ "$PSTAT" = ontbreekt ] || break
  [ "$elapsed" -lt "$SYNC_TIMEOUT" ] || { echo "FAIL: contract $HASH niet gesynct naar de provider binnen ${SYNC_TIMEOUT}s." >&2
    "${COMPOSE[@]}" logs --tail=50 manager-example-consumer manager-example-provider >&2 || true; exit 1; }
  sleep "$SYNC_INTERVAL"; elapsed=$((elapsed + SYNC_INTERVAL))
  echo "  ...nog niet gesynct (${elapsed}s)"
done

if [ "$PSTAT" = getekend ]; then
  # Een eerdere run kwam tot hier; alleen de push naar de consumer ontbreekt nog (stap 4).
  echo "  provider heeft contract $HASH al getekend."
else
  echo "bootstrap: provider accepteert (PUT .../accept)..."
  prov -X PUT "$PROVIDER_MANAGER/v1/contracts/$HASH/accept" -H 'Content-Type: application/json' >/dev/null \
    || { echo "FAIL: PUT accept ($HASH) geweigerd: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }
  echo "  provider-handtekening gezet (2xx)."
fi

# --- 4. Wacht tot de CONSUMER-manager het contract als 'valid' ziet ---------------------------
# contracts.valid_contracts (bron: OpenFSC migratie 011) eist BEIDE accept-sigs fysiek in de
# consumer-DB. De provider-accept-sig wordt async/best-effort naar de consumer gepusht (bounded
# backoff, GÉÉN cron-retry); landt die niet, dan blijft het contract 'proposed' op de consumer en
# ziet de outway 'm nooit (grant_links: []). Dus pollen we op state=valid en forceren we anders de
# provider-side her-distributie (het canonieke herstel voor een gestrande failed_distribution).
consumer_valid() {  # 0=valid, 1=nog niet; een onleesbare lijst is fataal, geen "nog niet"
  local regels; regels=$(eigen_contracten) || exit 1
  geldige_contracten "$regels" | grep -qxF "$HASH"
}
wait_valid() {  # pollt de consumer tot valid; 0=valid, 1=timeout
  local elapsed=0
  while [ "$elapsed" -lt "$SYNC_TIMEOUT" ]; do
    consumer_valid && return 0
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
if wait_valid; then
  echo "OK: contract $HASH is 'valid' op de consumer-manager (wederzijds ondertekend)."
else
  redistribute_accept
  if ! wait_valid; then
    echo "FAIL: contract $HASH werd niet 'valid' op de consumer-manager (provider-accept-sig niet gesynct)." >&2
    "${COMPOSE[@]}" logs --tail=60 manager-example-provider manager-example-consumer >&2 || true
    exit 1
  fi
  echo "OK: contract $HASH is 'valid' op de consumer-manager (na her-distributie)."
fi

# --- 5. Best-effort token (bonus; echte afdwinging + logging volgen als vervolgwerk) ----------
# LET OP: FSC's /token verwacht scope=<GRANT-hash> (de `gth`-claim), niet de contract-content_hash.
# We hebben alleen de content_hash, dus een NIET-200 is hier VERWACHT — geen rode vlag. De echte,
# grant-hash-gebonden token haalt de outway native op tijdens egress (canonicalisatie +
# SHA3-512 over enkel het grant-object is versiegevoelig; daarom hier niet nagebouwd).
echo "bootstrap: (best-effort) token-probe — een niet-200 is verwacht (scope=content_hash); echte token volgt later."
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
echo "  token-endpoint HTTP-status: ${TOK:-<geen>} (niet-200 verwacht; grant-hash-token volgt later)."
[ "${TOK:-}" = "200" ] || { [ -s "$ERRLOG" ] && echo "  (info) token-diagnostiek: $(tail -n1 "$ERRLOG")" >&2; }

echo "BOOTSTRAP OK."
