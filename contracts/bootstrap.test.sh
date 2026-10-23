#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Regressietest voor de beslislogica van contracts/bootstrap.sh, zonder draaiende managers: een
# nep-`docker` vooraan op PATH speelt beide managers na op twee JSON-bestanden en logt elke call.
# Bewijst o.a. "drie runs op een lege omgeving = één contract" en dat duplicaten, lopende,
# gestrande en afgewezen contracten de juiste afslag nemen.
# FSC-hashes (`$1$<n>$…`) zijn letterlijke tekst, geen variabelen:
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CONS=00000000000000000020
PROV=00000000000000000030
SVC=example-service
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

zijde="" methode=GET url="" body="" token=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cert) case "$2" in *example-consumer/manager*) zijde=cons ;; *example-provider/manager*) zijde=prov ;; *) zijde=outway ;; esac; shift 2 ;;
    -X) methode="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -w) token=1; shift 2 ;;
    -H|--key|--cacert|-o|--data-urlencode) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$token" -eq 0 ] || { printf 404; exit 0; }

pad="/${url#https://*/}"; pad="${pad%%\?*}"
echo "$zijde $methode $pad" >>"$STUB/calls.log"
bestand="$STUB/$zijde.json"

# zet <bestand> <jq-filter> [args…]: herschrijf een managerdatabase.
zet() { local f="$1"; shift; jq "$@" "$f" >"$f.nieuw" && mv "$f.nieuw" "$f"; }
markeer() {  # markeer <bestand> <hash> <jq-update-op-dat-contract>
  zet "$1" --arg h "$2" "map(if .hash == \$h then $3 else . end)"
}

case "$methode $pad" in
  "GET /v1/contracts")
    [ "$zijde" != cons ] || [ "${STUB_CONS_KAPOT:-0}" != 1 ] || { printf '<html>502</html>'; exit 22; }
    filter=""; case "$url" in *content_hash=*) filter="${url##*content_hash=}"; filter="${filter%%&*}"; filter=$(printf '%b' "${filter//%/\\x}") ;; esac
    jq -c --arg h "$filter" '{contracts: map(select($h == "" or .hash == $h)), pagination: {next_cursor: ""}}' "$bestand" ;;
  "POST /v1/contracts")
    n=$(( $(jq length "$STUB/cons.json") + 1 )); h="\$1\$1\$NIEUW${n}"
    nieuw=$(printf '%s' "$body" | jq -c --arg h "$h" --arg cons "$CONS" '
      { hash: $h, state: "CONTRACT_STATE_PROPOSED", has_revoked: false, has_rejected: false,
        signatures: { accept: { ($cons): {} } },
        content: (.contract_content | .grants[0].hash = ("$1$3$g" + ($h | split("$") | last))) }')
    zet "$STUB/cons.json" --argjson c "$nieuw" '. + [$c]'
    [ "${STUB_GEEN_SYNC:-0}" = 1 ] || zet "$STUB/prov.json" --argjson c "$nieuw" '. + [$c]'
    printf '{"content_hash":"%s"}' "$h" ;;
  "PUT /v1/contracts/"*/accept)
    [ "$zijde" = prov ] || exit 22
    h="${pad#/v1/contracts/}"; h="${h%/accept}"
    markeer "$STUB/prov.json" "$h" ".signatures.accept[\"$PROV\"] = {} | .state = \"CONTRACT_STATE_VALID\""
    [ "${STUB_GESTRAND:-0}" = 1 ] || markeer "$STUB/cons.json" "$h" ".signatures.accept[\"$PROV\"] = {} | .state = \"CONTRACT_STATE_VALID\""
    printf '{}' ;;
  "PUT /v1/contracts/"*/distributions/"$CONS"/DISTRIBUTION_ACTION_SUBMIT_ACCEPT_SIGNATURE/retry)
    h="${pad#/v1/contracts/}"; h="${h%%/distributions/*}"
    markeer "$STUB/cons.json" "$h" ".signatures.accept[\"$PROV\"] = {} | .state = \"CONTRACT_STATE_VALID\""
    printf '{}' ;;
  "PUT /v1/contracts/"*/distributions/"$PROV"/DISTRIBUTION_ACTION_SUBMIT_CONTRACT/retry)
    h="${pad#/v1/contracts/}"; h="${h%%/distributions/*}"
    zet "$STUB/prov.json" --slurpfile c "$STUB/cons.json" --arg h "$h" '. + [$c[0][] | select(.hash == $h)]'
    printf '{}' ;;
  "PUT /v1/contracts/"*/revoke)
    h="${pad#/v1/contracts/}"; h="${h%/revoke}"
    markeer "$STUB/cons.json" "$h" '.state = "CONTRACT_STATE_REVOKED" | .has_revoked = true'
    printf '{}' ;;
  *) printf '{"title":"405 of onbekend"}'; exit 22 ;;
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

# contract <hash> <state> <getekend-door-json> [created_at]: één contract van onze combinatie.
contract() {
  jq -cn --arg h "$1" --arg st "$2" --argjson sig "$3" --argjson t "${4:-1000}" \
     --arg svc "$SVC" --arg prov "$PROV" --arg cons "$CONS" --arg thumb "$THUMB" '
    { hash: $h, state: $st, has_revoked: false, has_rejected: false,
      signatures: { accept: ($sig | map({(.): {}}) | add // {}) },
      content: { created_at: $t, grants: [ {
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

# draai [env…]: draai de bootstrap tegen de stub; zet RC.
draai() {
  RC=0
  env PATH="$TMP/bin:$PATH" STUB="$STUB" CONS="$CONS" PROV="$PROV" \
      OUTWAY_CERT_HOST="$TMP/outway.pem" SYNC_TIMEOUT=1 SYNC_INTERVAL=1 "$@" \
      bash "$HERE/bootstrap.sh" >"$STUB/out.log" 2>&1 || RC=$?
}

aantal() { grep -c -- "$1" "$STUB/calls.log" || true; }
gelogd() { grep -F -- "$1" "$STUB/calls.log" | paste -sd'|' || true; }
niet_ingetrokken() { jq '[.[] | select(.state != "CONTRACT_STATE_REVOKED")] | length' "$STUB/cons.json"; }

BEIDE="[\"$CONS\",\"$PROV\"]"
ALLEEN_CONS="[\"$CONS\"]"

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

# De smoke die dit live bewijst, draait hier tegen dezelfde stub: groen op een lege omgeving, rood
# zodra er een tweede contract naast staat.
omgeving '[]' '[]'
RC=0; env PATH="$TMP/bin:$PATH" STUB="$STUB" CONS="$CONS" PROV="$PROV" OUTWAY_CERT_HOST="$TMP/outway.pem" \
  SYNC_TIMEOUT=1 SYNC_INTERVAL=1 bash "$HERE/../deploy/local/smoke-contract.sh" >"$STUB/out.log" 2>&1 || RC=$?
expect "smoke-contract.sh: groen op een lege omgeving" 0 "$RC"
expect "smoke-contract.sh: drie bootstrap-runs, één POST" 1 "$(aantal 'cons POST /v1/contracts')"

omgeving "[$(contract '$1$1$EEN' CONTRACT_STATE_VALID "$BEIDE" 1000),$(contract '$1$1$TWEE' CONTRACT_STATE_REJECTED "$ALLEEN_CONS" 2000)]" '[]'
RC=0; env PATH="$TMP/bin:$PATH" STUB="$STUB" CONS="$CONS" PROV="$PROV" OUTWAY_CERT_HOST="$TMP/outway.pem" \
  SYNC_TIMEOUT=1 SYNC_INTERVAL=1 RUNS=1 bash "$HERE/../deploy/local/smoke-contract.sh" >"$STUB/out.log" 2>&1 || RC=$?
expect "smoke-contract.sh: rood bij een tweede contract voor de combinatie" 1 "$RC"

# --- Duplicaten: het oudste blijft, overige geldige én lopende worden ingetrokken ---------------
omgeving "[$(contract '$1$1$NIEUW' CONTRACT_STATE_VALID "$BEIDE" 2000),$(contract '$1$1$OUD' CONTRACT_STATE_VALID "$BEIDE" 1000),$(contract '$1$1$LOPEND' CONTRACT_STATE_PROPOSED "$ALLEEN_CONS" 3000)]" '[]'
draai
expect "duplicaten: exit 0" 0 "$RC"
expect "duplicaten: nieuwste en lopende ingetrokken, oudste niet" \
  'cons PUT /v1/contracts/$1$1$NIEUW/revoke|cons PUT /v1/contracts/$1$1$LOPEND/revoke' "$(gelogd /revoke)"
expect "duplicaten: geen POST" 0 "$(aantal 'POST /v1/contracts')"
expect "duplicaten: één over" 1 "$(niet_ingetrokken)"

# --- Lopend contract: afmaken, niet opnieuw indienen ---------------------------------------------
L="[$(contract '$1$1$LOPEND' CONTRACT_STATE_PROPOSED "$ALLEEN_CONS")]"
omgeving "$L" "$L"
draai
expect "lopend: exit 0" 0 "$RC"
expect "lopend: geen POST" 0 "$(aantal 'POST /v1/contracts')"
expect "lopend: accept op precies dat contract" 'prov PUT /v1/contracts/$1$1$LOPEND/accept' "$(gelogd /accept)"

# --- Lopend contract dat de provider nooit bereikte: consumer-side her-distributie -------------
omgeving "$L" '[]'
draai
expect "niet gesynct: exit 0" 0 "$RC"
expect "niet gesynct: SUBMIT_CONTRACT-retry op de consumer" 1 "$(aantal 'cons PUT .*DISTRIBUTION_ACTION_SUBMIT_CONTRACT/retry')"
expect "niet gesynct: geen POST" 0 "$(aantal 'POST /v1/contracts')"

# --- Provider tekende al, push naar de consumer strandde: geen accept, wel her-distributie ------
omgeving "$L" "[$(contract '$1$1$LOPEND' CONTRACT_STATE_VALID "$BEIDE")]"
draai
expect "gestrand: exit 0" 0 "$RC"
expect "gestrand: geen tweede accept" 0 "$(aantal '/accept')"
expect "gestrand: accept-sig-retry op de provider" 1 "$(aantal 'prov PUT .*DISTRIBUTION_ACTION_SUBMIT_ACCEPT_SIGNATURE/retry')"

# --- Verse indiening waarvan de accept-push strandt ----------------------------------------------
omgeving '[]' '[]'
draai STUB_GESTRAND=1
expect "verse indiening, push strandt: exit 0 na her-distributie" 0 "$RC"
expect "verse indiening, push strandt: accept-sig-retry" 1 "$(aantal 'DISTRIBUTION_ACTION_SUBMIT_ACCEPT_SIGNATURE/retry')"

# --- Afgewezen: respecteren, tenzij expliciet opnieuw --------------------------------------------
omgeving "[$(contract '$1$1$AFGEWEZEN' CONTRACT_STATE_REJECTED "$ALLEEN_CONS")]" '[]'
draai
expect "afgewezen: exit 1" 1 "$RC"
expect "afgewezen: geen POST" 0 "$(aantal 'POST /v1/contracts')"
draai OPNIEUW_NA_AFWIJZING=1
expect "afgewezen + OPNIEUW_NA_AFWIJZING=1: exit 0" 0 "$RC"
expect "afgewezen + OPNIEUW_NA_AFWIJZING=1: één POST" 1 "$(aantal 'POST /v1/contracts')"

# --- Verlopen: telt als afwezig ------------------------------------------------------------------
omgeving "[$(contract '$1$1$VERLOPEN' CONTRACT_STATE_EXPIRED "$BEIDE")]" '[]'
draai
expect "verlopen: nieuw contract ingediend" 1 "$(aantal 'POST /v1/contracts')"
expect "verlopen: exit 0" 0 "$RC"

# --- Onleesbare lijst of onbekende state: hard stoppen, niets indienen ---------------------------
omgeving '[]' '[]'
draai STUB_CONS_KAPOT=1
expect "foutpagina: exit ≠ 0" 1 "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
expect "foutpagina: geen POST" 0 "$(aantal 'POST /v1/contracts')"

omgeving "[$(contract '$1$1$RAAR' CONTRACT_STATE_VALID "$BEIDE" | jq -c 'del(.state)')]" '[]'
draai
expect "ontbrekende state: exit 1" 1 "$RC"
expect "ontbrekende state: geen POST" 0 "$(aantal 'POST /v1/contracts')"

# --- Ongeldige invoer --------------------------------------------------------------------------
omgeving '[]' '[]'
draai SYNC_INTERVAL=0
expect "SYNC_INTERVAL=0 (hot loop) wordt geweigerd" 1 "$RC"
expect "SYNC_INTERVAL=0: geen enkele call" 0 "$(wc -l <"$STUB/calls.log" | tr -d ' ')"

echo
if [ "$fails" -eq 0 ]; then
  echo "== ${cases} cases groen =="
else
  echo "== ${fails} van ${cases} cases rood ==" >&2
  exit 1
fi
