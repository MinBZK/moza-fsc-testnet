#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Regressietest voor contracts/contracten.sh, zonder draaiende managers. Telt de matcher een vreemd
# contract mee, dan is de bootstrap false green; mist hij het eigen contract, dan dient elke run
# een nieuw in.
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

# faalt <omschrijving> <stderr-patroon> <commando...>: het commando hoort met een fout te eindigen,
# en om de genoemde reden — niet om een willekeurige andere (tikfout, jq-syntax).
faalt() {
  local rc=0 err
  err=$("${@:3}" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then expect "$1" fout "rc=0"
  elif [ -z "$2" ] || printf '%s' "$err" | grep -q -- "$2"; then expect "$1" fout fout
  else expect "$1" "fout met '$2'" "rc=$rc: ${err:0:200}"; fi
}

SVC=example-service
PROV=00000000000000000030
CONS=00000000000000000020
THUMB=$(printf '%064d' 0 | tr 0 a)
ANDER=$(printf '%064d' 0 | tr 0 b)

# contract <hash> <state> <getekend-door-json> [jq-aanpassing]: één contractrij in de GET-vorm.
# created_at volgt uit de hash, zodat de volgorde in de fixtures expliciet is.
contract() {
  jq -cn --arg h "$1" --arg st "$2" --argjson sig "$3" \
     --arg svc "$SVC" --arg prov "$PROV" --arg cons "$CONS" --arg thumb "$THUMB" '
    { hash: $h, state: $st, has_revoked: false, has_rejected: false,
      signatures: { accept: ($sig | map({(.): {}}) | add // {}) },
      content: { created_at: 1000, grants: [ {
        type: "GRANT_TYPE_SERVICE_CONNECTION", hash: ("$1$3$g" + ($h | split("$") | last)),
        service: { type: "SERVICE_TYPE_SERVICE", peer_id: $prov, name: $svc },
        outway: { peer_id: $cons, identification: {
          type: "OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT", public_key_thumbprint: $thumb } } } ] } }
    | '"${4:-.}"
}

lijst() { jq -cn '{contracts: $ARGS.positional | map(fromjson)}' --args "$@"; }
match() { contract_voor_combinatie "$1" "$SVC" "$PROV" "$CONS" "$THUMB"; }

H1='$1$1$AAAA'
H2='$1$1$BBBB'
H3='$1$1$CCCC'
BEIDE="[\"$CONS\",\"$PROV\"]"
VALID=CONTRACT_STATE_VALID
PROPOSED=CONTRACT_STATE_PROPOSED

echo "Regressietest contracts/contracten.sh"

# --- Matcher: wat telt als het contract van deze combinatie -----------------------------------
expect "geldig eigen contract wordt gevonden, met beide handtekeningen en grant-hash" \
  "$H1 contract_state_valid ja ja \$1\$3\$gAAAA" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE")")")"

PUBLICATIE=$(jq -cn --arg h "$H2" --arg svc "$SVC" --arg prov "$PROV" '
  { hash: $h, state: "CONTRACT_STATE_VALID", has_revoked: false, has_rejected: false,
    signatures: { accept: { ($prov): {} } },
    content: { grants: [ { type: "GRANT_TYPE_SERVICE_PUBLICATION",
      service: { peer_id: $prov, name: $svc, protocol: "PROTOCOL_TCP_HTTP_1.1" } } ] } }')
expect "servicePublication-contract voor dezelfde dienst telt niet mee" \
  "" "$(match "$(lijst "$PUBLICATIE")")"

# OpenFSC zet has_revoked/has_rejected alleen voor de eigen handtekening; door de andere peer
# ingetrokken of afgewezen zie je alleen aan `state`.
expect "door de andere peer ingetrokken contract blijft zichtbaar als revoked" \
  "$H1 contract_state_revoked ja ja \$1\$3\$gAAAA" "$(match "$(lijst "$(contract "$H1" CONTRACT_STATE_REVOKED "$BEIDE")")")"
expect "zelf ingetrokken contract telt niet mee (has_revoked)" \
  "" "$(match "$(lijst "$(contract "$H1" CONTRACT_STATE_REVOKED "$BEIDE" '.has_revoked = true')")")"
expect "verlopen contract telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" CONTRACT_STATE_EXPIRED "$BEIDE")")")"
expect "voorgesteld contract voorbij not_after telt als verlopen" \
  "" "$(match "$(lijst "$(contract "$H1" $PROPOSED "[\"$CONS\"]" '.content.validity = {not_before: 1, not_after: 2}')")")"
expect "door de provider afgewezen contract komt terug als rejected" \
  "$H1 contract_state_rejected nee ja \$1\$3\$gAAAA" \
  "$(match "$(lijst "$(contract "$H1" CONTRACT_STATE_REJECTED "[\"$CONS\"]")")")"

expect "contract met een andere outway-thumbprint telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" ".content.grants[0].outway.identification.public_key_thumbprint = \"$ANDER\"")")")"
expect "contract van een andere consumer telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants[0].outway.peer_id = "00000000000000000099"')")")"
expect "zelfde dienstnaam bij een andere provider telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants[0].service.peer_id = "00000000000000000099"')")")"
expect "andere dienst van dezelfde provider telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants[0].service.name = "andere-dienst"')")")"
expect "gedelegeerde serviceConnection telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants[0].type = "GRANT_TYPE_DELEGATED_SERVICE_CONNECTION"')")")"
expect "gedelegeerde dienst in een gewone grant telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants[0].service.type = "SERVICE_TYPE_DELEGATED_SERVICE"')")")"
expect "contract met een tweede grant telt niet mee" \
  "" "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" '.content.grants += [.content.grants[0]]')")")"

expect "misvormde rij van een ander neemt de rest niet mee" \
  "$H1 contract_state_valid ja ja \$1\$3\$gAAAA" \
  "$(match "$(lijst '{"hash":"$1$1$ZZZZ","content":"kapot"}' '"geen object"' "$(contract "$H1" $VALID "$BEIDE")")")"

faalt "eigen contract met een hash die een URL-pad verlegt faalt luid" "onverwacht hash" \
  match "$(lijst "$(contract '$1$1$../revoke' $VALID "$BEIDE")")"
faalt "eigen contract met een newline achter het hash faalt luid" "onverwacht hash" \
  match "$(lijst "$(contract "$H1"$'\n' $VALID "$BEIDE")")"
faalt "respons zonder contractenlijst faalt in plaats van 'geen contracten'" "geen contractenlijst" match '{"items":[]}'
faalt "lege respons faalt in plaats van 'geen contracten'" "lege contractenlijst" match $' \n'
faalt "ook zonder pipefail bij de aanroeper" "geen contractenlijst" \
  bash -c ". '${HERE}/contracten.sh'; contract_voor_combinatie '{\"items\":[]}' a b c d"

expect "oudste eerst (created_at), hash als tiebreak" \
  "$H3|$H1|$H2" \
  "$(match "$(lijst "$(contract "$H2" $VALID "$BEIDE" '.content.created_at = 2000')" \
                   "$(contract "$H1" $VALID "$BEIDE")" \
                   "$(contract "$H3" $VALID "$BEIDE" '.content.created_at = 500')")" | cut -d' ' -f1 | paste -sd'|' -)"

# --- Indeling van de regels --------------------------------------------------------------------
H4='$1$1$DDDD'
H5='$1$1$EEEE'
REGELS=$(match "$(lijst \
  "$(contract "$H1" $PROPOSED "[\"$CONS\"]")" \
  "$(contract "$H2" CONTRACT_STATE_REJECTED "[\"$CONS\"]")" \
  "$(contract "$H3" $VALID "$BEIDE")" \
  "$(contract "$H4" CONTRACT_STATE_REVOKED "$BEIDE")" \
  "$(contract "$H5" $VALID "[\"$CONS\"]")")")
expect "geldige_contracten: alleen valid met beide handtekeningen" "$H3" "$(geldige_contracten "$REGELS")"
expect "lopende_contracten: alleen proposed" "$H1" "$(lopende_contracten "$REGELS")"
expect "beeindigde_contracten: rejected en door de ander revoked" "$H2|$H4" "$(beeindigde_contracten "$REGELS" | paste -sd'|' -)"
expect "onbekende_contracten: valid zonder provider-handtekening" "$H5" "$(onbekende_contracten "$REGELS" | cut -d' ' -f1)"
expect "onbekende_contracten: ontbrekende state" "ontbreekt" \
  "$(onbekende_contracten "$(match "$(lijst "$(contract "$H1" $VALID "$BEIDE" 'del(.state)')")")" | cut -d' ' -f2)"
expect "valid zonder consumer-handtekening is niet geldig" "" \
  "$(geldige_contracten "$H1 contract_state_valid ja nee \$1\$3\$g")"
expect "proposed met beide handtekeningen (gestrande push) is niet geldig" "" \
  "$(geldige_contracten "$(match "$(lijst "$(contract "$H1" $PROPOSED "$BEIDE")")")")"
expect "consumer_getekend: ja bij consumer-handtekening" ja "$(consumer_getekend "$REGELS" "$H1" && echo ja || echo nee)"
expect "consumer_getekend: nee zonder" nee \
  "$(consumer_getekend "$(match "$(lijst "$(contract "$H1" $PROPOSED "[\"$PROV\"]")")")" "$H1" && echo ja || echo nee)"
expect "grant_hash_van levert de grant-hash van dat contract" '$1$3$gCCCC' "$(grant_hash_van "$REGELS" "$H3")"

# --- hash_ok -------------------------------------------------------------------------------------
expect "hash_ok accepteert de FSC-vorm" ok "$(hash_ok "$H1" && echo ok || echo nee)"
expect "hash_ok weigert een pad" nee "$(hash_ok '$1$1$a/../b' && echo ok || echo nee)"
expect "hash_ok weigert leeg" nee "$(hash_ok '' && echo ok || echo nee)"

# --- Paginering --------------------------------------------------------------------------------
# OpenFSC zet een cursor op elke pagina met rijen; pas een lege pagina heeft een lege cursor.
PAGINA1=$(jq -cn --argjson c "[$(contract "$H1" $VALID "$BEIDE")]" '{contracts: $c, pagination: {next_cursor: "a+b="}}')
PAGINA2=$(jq -cn --argjson c "[$(contract "$H2" $VALID "$BEIDE")]" '{contracts: $c, pagination: {next_cursor: "p3"}}')
PAGINA3='{"contracts":[],"pagination":{"next_cursor":""}}'
ophaler() {
  case "$1" in
    *'cursor=a%2Bb%3D') printf '%s' "$PAGINA2" ;;
    *cursor=p3)         printf '%s' "$PAGINA3" ;;
    *cursor=*)          return 22 ;;
    *)                  printf '%s' "$PAGINA1" ;;
  esac
}
expect "alle pagina's worden samengevoegd (cursor URL-encoded)" 2 \
  "$(contracten_paginas ophaler 'https://m/v1/contracts?limit=1000' | jq '.contracts | length')"

kapot() { printf '%s' '<html>502</html>'; }
faalt "foutpagina is geen lege lijst" "geen contractenpagina" contracten_paginas kapot 'https://m/v1/contracts?limit=1'
geen_cursor() { printf '%s' '{"contracts":[]}'; }
faalt "respons zonder paginatieveld is geen laatste pagina" "geen contractenpagina" contracten_paginas geen_cursor 'https://m/v1/contracts?limit=1'
eindeloos() { printf '%s' '{"contracts":[],"pagination":{"next_cursor":"weer"}}'; }
faalt "eindeloze cursor breekt af" "nog een cursor" contracten_paginas eindeloos 'https://m/v1/contracts?limit=1'
pagina2_faalt() { case "$1" in *cursor=*) return 7 ;; *) printf '%s' "$PAGINA1" ;; esac; }
faalt "fout op een latere pagina is fataal" "faalde" contracten_paginas pagina2_faalt 'https://m/v1/contracts?limit=1'

# Groot genoeg om als één argument boven de Linux-grens van 128 KiB uit te komen.
GROOT=$(jq -cn --argjson c "$(contract "$H1" $VALID "$BEIDE")" \
  '{contracts: [range(0; 600) | $c | .pad = ("x" * 400)], pagination: {next_cursor: ""}}')
groot() { printf '%s' "$GROOT"; }
expect "grote lijst (> 128 KiB) gaat niet via een argument" 600 \
  "$(contracten_paginas groot 'https://m/v1/contracts?limit=1000' | jq '.contracts | length')"

# --- Thumbprint --------------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Vaste testvector, inline (alleen het cert; de sleutel is weggegooid). De verwachte waarde is
# zonder `openssl dgst` berekend: SHA-256 over de base64-gedecodeerde SubjectPublicKeyInfo.
cat >"$TMP/vector.pem" <<'PEM'
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
expect "thumbprint = SPKI-SHA256-hex van de publieke sleutel (vaste vector)" \
  edfa32b765fccd82aae11dcf3319b12e504508a866f65aceffb1a954946b520f "$(outway_thumbprint "$TMP/vector.pem")"
printf 'geen pem\n' >"$TMP/kapot.pem"
faalt "thumbprint van een niet-PEM-bestand faalt" "" outway_thumbprint "$TMP/kapot.pem"
faalt "thumbprint van een ontbrekend bestand faalt" "" outway_thumbprint "$TMP/bestaat-niet.pem"

echo
if [ "$fails" -eq 0 ]; then
  echo "== ${cases} cases groen =="
else
  echo "== ${fails} van ${cases} cases rood ==" >&2
  exit 1
fi
