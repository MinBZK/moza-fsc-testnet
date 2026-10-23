#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Regressietest voor de beslislogica van contracts/bootstrap.sh, zonder draaiende managers: een
# nep-`docker` vooraan op PATH speelt beide managers na op twee JSON-bestanden en logt elke call.
# Bewijst o.a. "drie runs op een lege omgeving = één contract" en dat duplicaten, lopende,
# gestrande, afgewezen en ingetrokken contracten de juiste afslag nemen.
#
# De stub volgt OpenFSC v2.7.0 waar dat het gedrag bepaalt: routering op host met het cert dat
# bij die manager hoort, een cursor op élke pagina met rijen, een content_hash-filter dat de cursor
# negeert maar er wel een zet, state 'valid' alleen met beide handtekeningen, en een POST die het
# contract eerst opslaat en pas daarna naar de provider pusht.
# FSC-hashes (`$1$<n>$…`) zijn letterlijke tekst, geen variabelen:
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Vast testcert (zelfde vector als contracten.test.sh); de bootstrap leidt hier de thumbprint uit af.
THUMB=edfa32b765fccd82aae11dcf3319b12e504508a866f65aceffb1a954946b520f
cat >"$TMP/outway.pem" <<'PEM'
-----BEGIN CERTIFICATE-----
MIIBljCCAT2gAwIBAgIUcFBoUnMtl6PtY59T3vjqVyyAnaIwCgYIKoZIzj0EAwIw
IDEeMBwGA1UEAwwVdGh1bWJwcmludC10ZXN0dmVjdG9yMCAXDTI2MTAyMzA2MDg1
MFoYDzIxMjYwOTI5MDYwODUwWjAgMR4wHAYDVQQDDBV0aHVtYnByaW50LXRlc3R2
ZWN0b3IwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASwE37mC3nKq/aS3z+T4QWi
V1HyDCNR6KE8GRvKcuSQ1Jybjhm/H8Y8h+w3KJ7PNiRmL2aMnShDzYIfdXfSpCqW
o1MwUTAdBgNVHQ4EFgQUBH2jzJPugUbmnRSqDRZwAgExC84wHwYDVR0jBBgwFoAU
BH2jzJPugUbmnRSqDRZwAgExC84wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQD
AgNHADBEAiBn0bvlMxxkUjjdMKj+hk/p5rOm1kG4hX/wJkq83NVs3gIgcmz0/sQ2
otlGU3hOr2uKKll2NXFo1omnCuJglI+6zZo=
-----END CERTIFICATE-----
PEM

# --- Nep-docker: `docker compose … exec -T toolbox curl …` en `docker compose … logs …` --------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null || true   # zoals compose exec: stdin wordt gelezen
for a in "$@"; do [ "$a" = logs ] && exit 0; done
while [ "$1" != curl ]; do shift; done; shift

cert="" methode=GET url="" body="" token=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cert) cert="$2"; shift 2 ;;
    -X) methode="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -w) token=1; shift 2 ;;
    -H|--key|--cacert|-o|--data-urlencode|--connect-timeout|--max-time) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$token" -eq 0 ] || { printf 404; exit 0; }

host="${url#https://}"; host="${host%%/*}"
case "$host" in
  "$S_CONS_HOST") zijde=cons; eigen="$S_CONS"; ander="$S_PROV"; ander_zijde=prov; verwacht="$S_CONS_CERT" ;;
  "$S_PROV_HOST") zijde=prov; eigen="$S_PROV"; ander="$S_CONS"; ander_zijde=cons; verwacht="$S_PROV_CERT" ;;
  *) echo "stub: onbekende host $host" >&2; exit 6 ;;
esac
# Een cert dat niet bij deze manager hoort, haalt de mTLS-handshake niet.
[ "$cert" = "$verwacht" ] || { echo "stub: cert $cert hoort niet bij $host" >&2; exit 35; }

pad="/${url#https://*/}"; query=""; case "$pad" in *\?*) query="${pad#*\?}" ;; esac; pad="${pad%%\?*}"
echo "$zijde $methode $pad" >>"$STUB/calls.log"
db="$STUB/$zijde.json"
param() { local v; v=$(printf '%s' "&$query" | sed -n "s/.*&$1=\([^&]*\).*/\1/p"); printf '%b' "${v//%/\\x}"; }

# zet <bestand> <jq-filter> [args…]: herschrijf een managerdatabase.
zet() { local f="$1"; shift; jq "$@" "$f" >"$f.nieuw" && mv "$f.nieuw" "$f"; }
# teken <bestand> <hash> <oin>: handtekening erbij; 'valid' pas met beide (OpenFSC ContractStateService).
teken() {
  zet "$1" --arg h "$2" --arg oin "$3" --arg a "$S_CONS" --arg b "$S_PROV" '
    map(if .hash == $h then (.signatures.accept[$oin] = {}
        | if .state == "CONTRACT_STATE_PROPOSED" and (.signatures.accept | has($a) and has($b))
          then .state = "CONTRACT_STATE_VALID" else . end) else . end)'
}
hash_uit_pad() { local h="${pad#/v1/contracts/}"; printf '%s' "${h%%/*}"; }

case "$methode $pad" in
  "GET /v1/contracts")
    [ "$zijde" != cons ] || [ "${STUB_CONS_KAPOT:-0}" != 1 ] || { printf '<html>502</html>'; exit 22; }
    ch=$(param content_hash)
    if [ -n "$ch" ]; then
      # OpenFSC: dit filter negeert cursor en limit, maar zet wel een cursor als er rijen zijn.
      jq -c --arg h "$ch" 'map(select(.hash == $h)) | {contracts: ., pagination: {next_cursor: (if length > 0 then "genegeerd" else "" end)}}' "$db"
    else
      van=$(param cursor); van=${van:-0}; gt=$(param grant_type)
      jq -c --arg gt "$gt" --argjson van "$van" --argjson n "${STUB_PAGINA:-2}" '
        map(select($gt == "" or .content.grants[0].type == $gt)) | .[$van:$van + $n]
        | {contracts: ., pagination: {next_cursor: (if length > 0 then ($van + length | tostring) else "" end)}}' "$db"
    fi ;;
  "POST /v1/contracts")
    [ "$zijde" = cons ] || exit 22
    # Wat een echte manager weigert (500 invalid service type / outway identification), weigert dit ook.
    printf '%s' "$body" | jq -e '.contract_content | (.grants | length == 1)
      and .hash_algorithm == "HASH_ALGORITHM_SHA3_512" and has("fsc_version") == false
      and .validity.not_before <= .created_at and .created_at <= now
      and .grants[0].type == "GRANT_TYPE_SERVICE_CONNECTION"
      and .grants[0].service.type == "SERVICE_TYPE_SERVICE"
      and .grants[0].outway.identification.type == "OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT"' >/dev/null \
      || { printf '{"title":"invalid contract content"}'; exit 22; }
    n=$(( $(jq length "$db") + 1 )); h="\$1\$1\$NIEUW${n}"
    nieuw=$(printf '%s' "$body" | jq -c --arg h "$h" --arg cons "$S_CONS" '
      { hash: $h, state: "CONTRACT_STATE_PROPOSED", has_revoked: false, has_rejected: false,
        signatures: { accept: { ($cons): {} } },
        content: (.contract_content | .grants[0].hash = ("$1$3$g" + ($h | split("$") | last))) }')
    zet "$db" --argjson c "$nieuw" '. + [$c]'
    # Opgeslagen, maar de respons faalt (timeout, audit-log): de client ziet een fout terwijl het
    # contract er al is. De push naar de provider is in OpenFSC asynchroon en komt dan niet aan.
    [ "${STUB_POST_500:-0}" != 1 ] || { printf '{"title":"internal error"}'; exit 22; }
    zet "$STUB/prov.json" --argjson c "$nieuw" '. + [$c]'
    printf '{"content_hash":"%s"}' "${STUB_POST_HASH:-$h}" ;;
  "PUT /v1/contracts/"*/accept)
    h=$(hash_uit_pad)
    teken "$db" "$h" "$eigen"
    # STUB_GESTRAND / STUB_CONS_GESTRAND: de push van de provider- resp. consumer-handtekening naar
    # de andere manager komt niet aan.
    { [ "$zijde" = prov ] && [ "${STUB_GESTRAND:-0}" = 1 ]; } || { [ "$zijde" = cons ] && [ "${STUB_CONS_GESTRAND:-0}" = 1 ]; } \
      || teken "$STUB/$ander_zijde.json" "$h" "$eigen"
    printf '{}' ;;
  "PUT /v1/contracts/"*/distributions/*/DISTRIBUTION_ACTION_SUBMIT_ACCEPT_SIGNATURE/retry)
    # OpenFSC: 201 zolang het contract bestaat; de push zelf is asynchroon.
    [ "${STUB_RETRY_NOOP:-0}" = 1 ] || teken "$STUB/$ander_zijde.json" "$(hash_uit_pad)" "$eigen"
    printf '{}' ;;
  "PUT /v1/contracts/"*/distributions/*/DISTRIBUTION_ACTION_SUBMIT_CONTRACT/retry)
    h=$(hash_uit_pad)
    [ "${STUB_SUBMIT_NOOP:-0}" = 1 ] || zet "$STUB/prov.json" --slurpfile c "$db" --arg h "$h" \
      'if any(.[]; .hash == $h) then . else . + [$c[0][] | select(.hash == $h)] end'
    printf '{}' ;;
  "PUT /v1/contracts/"*/revoke)
    h=$(hash_uit_pad)
    [ "${STUB_REVOKE_FAAL:-}" != "$h" ] || { printf '{"title":"revoke mislukt"}'; exit 22; }
    [ "${STUB_REVOKE_NOOP:-0}" != 1 ] || { printf '{}'; exit 0; }
    zet "$db" --arg h "$h" 'map(if .hash == $h then .state = "CONTRACT_STATE_REVOKED" | .has_revoked = true else . end)'
    zet "$STUB/$ander_zijde.json" --arg h "$h" 'map(if .hash == $h then .state = "CONTRACT_STATE_REVOKED" else . end)'
    printf '{}' ;;
  *) printf '{"title":"405 of onbekend endpoint"}'; exit 22 ;;
esac
STUB
chmod +x "$TMP/bin/docker"

fails=0
cases=0
expect() {
  cases=$((cases + 1))
  if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAAL  %s\n  verwacht: %s\n  gekregen: %s\n' "$1" "$2" "$3" >&2; fails=$((fails + 1)); fi
}

# Peer-instellingen; `andere_peers` zet een tweede set om de generieke parameters te toetsen.
example_peers() {
  CONS=00000000000000000020; PROV=00000000000000000030; SVC=example-service
  CONS_URL=https://manager.example-consumer.fsc-test.local:9443
  PROV_URL=https://manager.example-provider.fsc-test.local:9443
  CONS_CERT=/pki/internal/example-consumer/manager/cert.pem
  PROV_CERT=/pki/internal/example-provider/manager/cert.pem
}
andere_peers() {
  CONS=00000000000000000777; PROV=00000000000000000888; SVC=andere-dienst
  CONS_URL=https://mgr.uitvraag.test:9443; PROV_URL=https://mgr.magazijn.test:9443
  CONS_CERT=/certs/uitvraag/cert.pem; PROV_CERT=/certs/magazijn/cert.pem
}

# contract <hash> <state> <getekend-door-json> [created_at]: één contract van onze combinatie.
contract() {
  jq -cn --arg h "$1" --arg st "$2" --argjson sig "$3" --argjson t "${4:-1000}" \
     --arg svc "$SVC" --arg prov "$PROV" --arg cons "$CONS" --arg thumb "$THUMB" '
    { hash: $h, state: $st, has_revoked: false, has_rejected: false,
      signatures: { accept: ($sig | map({(.): {}}) | add // {}) },
      content: { created_at: $t, group_id: "moza-fbs-test", hash_algorithm: "HASH_ALGORITHM_SHA3_512",
                 validity: { not_before: 1, not_after: 4102444800 }, grants: [ {
        type: "GRANT_TYPE_SERVICE_CONNECTION", hash: ("$1$3$g" + ($h | split("$") | last)),
        service: { type: "SERVICE_TYPE_SERVICE", peer_id: $prov, name: $svc },
        outway: { peer_id: $cons, identification: {
          type: "OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT", public_key_thumbprint: $thumb } } } ] } }'
}

# omgeving <consumer-json-array> <provider-json-array>: verse managerdatabases.
omgeving() {
  STUB="$TMP/stub-$cases-$RANDOM"; mkdir -p "$STUB"
  printf '%s' "$1" >"$STUB/cons.json"; printf '%s' "$2" >"$STUB/prov.json"; : >"$STUB/calls.log"
}

# start <script> [env…]: draai een script tegen de stub; zet RC, uitvoer in $STUB/out.log.
start() {
  local script="$1"; shift
  local hc="${CONS_URL#https://}" hp="${PROV_URL#https://}"
  RC=0
  env PATH="$TMP/bin:$PATH" STUB="$STUB" S_CONS="$CONS" S_PROV="$PROV" \
      S_CONS_HOST="${hc%%/*}" S_PROV_HOST="${hp%%/*}" S_CONS_CERT="$CONS_CERT" S_PROV_CERT="$PROV_CERT" \
      CONSUMER_OIN="$CONS" PROVIDER_OIN="$PROV" SERVICE_NAME="$SVC" \
      CONSUMER_MANAGER="$CONS_URL" PROVIDER_MANAGER="$PROV_URL" CONSUMER_CERT="$CONS_CERT" PROVIDER_CERT="$PROV_CERT" \
      OUTWAY_CERT_HOST="$TMP/outway.pem" SYNC_TIMEOUT=1 SYNC_INTERVAL=1 "$@" \
      bash "$script" >"$STUB/out.log" 2>&1 || RC=$?
}
draai() { start "$HERE/bootstrap.sh" "$@"; }

aantal() { grep -c -- "$1" "$STUB/calls.log" || true; }
gelogd() { grep -F -- "$1" "$STUB/calls.log" | paste -sd'|' - || true; }
niet_ingetrokken() { jq '[.[] | select(.state != "CONTRACT_STATE_REVOKED")] | length' "$STUB/cons.json"; }
# reden <patroon>: staat de verwachte FAIL-reden in de uitvoer (en niet een willekeurige andere)?
reden() {
  if grep -q -- "$1" "$STUB/out.log"; then echo ja; else echo "nee: $(grep FAIL "$STUB/out.log" | head -n1)"; fi
}

example_peers
BEIDE="[\"$CONS\",\"$PROV\"]"
ALLEEN_CONS="[\"$CONS\"]"
ALLEEN_PROV="[\"$PROV\"]"

echo "Regressietest contracts/bootstrap.sh (beslislogica, gestubde managers)"

# --- Drie runs op een lege omgeving: precies één contract --------------------------------------
omgeving '[]' '[]'
draai; expect "run 1: exit 0" 0 "$RC"
draai; expect "run 2: exit 0" 0 "$RC"
draai; expect "run 3: exit 0" 0 "$RC"
expect "drie runs: één POST" 1 "$(aantal 'cons POST /v1/contracts')"
expect "drie runs: één accept" 1 "$(aantal '/accept')"
expect "drie runs: precies één contract" 1 "$(niet_ingetrokken)"
expect "geen enkele POST op een retry-endpoint (OpenFSC routeert die alleen als PUT)" 0 "$(aantal 'POST .*/retry')"

# Bij meer contracten dan één pagina (STUB_PAGINA=1) moet de bootstrap ze nog steeds terugvinden.
omgeving "[$(contract '$1$1$ANDER' CONTRACT_STATE_VALID "$BEIDE" 500 | jq -c '.content.grants[0].service.name = "x"'),$(contract '$1$1$EIGEN' CONTRACT_STATE_VALID "$BEIDE")]" \
  "[$(contract '$1$1$EIGEN' CONTRACT_STATE_VALID "$BEIDE")]"
draai STUB_PAGINA=1
expect "eigen contract op pagina 2: exit 0, geen POST" "0 0" "$RC $(aantal 'POST /v1/contracts')"

andere_peers
omgeving '[]' '[]'
draai; draai; draai
expect "andere peers/dienst/managers/certs via env: drie runs, één contract" "0 1 1" "$RC $(aantal 'cons POST /v1/contracts') $(niet_ingetrokken)"
example_peers

# --- smoke-contract.sh tegen dezelfde stub ------------------------------------------------------
omgeving '[]' '[]'
start "$HERE/../deploy/local/smoke-contract.sh"
expect "smoke-contract.sh: groen op een lege omgeving" 0 "$RC"
expect "smoke-contract.sh: drie bootstrap-runs, één POST" 1 "$(aantal 'cons POST /v1/contracts')"

# De gedocumenteerde herstelroute na een afwijzing moet de smoke groen laten.
omgeving "[$(contract '$1$1$AFGEWEZEN' CONTRACT_STATE_REJECTED "$ALLEEN_CONS")]" '[]'
draai OPNIEUW_INDIENEN=1
start "$HERE/../deploy/local/smoke-contract.sh"
expect "smoke-contract.sh: groen na herstel van een afwijzing" 0 "$RC"

omgeving '[]' '[]'
start "$HERE/../deploy/local/smoke-contract.sh" RUNS=0
expect "smoke-contract.sh: RUNS=0 is rood, niet nul rondes groen" "1 0" "$RC $(aantal 'POST /v1/contracts')"

# Blijft een duplicaat staan (intrekken meldt 2xx maar doet niets), dan stopt de bootstrap al zelf.
omgeving "[$(contract '$1$1$EEN' CONTRACT_STATE_VALID "$BEIDE" 1000),$(contract '$1$1$TWEE' CONTRACT_STATE_VALID "$BEIDE" 2000)]" \
  "[$(contract '$1$1$EEN' CONTRACT_STATE_VALID "$BEIDE" 1000)]"
start "$HERE/../deploy/local/smoke-contract.sh" RUNS=1 STUB_REVOKE_NOOP=1
expect "intrekken met 2xx zonder effect: rood, met die reden" "1 ja" "$RC $(reden 'na intrekken nog geldig of lopend')"

# --- Duplicaten: het oudste blijft, overige geldige én lopende worden ingetrokken ---------------
omgeving "[$(contract '$1$1$NIEUW' CONTRACT_STATE_VALID "$BEIDE" 2000),$(contract '$1$1$OUD' CONTRACT_STATE_VALID "$BEIDE" 1000),$(contract '$1$1$LOPEND' CONTRACT_STATE_PROPOSED "$ALLEEN_CONS" 3000)]" \
  "[$(contract '$1$1$OUD' CONTRACT_STATE_VALID "$BEIDE" 1000)]"
draai
expect "duplicaten: exit 0" 0 "$RC"
expect "duplicaten: nieuwste en lopende ingetrokken, oudste niet" \
  'cons PUT /v1/contracts/$1$1$NIEUW/revoke|cons PUT /v1/contracts/$1$1$LOPEND/revoke' "$(gelogd /revoke)"
expect "duplicaten: geen POST" 0 "$(aantal 'POST /v1/contracts')"
expect "duplicaten: één over" 1 "$(niet_ingetrokken)"

omgeving "[$(contract '$1$1$OUD' CONTRACT_STATE_VALID "$BEIDE" 1000),$(contract '$1$1$B' CONTRACT_STATE_VALID "$BEIDE" 2000),$(contract '$1$1$C' CONTRACT_STATE_VALID "$BEIDE" 3000)]" '[]'
draai STUB_REVOKE_FAAL='$1$1$B'
expect "intrekken faalt voor één duplicaat: exit 1, de rest toch ingetrokken, faler nog geldig" \
  "1 1 CONTRACT_STATE_VALID" "$RC $(aantal 'PUT /v1/contracts/$1$1$C/revoke') $(jq -r '.[] | select(.hash == "$1$1$B") | .state' "$STUB/cons.json")"


# --- Lopend contract: afmaken, niet opnieuw indienen ---------------------------------------------
L="[$(contract '$1$1$LOPEND' CONTRACT_STATE_PROPOSED "$ALLEEN_CONS")]"
omgeving "$L" "$L"
draai
expect "lopend: exit 0" 0 "$RC"
expect "lopend: geen POST" 0 "$(aantal 'POST /v1/contracts')"
expect "lopend: accept op precies dat contract" 'prov PUT /v1/contracts/$1$1$LOPEND/accept' "$(gelogd /accept)"

P="[$(contract '$1$1$VANPROV' CONTRACT_STATE_PROPOSED "$ALLEEN_PROV")]"
omgeving "$P" "$P"
draai
expect "door de provider voorgesteld: consumer tekent, exit 0" \
  "0 cons PUT /v1/contracts/\$1\$1\$VANPROV/accept" "$RC $(gelogd /accept)"

omgeving "$P" "$P"
draai STUB_CONS_GESTRAND=1
expect "consumer-accept strandt richting provider: her-distributie, exit 0, provider valid" \
  "0 1 CONTRACT_STATE_VALID" "$RC $(aantal 'cons PUT .*SUBMIT_ACCEPT_SIGNATURE/retry') $(jq -r '.[0].state' "$STUB/prov.json")"

omgeving "[$(contract '$1$1$HALF' CONTRACT_STATE_VALID "$BEIDE")]" "[$(contract '$1$1$HALF' CONTRACT_STATE_PROPOSED "$ALLEEN_PROV")]"
draai
expect "bestaand contract alleen op de consumer valid: geen no-op maar her-distributie" \
  "0 1" "$RC $(aantal 'cons PUT .*SUBMIT_ACCEPT_SIGNATURE/retry')"
omgeving "[$(contract '$1$1$HALF' CONTRACT_STATE_VALID "$BEIDE")]" "[$(contract '$1$1$HALF' CONTRACT_STATE_PROPOSED "$ALLEEN_PROV")]"
draai STUB_RETRY_NOOP=1
expect "provider blijft niet-valid: begrensd exit 1" "1 ja" "$RC $(reden "niet 'valid' op de provider")"

omgeving "$L" '[]'
draai
expect "nooit bij de provider: SUBMIT_CONTRACT-retry, exit 0, geen POST" "0 1 0" \
  "$RC $(aantal 'cons PUT .*DISTRIBUTION_ACTION_SUBMIT_CONTRACT/retry') $(aantal 'POST /v1/contracts')"

omgeving "$L" '[]'
draai STUB_SUBMIT_NOOP=1
expect "ook na her-distributie niet bij de provider: begrensd exit 1" "1 ja" "$RC $(reden 'ook na her-distributie')"

omgeving "$L" "[$(contract '$1$1$LOPEND' CONTRACT_STATE_VALID "$BEIDE")]"
draai
expect "gestrand (provider tekende al): geen accept, wel accept-sig-retry, exit 0" "0 0 1" \
  "$RC $(aantal '/accept') $(aantal 'prov PUT .*DISTRIBUTION_ACTION_SUBMIT_ACCEPT_SIGNATURE/retry')"

omgeving '[]' '[]'
draai STUB_GESTRAND=1
expect "verse indiening, push strandt: exit 0 na her-distributie" "0 1" "$RC $(aantal 'SUBMIT_ACCEPT_SIGNATURE/retry')"

omgeving '[]' '[]'
draai STUB_GESTRAND=1 STUB_RETRY_NOOP=1
expect "ook na her-distributie niet geldig: begrensd exit 1" "1 ja" "$RC $(reden "werd niet 'valid'")"

# --- Afgewezen of ingetrokken door de andere peer: respecteren -----------------------------------
omgeving "$L" "[$(contract '$1$1$LOPEND' CONTRACT_STATE_REJECTED "$ALLEEN_CONS")]"
draai
expect "provider wees af, consumer weet het nog niet: geen accept, exit 1" "1 0 ja" "$RC $(aantal '/accept') $(reden 'afgewezen, ingetrokken of verlopen')"
draai OPNIEUW_INDIENEN=1
expect "… met OPNIEUW_INDIENEN=1: intrekken, één nieuw contract, exit 0" "0 1 1" \
  "$RC $(aantal 'cons PUT /v1/contracts/\$1\$1\$LOPEND/revoke') $(aantal 'POST /v1/contracts')"

omgeving "$L" "[$(contract '$1$1$LOPEND' CONTRACT_STATE_REVOKED "$ALLEEN_CONS")]"
draai
expect "provider trok in, consumer weet het nog niet: geen accept, exit 1" "1 0" "$RC $(aantal '/accept')"

omgeving "[$(contract '$1$1$AFGEWEZEN' CONTRACT_STATE_REJECTED "$ALLEEN_CONS")]" '[]'
draai
expect "afgewezen: exit 1, geen POST" "1 0 ja" "$RC $(aantal 'POST /v1/contracts') $(reden 'OPNIEUW_INDIENEN=1')"
draai OPNIEUW_INDIENEN=1
expect "afgewezen + OPNIEUW_INDIENEN=1: exit 0, één POST" "0 1" "$RC $(aantal 'POST /v1/contracts')"

omgeving "[$(contract '$1$1$INGETROKKEN' CONTRACT_STATE_REVOKED "$BEIDE")]" '[]'
draai
expect "door de provider ingetrokken (has_revoked=false): exit 1, geen POST" "1 0" "$RC $(aantal 'POST /v1/contracts')"

# --- Verlopen: telt als afwezig ------------------------------------------------------------------
omgeving "[$(contract '$1$1$VERLOPEN' CONTRACT_STATE_EXPIRED "$BEIDE")]" '[]'
draai
expect "verlopen: nieuw contract, exit 0" "0 1" "$RC $(aantal 'POST /v1/contracts')"

# --- POST faalt nadat de manager het contract al opsloeg ----------------------------------------
omgeving '[]' '[]'
draai STUB_POST_500=1
expect "POST 500 na lokaal opslaan: run 1 faalt" 1 "$RC"
draai
expect "POST 500 na lokaal opslaan: run 2 maakt hetzelfde contract af" "0 1 1 1" \
  "$RC $(aantal 'POST /v1/contracts') $(aantal 'SUBMIT_CONTRACT/retry') $(niet_ingetrokken)"

omgeving '[]' '[]'
draai STUB_POST_HASH='$1$1$../revoke'
expect "POST-respons met een hash die een pad verlegt: exit 1, geen call met dat hash" "1 0 ja" \
  "$RC $(aantal 'revoke\|/accept\|/retry') $(reden 'bruikbare content_hash')"

# --- Onleesbare lijst of onbekende toestand: hard stoppen, niets indienen ------------------------
omgeving '[]' '[]'
draai STUB_CONS_KAPOT=1
expect "foutpagina: exit 1, geen POST, juiste reden" "1 0 ja" "$RC $(aantal 'POST /v1/contracts') $(reden 'niet op te halen')"

omgeving "[$(contract '$1$1$RAAR' CONTRACT_STATE_VALID "$BEIDE" | jq -c 'del(.state)')]" '[]'
draai
expect "ontbrekende state: exit 1, geen POST" "1 0 ja" "$RC $(aantal 'POST /v1/contracts') $(reden 'onverwachte state')"

omgeving "[$(contract '$1$1$HALF' CONTRACT_STATE_VALID "$ALLEEN_CONS")]" '[]'
draai
expect "'valid' zonder provider-handtekening: exit 1, geen POST" "1 0" "$RC $(aantal 'POST /v1/contracts')"

# --- Ongeldige invoer --------------------------------------------------------------------------
omgeving '[]' '[]'
draai SYNC_INTERVAL=0
expect "SYNC_INTERVAL=0 (hot loop) wordt geweigerd zonder één call" "1 0" "$RC $(wc -l <"$STUB/calls.log" | tr -d ' ')"
draai SYNC_INTERVAL=08
expect "SYNC_INTERVAL=08 (octaal) wordt geweigerd" 1 "$RC"

echo
if [ "$fails" -eq 0 ]; then
  echo "== ${cases} cases groen =="
else
  echo "== ${fails} van ${cases} cases rood ==" >&2
  exit 1
fi
