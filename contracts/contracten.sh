#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Gedeelde bouwstenen voor contracts/bootstrap.sh en deploy/local/smoke-contract.sh: het
# serviceConnection-contract van één combinatie terugvinden in de contractenlijst van een manager.
# Waarom de contracten zelf de bron van waarheid zijn: zie contracts/bootstrap.md.
#
# Sourcen, niet uitvoeren. Vereist jq. Leunt niet op `pipefail` van de aanroeper.

# FSC-contract- en grant-hash: `$<algoritme>$<type>$<base64url zonder padding>` (OpenFSC
# hash.go, RawURLEncoding). Gaat ongewijzigd een URL-pad in, dus geen `/`, `.` of witruimte.
FSC_HASH_RE='\A\$[0-9]+\$[0-9]+\$[A-Za-z0-9_-]+\z'

# hash_ok <waarde>: heeft dit hash de FSC-vorm?
hash_ok() {
  jq -ne --arg h "${1:-}" --arg re "$FSC_HASH_RE" '$h | test($re)' >/dev/null
}

# outway_thumbprint <cert.pem>: SPKI-SHA256-hex van de publieke sleutel op stdout.
#
# Het GROUP-cert van de outway, niet het internal-cert: de outway meldt zich met zijn group-cert bij
# zijn controller, en de manager matcht dat thumbprint tegen de grant. Host-side openssl, want de
# toolbox heeft geen openssl-CLI.
outway_thumbprint() {
  local pub thumb
  # PIPESTATUS i.p.v. pipefail: zonder die controle levert een mislukte stap de SHA-256 van lege
  # invoer op, een geldig ogende thumbprint die nergens bij hoort.
  pub=$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null) && [ -n "$pub" ] || return 1
  thumb=$(printf '%s\n' "$pub" | openssl pkey -pubin -outform DER | openssl dgst -sha256 -r
          s=("${PIPESTATUS[@]}"); [ "${s[1]}" -eq 0 ] && [ "${s[2]}" -eq 0 ]) || return 1
  thumb=${thumb%% *}

  # Negatief patroon: `[0-9a-f]*` als case-glob toetst alleen het eerste teken.
  case "$thumb" in
    ""|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#thumb}" -eq 64 ] || return 1

  printf '%s' "$thumb"
}

# contracten_paginas <ophaler> <basis-url-met-query>: alle contracten over alle pagina's, als één
# `{"contracts":[...]}`-object op stdout. <ophaler> is een functie die één URL ophaalt.
#
# Valt ons contract van pagina 1, dan zou de bootstrap het niet meer zien en opnieuw indienen.
# OpenFSC zet `next_cursor` op élke pagina met rijen, ook als die de hele lijst is: een cursor
# betekent "er kán meer zijn". Daarom doorlezen tot de cursor leeg is.
contracten_paginas() {
  local ophaler="$1" basis="$2" cursor="" url body paginas="" ronde=0

  while :; do
    url="$basis"
    [ -z "$cursor" ] || url="${basis}&cursor=$(printf '%s' "$cursor" | jq -sRr @uri)"

    body=$("$ophaler" "$url") || {
      echo "ophalen van ${url} faalde: ${body:0:300}" >&2; return 1; }

    # Geen `.contracts[]?` of `// ""`: een respons zonder contractenlijst of zonder paginatieveld
    # (ander schema, foutpagina, lege body) moet stuk, niet als "geen (verdere) contracten"
    # doorgaan — anders dient de bootstrap opnieuw in.
    cursor=$(printf '%s' "$body" | jq -er '
      if (.contracts | type) != "array" then error("geen contractenlijst")
      elif (.pagination.next_cursor | type) != "string" then error("geen pagination.next_cursor")
      else .pagination.next_cursor end') || {
      echo "respons is geen contractenpagina: ${body:0:300}" >&2; return 1; }
    paginas+="$body"$'\n'
    [ -n "$cursor" ] || break

    # Rem tegen een server die eindeloos een cursor blijft zetten.
    ronde=$((ronde + 1))
    [ "$ronde" -lt 100 ] || { echo "contractenlijst geeft na ${ronde} pagina's nog een cursor" >&2; return 1; }
  done

  # Via stdin, niet via `--argjson`: één argument mag op Linux hoogstens 128 KiB zijn.
  printf '%s' "$paginas" | jq -cs '{contracts: (map(.contracts) | add // [])}'
}

# contract_voor_combinatie <json> <service> <provider_oin> <consumer_oin> <thumbprint> <group_id>:
# per contract van precies deze serviceConnection één regel
#   <hash> <state> <provider-getekend ja|nee> <consumer-getekend ja|nee> <grant-hash>
# met <state> lowercase (`contract_state_valid`, `…_proposed`, `…_rejected`, `…_revoked`) of
# `ontbreekt`. Weggelaten: verlopen contracten en contracten die deze manager zélf introk.
# Oudste eerst (created_at, dan hash): bij duplicaten blijft zo het contract staan dat het langst
# bestaat en dus het meest waarschijnlijk al via zijn grant-hash in gebruik is.
#
# De identiteit is service + provider + consumer-outway + thumbprint samen, in een contract met
# precies één grant, zonder grant-properties, in onze group en met ons hash-algoritme. Een contract
# dat daar afwijkt (bv. via de controller-UI opgesteld) is niet het onze: afmaken zou iets tekenen
# dat wij niet opstelden, en een contract uit een andere group wijst de inway af.
#
# Afwijzen en intrekken lezen we uit `.state`; `has_rejected`/`has_revoked` zeggen alleen of de
# manager zélf getekend heeft. Een intrekking door de ándere peer blijft dus zichtbaar als
# `…_revoked`: dat is een besluit, geen leeg veld om opnieuw in te vullen.
contract_voor_combinatie() {
  local uit
  # jq draait niet op lege invoer (exit 0, geen uitvoer): dat zou als "geen contracten" lezen.
  case "${1:-}" in *[![:space:]]*) ;; *) echo "lege contractenlijst-respons" >&2; return 1 ;; esac
  uit=$(printf '%s' "$1" | jq -r --arg svc "$2" --arg prov "$3" --arg cons "$4" --arg thumb "$5" --arg group "$6" \
          --arg re "$FSC_HASH_RE" '
    def getekend($oin): if ((.signatures.accept // {}) | has($oin)) then "ja" else "nee" end;
    if (.contracts | type) != "array" then error("respons is geen contractenlijst") else .contracts end
    | map(select(type == "object"
        # try: één misvormde rij van een andere peer mag de rest van de lijst niet meenemen.
        and (try (.content.group_id == $group and .content.hash_algorithm == "HASH_ALGORITHM_SHA3_512"
              and (.content.grants | length == 1) and (((.content.grants[0].properties // {}) | length) == 0)
              and (.content.grants[0]
              | .type == "GRANT_TYPE_SERVICE_CONNECTION"
                and .service.type == "SERVICE_TYPE_SERVICE"
                and .service.name == $svc
                and .service.peer_id == $prov
                and .outway.peer_id == $cons
                and .outway.identification.public_key_thumbprint == $thumb)) catch false)))
    | map(. + {st: ((.state // "ontbreekt") | tostring | ascii_downcase)})
    # OpenFSC laat een voorgesteld contract na not_after `proposed`; afmaken loopt dan vast.
    | map(if .st == "contract_state_proposed" and ((.content.validity.not_after? // infinite) <= now)
          then .st = "contract_state_expired" else . end)
    | map(select(.st != "contract_state_expired" and (.has_revoked // false) == false))
    | sort_by([(.content.created_at // 0), .hash])
    | .[]
    # Een eigen contract met een onverwacht hash stil overslaan zou elke run een nieuw opleveren.
    | if ((.hash | type) != "string") or ((.hash | test($re)) | not)
        or ((.content.grants[0].hash // "") | test($re) | not)
      then error("contract voor deze combinatie met onverwacht hash: \(.hash | tostring)")
      else "\(.hash) \(.st) \(getekend($prov)) \(getekend($cons)) \(.content.grants[0].hash)"
      end') || return 1
  [ -z "$uit" ] || printf '%s\n' "$uit"
}

# geldige_contracten <regels>: de hashes die 'valid' zijn met beide accept-handtekeningen.
# Oudste eerst.
geldige_contracten() {
  printf '%s' "${1:-}" | awk '$2 == "contract_state_valid" && $3 == "ja" && $4 == "ja" { print $1 }'
}

# lopende_contracten <regels>: voorgesteld, nog niet geldig. Oudste eerst.
lopende_contracten() {
  printf '%s' "${1:-}" | awk '$2 == "contract_state_proposed" { print $1 }'
}

# beeindigde_contracten <regels>: door een van beide peers afgewezen, of door de andere ingetrokken.
beeindigde_contracten() {
  printf '%s' "${1:-}" | awk '$2 == "contract_state_rejected" || $2 == "contract_state_revoked" { print $1 }'
}

# onbekende_contracten <regels>: regels die in geen van de categorieën hierboven passen (state
# ontbreekt of is nieuw, of 'valid' zonder beide handtekeningen). De aanroeper hoort hierop te
# stoppen in plaats van te gokken.
onbekende_contracten() {
  printf '%s' "${1:-}" | awk '
    !(($2 == "contract_state_valid" && $3 == "ja" && $4 == "ja") || $2 == "contract_state_proposed" \
      || $2 == "contract_state_rejected" || $2 == "contract_state_revoked")'
}

# consumer_getekend <regels> <contract-hash>: draagt dat contract de consumer-handtekening?
consumer_getekend() {
  printf '%s' "${1:-}" | awk -v h="$2" '$1 == h && $4 == "ja" { f = 1 } END { exit !f }'
}

# grant_hash_van <regels> <contract-hash>: de grant-hash (voor `Fsc-Grant-Hash`) van dat contract.
grant_hash_van() {
  printf '%s' "${1:-}" | awk -v h="$2" '$1 == h { print $5; exit }'
}
