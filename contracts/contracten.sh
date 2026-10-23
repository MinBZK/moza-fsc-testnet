#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Gedeelde bouwstenen voor contracts/bootstrap.sh en deploy/local/smoke-contract.sh: het
# serviceConnection-contract van één combinatie terugvinden in de contractenlijst van een manager.
#
# De contracten zelf zijn de bron van waarheid, niet een lokaal state-bestand: een deploy start met
# een lege schijf, dus een onthouden hash is daar elke run weg en elke run zou er een contract
# bijmaken. Bootstrap en smoke gebruiken dezelfde matcher, zodat "bestaand" in beide hetzelfde
# betekent.
#
# Sourcen, niet uitvoeren. Vereist jq.

# outway_thumbprint <cert.pem>: SPKI-SHA256-hex van de publieke sleutel op stdout.
#
# Het GROUP-cert van de outway, niet het internal-cert: de outway meldt zich met zijn group-cert bij
# zijn controller, en de manager matcht dat thumbprint tegen de grant. Stabiel bij cert-rotatie
# binnen hetzelfde sleutelpaar.
outway_thumbprint() {
  local thumb
  thumb=$(openssl x509 -in "$1" -pubkey -noout \
            | openssl pkey -pubin -outform DER \
            | openssl dgst -sha256 -r | cut -d' ' -f1) || return 1

  # Negatief patroon: `[0-9a-f]*` als case-glob toetst alleen het eerste teken.
  case "$thumb" in
    ""|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#thumb}" -eq 64 ] || return 1

  printf '%s' "$thumb"
}

# contracten_paginas <ophaler> <basis-url>: alle contracten over alle pagina's, als één
# `{"contracts":[...]}`-object op stdout. <ophaler> is een functie die één URL ophaalt.
#
# De lijst is cursor-gepagineerd (default 100) en bevat ook publicatie-, ingetrokken en andermans
# contracten; valt ons contract van pagina 1, dan zou de bootstrap het niet meer zien en opnieuw
# indienen. OpenFSC zet `next_cursor` op élke pagina met rijen, ook als die de hele lijst is: een
# cursor betekent "er kán meer zijn". Daarom doorlezen tot de cursor leeg is.
contracten_paginas() {
  local ophaler="$1" basis="$2" cursor="" url body pagina alle="[]" ronde=0

  while :; do
    url="$basis"
    [ -z "$cursor" ] || url="${basis}&cursor=$(printf '%s' "$cursor" | jq -sRr @uri)"

    body=$("$ophaler" "$url") || return 1

    # Geen `.contracts[]?`: een respons zonder contractenlijst (ander schema, foutpagina, lege
    # body) moet stuk, niet als "geen contracten" doorgaan — anders dient de bootstrap opnieuw in.
    pagina=$(printf '%s' "$body" | jq -ce '.contracts | arrays') || {
      echo "respons is geen contractenlijst: ${body:0:200}" >&2; return 1; }
    alle=$(jq -cn --argjson a "$alle" --argjson b "$pagina" '$a + $b') || return 1

    cursor=$(printf '%s' "$body" | jq -r '.pagination.next_cursor? // .next_cursor? // ""') || return 1
    [ -n "$cursor" ] || break

    # Rem tegen een server die eindeloos een cursor blijft zetten.
    ronde=$((ronde + 1))
    [ "$ronde" -lt 100 ] || { echo "contractenlijst geeft na ${ronde} pagina's nog een cursor" >&2; return 1; }
  done

  jq -cn --argjson c "$alle" '{contracts: $c}'
}

# contract_voor_combinatie <json> <service> <provider_oin> <consumer_oin> <thumbprint>:
# per niet-ingetrokken contract van precies deze serviceConnection één regel
#   <hash> <state> <provider-getekend ja|nee> <afgewezen|->
# gesorteerd op hash, zodat "de eerste" over runs heen hetzelfde contract is.
#
# De identiteit is service + provider + consumer-outway + thumbprint samen. Alleen op servicenaam
# matchen volstaat niet: het servicePublication-contract voor dezelfde dienst staat op dezelfde
# managers en zou dan altijd meetellen. "Precies één grant": een contract met extra grants is niet
# het onze, ook al zit onze grant erin.
contract_voor_combinatie() {
  printf '%s' "$1" | jq -r --arg svc "$2" --arg prov "$3" --arg cons "$4" --arg thumb "$5" '
    if (.contracts | type) != "array" then error("respons is geen contractenlijst") else .contracts[] end
    | select(type == "object" and (.has_revoked // false) == false)
    # Het hash gaat later een URL-pad in (accept/revoke); alleen de FSC-vorm `$1$<n>$<base64url>`.
    | select(.hash | strings | test("^\\$1\\$[0-9]+\\$[A-Za-z0-9_=-]+$"))
    # try: één misvormde rij van een andere peer mag de rest van de lijst niet meenemen.
    | select(try (.content.grants | length == 1 and (.[0]
        | .type == "GRANT_TYPE_SERVICE_CONNECTION"
          and .service.name == $svc
          and .service.peer_id == $prov
          and .outway.peer_id == $cons
          and .outway.identification.public_key_thumbprint == $thumb)) catch false)
    | "\(.hash) \((.state // "ontbreekt") | tostring | ascii_downcase) \(if ((.signatures.accept // {}) | has($prov)) then "ja" else "nee" end) \(if (.has_rejected // false) then "afgewezen" else "-" end)"
  ' | sort
}

# geldige_contracten <regels>: de hashes uit contract_voor_combinatie die wederzijds getekend en
# 'valid' zijn op de manager waarvan de lijst kwam.
geldige_contracten() {
  printf '%s' "${1:-}" | awk '$2 == "contract_state_valid" && $3 == "ja" && $4 == "-" { print $1 }'
}
