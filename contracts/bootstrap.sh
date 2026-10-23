#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Contract-bootstrap: zet idempotent een geldig, wederzijds ondertekend
# ServiceConnectionGrant-contract op tussen een consumer en een provider. Werking, en waarom het
# bestaan uit de contracten zelf volgt i.p.v. uit een state-bestand: zie contracts/bootstrap.md.
#
# Stroom (OpenFSC Manager Internal-API, bewezen patroon uit deploy/local/publish-service.sh):
#   0. bereken de outway-GROUP-public-key-thumbprint (SPKI SHA-256 hex);
#   1. zoek op de CONSUMER-manager het contract van deze combinatie:
#        - geldig                  -> no-op; overtollige duplicaten intrekken;
#        - ingediend, niet geldig  -> dát contract afmaken (stap 3), geen nieuwe indienen;
#        - afgewezen/ingetrokken   -> stoppen, tenzij OPNIEUW_INDIENEN=1;
#        - niets                   -> stap 2;
#   2. POST /v1/contracts op de EIGEN (consumer-)manager -> die tekent server-side namens de
#      consumer en synct het contract via de mesh naar de provider;
#   3. wacht tot het contract op de provider-manager staat, dan PUT .../accept daar (overgeslagen
#      als de provider al getekend heeft);
#   4. wacht tot de consumer-manager het contract als 'valid' ziet (anders her-distributie);
#   5. best-effort (non-fataal): token-probe als bonus-signaal.
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

# Outway-GROUP-cert (host-pad): hiervan de public-key-thumbprint voor de grant.
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

# Alleen voor diagnose en de token-probe; per peer anders, dus ook te overrulen.
LOG_SERVICES="${LOG_SERVICES:-manager-example-consumer manager-example-provider}"
OUTWAY_CERT="${OUTWAY_CERT:-/pki/out/example-consumer/outway/cert.pem}"
OUTWAY_KEY="${OUTWAY_KEY:-/pki/out/example-consumer/outway/key.pem}"
GROUP_CA="${GROUP_CA:-/pki/ca/root.pem}"
PROVIDER_TOKEN_URL="${PROVIDER_TOKEN_URL:-https://example-provider.fsc-test.local:443/token}"
# Een tikfout mag geen hot loop (interval 0) of een `[`-fout die als "timeout" leest opleveren.
for v in SYNC_TIMEOUT SYNC_INTERVAL; do
  case "${!v}" in ""|*[!0-9]*|0) echo "FAIL: $v moet een positief geheel getal zijn, niet '${!v}'." >&2; exit 1 ;; esac
done

# Vang toolbox-/curl-stderr op i.p.v. weg te gooien: een mTLS-/netwerk-/dode-container-fout mag
# niet als "nog niet klaar" maskeren (spiegelt publish-service.sh). Surface 'm op de FAIL-paden.
ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT
laatste_fout() { tail -n1 "$ERRLOG" 2>/dev/null; }
# shellcheck disable=SC2086  # LOG_SERVICES is een spaties-gescheiden lijst servicenamen.
manager_logs() { "${COMPOSE[@]}" logs --tail="$1" $LOG_SERVICES >&2 </dev/null || true; }

# curl in de toolbox met het opgegeven client-cert. $1=cert $2=key $3=ca, rest = curl-args.
# </dev/null: `compose exec` leest anders stdin van de aanroeper leeg (bv. een while-read-lus).
# Timeouts: een manager die de verbinding aanneemt maar niet antwoordt, mag SYNC_TIMEOUT niet
# tot schijnveiligheid maken.
tb() { local c="$1" k="$2" a="$3"; shift 3
       "${COMPOSE[@]}" exec -T toolbox curl -sS --fail-with-body --connect-timeout 10 --max-time 30 \
         --cert "$c" --key "$k" --cacert "$a" "$@" </dev/null 2>"$ERRLOG"; }

cons() { tb "$CONSUMER_CERT" "$CONSUMER_KEY" "$CONSUMER_CA" "$@"; }
prov() { tb "$PROVIDER_CERT" "$PROVIDER_KEY" "$PROVIDER_CA" "$@"; }

# Contracten van deze combinatie op de consumer-manager, als regels uit contract_voor_combinatie.
# Server-side filter op grant-type houdt publicatie- en andere contracten buiten de lijst.
eigen_contracten() {
  local json
  json=$(contracten_paginas cons "$CONSUMER_MANAGER/v1/contracts?limit=1000&grant_type=GRANT_TYPE_SERVICE_CONNECTION") || {
    echo "FAIL: contractenlijst van de consumer-manager niet op te halen: $(laatste_fout)" >&2; return 1; }
  contract_voor_combinatie "$json" "$SERVICE_NAME" "$PROVIDER_OIN" "$CONSUMER_OIN" "$THUMB" || {
    echo "FAIL: contractenlijst van de consumer-manager niet te lezen." >&2; return 1; }
}

# Echoot "ontbreekt" | "open" | "getekend" | "beeindigd": hoe staat contract $1 op de provider?
# Eén GET, niet gepagineerd: het content_hash-filter negeert cursor en limit maar zet wél een
# cursor, dus doorlezen zou dezelfde rij eindeloos blijven ophalen.
provider_status() {
  local json
  json=$(prov "$PROVIDER_MANAGER/v1/contracts?content_hash=$(printf '%s' "$1" | jq -sRr @uri)") || {
    echo "FAIL: contract $1 niet op te vragen bij de provider-manager: ${json:0:300} $(laatste_fout)" >&2; return 1; }
  printf '%s' "$json" | jq -er --arg h "$1" --arg oin "$PROVIDER_OIN" '
    if (.contracts | type) != "array" then error("geen contractenlijst") else . end
    | [.contracts[] | objects | select(.hash == $h)] as $c
    | ($c | map((.state // "") | ascii_downcase)) as $st
    | if ($c | length) == 0 then "ontbreekt"
      elif ($st | any(. == "contract_state_rejected" or . == "contract_state_revoked" or . == "contract_state_expired")) then "beeindigd"
      elif ($c | any((.signatures.accept // {}) | has($oin))) then "getekend"
      else "open" end' || { echo "FAIL: antwoord van de provider-manager is geen contractenlijst: ${json:0:300}" >&2; return 1; }
}

# intrekken <hash...>: trekt elk contract in op de consumer-manager; telt mislukkingen en gaat door,
# zodat één weigerend contract de rest niet laat staan.
intrekken() {
  local h fouten=0
  for h in "$@"; do
    if cons -X PUT "$CONSUMER_MANAGER/v1/contracts/$h/revoke" -H 'Content-Type: application/json' >/dev/null; then
      echo "  ingetrokken: $h"
    # OpenFSC slaat de intrekking eerst lokaal op en pusht daarna; faalt de push, dan ziet een
    # volgende run het contract niet meer en blijft het bij de provider geldig. Daarom hier al
    # de her-distributie.
    elif cons -X PUT "$CONSUMER_MANAGER/v1/contracts/$h/distributions/$PROVIDER_OIN/DISTRIBUTION_ACTION_SUBMIT_REVOKE_SIGNATURE/retry" \
           -H 'Content-Type: application/json' >/dev/null; then
      echo "  ingetrokken (push naar de provider via her-distributie): $h"
    else
      echo "  FAIL: kon $h niet intrekken (mogelijk lokaal wel, push naar de provider faalde): $(laatste_fout)" >&2
      fouten=$((fouten + 1))
    fi
  done
  [ "$fouten" -eq 0 ]
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
LOPEND=$(lopende_contracten "$REGELS")
BEEINDIGD=$(beeindigde_contracten "$REGELS")

# Een state die we niet kennen (of die ontbreekt) is geen "nog niet klaar": dat zou eeuwig
# wachten op iets dat er al staat, of er stil een tweede naast zetten.
ONBEKEND=$(onbekende_contracten "$REGELS")
[ -z "$ONBEKEND" ] || { echo "FAIL: contract(en) voor deze combinatie met onverwachte state:" >&2
  printf '%s\n' "$ONBEKEND" | sed 's/^/  /' >&2; exit 1; }

if [ -n "$GELDIG" ]; then
  HASH=$(printf '%s\n' "$GELDIG" | head -n1)
  echo "OK: geldig contract $HASH voor $SERVICE_NAME ($CONSUMER_OIN -> $PROVIDER_OIN) bestaat al."

  # Check en POST zijn niet atomair: gelijktijdige runs kunnen elk indienen. Zonder gedeeld lock
  # niet te voorkomen, wel te herstellen: het oudste blijft, de overige geldige én lopende gaan eruit.
  OVERIG=$({ printf '%s\n' "$GELDIG" | tail -n +2; printf '%s\n' "$LOPEND"; } | grep -v '^$' | grep -vxF "$HASH" || true)
  if [ -n "$OVERIG" ]; then
    echo "  $(printf '%s\n' "$OVERIG" | grep -c .) overtollig(e) contract(en) voor dezelfde combinatie; intrekken..."
    # Ongequote splitsing: FSC-hashes bevatten geen witruimte of glob-tekens (hash_ok-vorm), en
    # mapfile ontbreekt in bash 3.2 (macOS).
    # shellcheck disable=SC2086
    intrekken $OVERIG || { echo "FAIL: niet alle overtollige contracten zijn ingetrokken." >&2; exit 1; }
  fi

  echo "BOOTSTRAP OK (bestaand contract)."; exit 0
fi

if [ -n "$LOPEND" ]; then
  HASH=$(printf '%s\n' "$LOPEND" | head -n1)
  echo "bootstrap: eerder ingediend contract $HASH is nog niet geldig; dat contract afmaken."
  # Door de provider voorgesteld (bv. via de controller-UI): dan ontbreekt ónze handtekening, en
  # zonder die wordt het nooit geldig. Het is precies de combinatie die we willen, dus tekenen.
  if ! consumer_getekend "$REGELS" "$HASH"; then
    echo "bootstrap: contract $HASH mist de consumer-handtekening; consumer accepteert..."
    cons -X PUT "$CONSUMER_MANAGER/v1/contracts/$HASH/accept" -H 'Content-Type: application/json' >/dev/null \
      || { echo "FAIL: consumer-accept ($HASH) mislukt: $(laatste_fout)" >&2; exit 1; }
  fi
elif [ -n "$BEEINDIGD" ] && [ "${OPNIEUW_INDIENEN:-0}" != 1 ]; then
  # Afwijzen of intrekken is een besluit van een van beide peers; de bootstrap draait dat niet
  # stil terug door een nieuw contract in te dienen en dat zelf als provider te tekenen.
  echo "FAIL: het contract voor deze combinatie is afgewezen of door de andere peer ingetrokken:" >&2
  printf '%s\n' "$REGELS" | awk '$2 == "contract_state_rejected" || $2 == "contract_state_revoked"' | sed 's/^/  /' >&2
  echo "  Los de oorzaak op en draai opnieuw met OPNIEUW_INDIENEN=1 om een nieuw contract in te dienen." >&2
  exit 1
else
  # --- 2. Contract opstellen + indienen bij de eigen (consumer-)manager -----------------------
  # UUID v4: /proc is Linux-only, op macOS valt 'ie terug op uuidgen (lowercase).
  IV=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  # Docker Desktop (macOS) draait in een VM waarvan de klok op de host kan achterlopen; de manager
  # weigert dan created_at "in the future" (HTTP 500). Backdate met een skew-marge — op Linux is de
  # skew ~0, dus onschadelijk. Blijft persistent falen? Herstart de Docker-VM (klok resynct).
  NBF=$(( $(date -u +%s) - 60 ))
  NAF=$((NBF + 315360000))                 # +10 jaar
  # De connection-grant's `service` VEREIST de discriminator `type: SERVICE_TYPE_SERVICE` (anders
  # 500 "invalid service type"; de publicatie-grant defaultte 'm, de connection-grant niet). Géén
  # `protocol` (dat hoort bij de service-PUBLICATIE, niet bij de connection).
  # Het `outway`-blok is sinds OpenFSC v2.0.0 een union met `type` als discriminator; de platte
  # v1-vorm (`outway.public_key_thumbprint`) wordt niet meer geaccepteerd. Wij houden het thumbprint
  # aan (stabiel bij cert-rotatie binnen hetzelfde sleutelpaar).
  # `fsc_version` zetten we NIET zelf: de POST neemt `createContractContent`, waar dat veld ontbreekt
  # — de manager vult 'm en neemt 'm mee in de content-hash.
  BODY=$(jq -cn --arg iv "$IV" --arg group "$GROUP_ID" --argjson nbf "$NBF" --argjson naf "$NAF" \
           --arg prov "$PROVIDER_OIN" --arg svc "$SERVICE_NAME" --arg cons "$CONSUMER_OIN" --arg thumb "$THUMB" '
    { contract_content: {
        iv: $iv, group_id: $group, hash_algorithm: "HASH_ALGORITHM_SHA3_512", created_at: $nbf,
        validity: { not_before: ($nbf - 60), not_after: $naf },
        grants: [ {
          type: "GRANT_TYPE_SERVICE_CONNECTION",
          service: { type: "SERVICE_TYPE_SERVICE", peer_id: $prov, name: $svc },
          outway: { peer_id: $cons, identification: {
            type: "OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT", public_key_thumbprint: $thumb } } } ] } }')

  echo "bootstrap: serviceConnection-contract indienen bij de consumer-manager..."
  RESP=$(cons -X POST "$CONSUMER_MANAGER/v1/contracts" -H 'Content-Type: application/json' -d "$BODY") \
    || { echo "FAIL: POST /v1/contracts geweigerd: ${RESP:-<leeg>} $(laatste_fout)" >&2; exit 1; }

  # --fail-with-body vangt HTTP-4xx/5xx; een 2xx zónder content_hash duidt op een geweigerd formaat.
  # Het hash gaat hierna URL-paden in, dus alleen in de FSC-vorm.
  HASH=$(printf '%s' "$RESP" | jq -r '.content_hash // empty' 2>/dev/null) || HASH=""
  hash_ok "$HASH" || { echo "FAIL: contract-respons zonder bruikbare content_hash: $RESP" >&2; exit 1; }
  echo "  consumer-handtekening gezet (2xx); mesh-sync gestart; content_hash=$HASH"
fi

# --- 3. Provider laat het contract accepteren -------------------------------------------------
# wacht_op_provider: pollt tot het contract op de provider staat; 0=er, 1=timeout. Zet PSTAT.
wacht_op_provider() {
  local elapsed=0
  while :; do
    PSTAT=$(provider_status "$HASH") || exit 1
    [ "$PSTAT" = ontbreekt ] || return 0
    [ "$elapsed" -lt "$SYNC_TIMEOUT" ] || return 1
    sleep "$SYNC_INTERVAL"; elapsed=$((elapsed + SYNC_INTERVAL))
    echo "  ...nog niet gesynct (${elapsed}s)"
  done
}

echo "bootstrap: wachten tot het contract naar de provider-manager gesynct is..."
if ! wacht_op_provider; then
  # Een hervat contract kan gestrand zijn in de distributie naar de provider; zonder herstel zou
  # elke run op hetzelfde contract blijven hangen.
  echo "bootstrap: forceer consumer-side her-distributie van het contract naar de provider..."
  cons -X PUT "$CONSUMER_MANAGER/v1/contracts/$HASH/distributions/$PROVIDER_OIN/DISTRIBUTION_ACTION_SUBMIT_CONTRACT/retry" \
    -H 'Content-Type: application/json' >/dev/null \
    || echo "  WARN: retry-call fout (mogelijk geen gestrande distributie): $(laatste_fout)" >&2
  wacht_op_provider || { echo "FAIL: contract $HASH niet gesynct naar de provider binnen ${SYNC_TIMEOUT}s (ook na her-distributie)." >&2
    manager_logs 50; exit 1; }
fi

case "$PSTAT" in
  beeindigd)
    # Op de provider afgewezen, ingetrokken of verlopen, ook als dat de consumer nog niet bereikte.
    # OpenFSC's accept kent geen state-controle, dus doorgaan zou een dood contract tekenen.
    echo "FAIL: contract $HASH is op de provider-manager afgewezen, ingetrokken of verlopen." >&2; exit 1 ;;
  getekend)
    # Een eerdere run kwam tot hier; alleen de push naar de consumer ontbreekt nog (stap 4).
    echo "  provider heeft contract $HASH al getekend." ;;
  *)
    echo "bootstrap: provider accepteert (PUT .../accept)..."
    prov -X PUT "$PROVIDER_MANAGER/v1/contracts/$HASH/accept" -H 'Content-Type: application/json' >/dev/null \
      || { echo "FAIL: PUT accept ($HASH) mislukt (mogelijk lokaal gezet, push faalde; de volgende run hervat): $(laatste_fout)" >&2; exit 1; }
    echo "  provider-handtekening gezet (2xx)." ;;
esac

# --- 4. Wacht tot de CONSUMER-manager het contract als 'valid' ziet ---------------------------
# 'valid' (OpenFSC ContractStateService) eist BEIDE accept-sigs fysiek in de consumer-DB. De provider-accept-sig wordt async/best-effort naar de consumer gepusht (bounded
# backoff, GÉÉN cron-retry); landt die niet, dan blijft het contract 'proposed' op de consumer en
# ziet de outway 'm nooit (grant_links: []). Dus pollen we op state=valid en forceren we anders de
# provider-side her-distributie (het canonieke herstel voor een gestrande failed_distribution).
consumer_valid() {  # 0=valid, 1=nog niet; onleesbaar, verdwenen of beëindigd is fataal
  local regels st
  regels=$(eigen_contracten) || exit 1
  st=$(printf '%s\n' "$regels" | awk -v h="$HASH" '$1 == h { print $2; exit }')
  case "$st" in
    "") echo "FAIL: contract $HASH staat niet (meer) op de consumer-manager (ingetrokken of verlopen?)." >&2; exit 1 ;;
    contract_state_rejected|contract_state_revoked)
        echo "FAIL: contract $HASH is tijdens het wachten afgewezen of ingetrokken ($st)." >&2; exit 1 ;;
  esac
  geldige_contracten "$regels" | grep -qxF "$HASH"
}
wait_valid() {  # pollt de consumer tot valid, ook ná de laatste sleep; 0=valid, 1=timeout
  local elapsed=0
  while :; do
    consumer_valid && return 0
    [ "$elapsed" -lt "$SYNC_TIMEOUT" ] || return 1
    sleep "$SYNC_INTERVAL"; elapsed=$((elapsed + SYNC_INTERVAL))
    echo "  ...contract nog niet 'valid' op de consumer (${elapsed}s)"
  done
}
redistribute_accept() {  # her-push de provider-accept-sig naar de consumer (idempotent, best-effort)
  echo "bootstrap: forceer provider-side her-distributie van de accept-sig naar de consumer..."
  prov -X PUT "$PROVIDER_MANAGER/v1/contracts/$HASH/distributions/$CONSUMER_OIN/DISTRIBUTION_ACTION_SUBMIT_ACCEPT_SIGNATURE/retry" \
    -H 'Content-Type: application/json' >/dev/null \
    || echo "  WARN: retry-call fout (mogelijk geen gestrande distributie): $(laatste_fout)" >&2
}

echo "bootstrap: wachten tot de consumer-manager het contract '$HASH' als 'valid' ziet..."
if wait_valid; then
  echo "OK: contract $HASH is 'valid' op de consumer-manager (wederzijds ondertekend)."
else
  redistribute_accept
  if ! wait_valid; then
    echo "FAIL: contract $HASH werd niet 'valid' op de consumer-manager (provider-accept-sig niet gesynct)." >&2
    manager_logs 60
    exit 1
  fi
  echo "OK: contract $HASH is 'valid' op de consumer-manager (na her-distributie)."
fi

# --- 5. Best-effort token-probe (bonus; de afdwinging bewijst smoke-e2e.sh) -------------------
# LET OP: FSC's /token verwacht scope=<GRANT-hash> (de `gth`-claim), niet de contract-content_hash.
# Een NIET-200 is hier dus VERWACHT — geen rode vlag. De echte, grant-hash-gebonden token haalt de
# outway native op tijdens egress.
echo "bootstrap: (best-effort) token-probe — een niet-200 is verwacht (scope=content_hash)."
: >"$ERRLOG"
TOK=$("${COMPOSE[@]}" exec -T toolbox curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
        --cert "$OUTWAY_CERT" --key "$OUTWAY_KEY" --cacert "$GROUP_CA" \
        -X POST "$PROVIDER_TOKEN_URL" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "scope=$HASH" \
        --data-urlencode "client_id=$CONSUMER_OIN" </dev/null 2>"$ERRLOG" || true)
echo "  token-endpoint HTTP-status: ${TOK:-<geen>} (niet-200 verwacht; zie smoke-e2e.sh voor de echte token)."
[ "${TOK:-}" = "200" ] || { [ -s "$ERRLOG" ] && echo "  (info) token-diagnostiek: $(laatste_fout)" >&2; }

echo "BOOTSTRAP OK."
