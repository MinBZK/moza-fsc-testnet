#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Regressietest voor contracts/contracten.sh, zonder draaiende managers. De idempotentie van de
# bootstrap staat of valt met deze matcher: telt hij een vreemd contract mee, dan is de bootstrap
# false green; mist hij het eigen contract, dan dient elke run een nieuw in.
# FSC-hashes (`$1$<n>$…`) zijn letterlijke tekst, geen variabelen:
# shellcheck disable=SC2016
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=contracten.sh
. "${HERE}/contracten.sh"

fails=0
cases=0

# $1=omschrijving $2=verwacht $3=gekregen
expect() {
  cases=$((cases + 1))
  if [ "$2" = "$3" ]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAAL  %s\n  verwacht: %s\n  gekregen: %s\n' "$1" "$2" "$3" >&2
    fails=$((fails + 1))
  fi
}

SVC=example-service
PROV=00000000000000000030
CONS=00000000000000000020
THUMB=$(printf '%064d' 0 | tr 0 a)
ANDER=$(printf '%064d' 0 | tr 0 b)

# contract <hash> <state> <getekend-door-json> [jq-aanpassing]: één contractrij in de GET-vorm.
contract() {
  jq -cn --arg h "$1" --arg st "$2" --argjson sig "$3" \
     --arg svc "$SVC" --arg prov "$PROV" --arg cons "$CONS" --arg thumb "$THUMB" '
    { hash: $h, state: $st, has_revoked: false, has_rejected: false,
      signatures: { accept: ($sig | map({(.): {}}) | add // {}) },
      content: { grants: [ {
        type: "GRANT_TYPE_SERVICE_CONNECTION",
        service: { type: "SERVICE_TYPE_SERVICE", peer_id: $prov, name: $svc },
        outway: { peer_id: $cons, identification: {
          type: "OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT", public_key_thumbprint: $thumb } } } ] } }
    | '"${4:-.}"
}

lijst() { jq -cn '{contracts: $ARGS.positional | map(fromjson)}' --args "$@"; }
match() { contract_voor_combinatie "$1" "$SVC" "$PROV" "$CONS" "$THUMB"; }

H1='$1$4$AAAA'
H2='$1$4$BBBB'
H3='$1$4$CCCC'
BEIDE="[\"$CONS\",\"$PROV\"]"
VALID=CONTRACT_STATE_VALID

echo "Regressietest contracts/contracten.sh"

# --- Matcher: wat telt als het contract van deze combinatie -----------------------------------
expect "geldig eigen contract wordt gevonden" \
  "$H1 contract_state_valid ja -" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE")")")"

PUBLICATIE=$(jq -cn --arg h "$H2" --arg svc "$SVC" --arg prov "$PROV" '
  { hash: $h, state: "CONTRACT_STATE_VALID", has_revoked: false, has_rejected: false,
    signatures: { accept: { ($prov): {} } },
    content: { grants: [ { type: "GRANT_TYPE_SERVICE_PUBLICATION",
      service: { peer_id: $prov, name: $svc, protocol: "PROTOCOL_TCP_HTTP_1.1" } } ] } }')
expect "servicePublication-contract voor dezelfde dienst telt niet mee" \
  "" "$(match "$(lijst "$PUBLICATIE")")"

expect "ingetrokken contract telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" CONTRACT_STATE_REVOKED "$BEIDE" '.has_revoked = true')")")"

expect "contract met een andere outway-thumbprint telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" ".content.grants[0].outway.identification.public_key_thumbprint = \"$ANDER\"")")")"

expect "contract van een andere consumer telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants[0].outway.peer_id = "00000000000000000099"')")")"

expect "gedelegeerde serviceConnection telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants[0].type = "GRANT_TYPE_DELEGATED_SERVICE_CONNECTION"')")")"

expect "contract met een tweede grant telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants += [.content.grants[0]]')")")"

expect "hash die een URL-pad zou verleggen telt niet mee" \
  "" "$(match "$(lijst "$(contract '$1$4$../revoke' $VALID "$BEIDE")")")"

expect "misvormde rij van een ander neemt de rest niet mee" \
  "$H1 contract_state_valid ja -" \
  "$(match "$(lijst '{"hash":"$1$4$ZZZZ","content":"kapot"}' '"geen object"' "$(contract "$H1" $VALID "$BEIDE")")")"

expect "afgewezen contract wordt gemeld" \
  "$H1 contract_state_rejected nee afgewezen" \
  "$(match "$(lijst "$(contract "$H1" CONTRACT_STATE_REJECTED "[\"$CONS\"]" '.has_rejected = true')")")"

expect "uitvoer is gesorteerd op hash (stabiele keuze over runs)" \
  "$H1 contract_state_valid ja -|$H3 contract_state_valid ja -" \
  "$(match "$(lijst "$(contract "$H3" $VALID "$BEIDE")" "$(contract "$H1" $VALID "$BEIDE")")" | paste -sd'|')"

rc=0; match '{"items":[]}' >/dev/null 2>&1 || rc=$?
expect "respons zonder contractenlijst faalt in plaats van 'geen contracten'" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# --- geldige_contracten: alleen wederzijds getekend én 'valid' --------------------------------
REGELS=$(match "$(lijst \
  "$(contract "$H1" CONTRACT_STATE_PROPOSED "[\"$CONS\"]")" \
  "$(contract "$H2" CONTRACT_STATE_PROPOSED "$BEIDE")" \
  "$(contract "$H3" $VALID "$BEIDE")")")
expect "alleen het geldige contract telt als bestaand" "$H3" "$(geldige_contracten "$REGELS")"
expect "afgewezen contract telt nooit als bestaand" "" \
  "$(geldige_contracten "$H1 contract_state_valid ja afgewezen")"
expect "ingediend-maar-niet-geldig telt niet als bestaand" "" \
  "$(geldige_contracten "$(match "$(lijst "$(contract "$H1" CONTRACT_STATE_PROPOSED "$BEIDE")")")")"

# --- Paginering --------------------------------------------------------------------------------
# OpenFSC zet een cursor op elke pagina met rijen; pas een lege pagina heeft een lege cursor.
PAGINA1=$(jq -cn --argjson c "[$(contract "$H1" $VALID "$BEIDE")]" '{contracts: $c, pagination: {next_cursor: "p2"}}')
PAGINA2=$(jq -cn --argjson c "[$(contract "$H2" $VALID "$BEIDE")]" '{contracts: $c, pagination: {next_cursor: "p3"}}')
PAGINA3='{"contracts":[],"pagination":{"next_cursor":""}}'
ophaler() {
  case "$1" in
    *cursor=p2) printf '%s' "$PAGINA2" ;;
    *cursor=p3) printf '%s' "$PAGINA3" ;;
    *)          printf '%s' "$PAGINA1" ;;
  esac
}
expect "alle pagina's worden samengevoegd" 2 \
  "$(contracten_paginas ophaler 'https://m/v1/contracts?limit=1000' | jq '.contracts | length')"

kapot() { printf '%s' '<html>502</html>'; }
rc=0; contracten_paginas kapot 'https://m/v1/contracts?limit=1000' >/dev/null 2>&1 || rc=$?
expect "foutpagina is geen lege lijst" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

eindeloos() { printf '%s' '{"contracts":[],"pagination":{"next_cursor":"weer"}}'; }
rc=0; contracten_paginas eindeloos 'https://m/v1/contracts?limit=1000' >/dev/null 2>&1 || rc=$?
expect "eindeloze cursor breekt af" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# --- Thumbprint --------------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=test \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 1 2>/dev/null
WANT=$(openssl pkey -in "$TMP/key.pem" -pubout -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1)
expect "thumbprint = SPKI-SHA256-hex van de publieke sleutel" "$WANT" "$(outway_thumbprint "$TMP/cert.pem")"

echo
if [ "$fails" -eq 0 ]; then
  echo "== ${cases} cases groen =="
else
  echo "== ${fails} van ${cases} cases rood ==" >&2
  exit 1
fi
