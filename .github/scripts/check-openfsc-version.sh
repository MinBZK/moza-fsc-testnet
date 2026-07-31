#!/usr/bin/env bash
# Bewaakt dat er in deze repo précies één OpenFSC-versie rondgaat.
#
# Waarom: OpenFSC releaset manager/controller/txlog-api/inway/outway/directory-ui in lockstep onder
# één versietag, en ze moeten ook in lockstep dráaien — de contract-hash en de grant-vorm zijn
# versiegebonden. Een halve bump (bijvoorbeeld een Dependabot-PR die alleen een base-image in één
# wrapper-Dockerfile verzet) levert een group op die niet meer met zichzelf praat. Erger nog: de
# wrapper-images krijgen hun output-tag uit de workflow-default, dus een halve bump publiceert een
# image dat v-oud heet en v-nieuw ís.
#
# De guard werkt in twee fasen, omdat één ervan niet volstaat:
#   A. GERICHTE SCANS op de plekken waar de versie hoort te staan, elk met een minimum aantal
#      treffers. Zonder dat minimum is "patroon matcht niets meer" niet te onderscheiden van
#      "alles is consistent" — dan roest de dekking stil weg bij een hernoeming of herformattering.
#   B. EEN SWEEP over alle OpenFSC-image-verwijzingen in deploy/ en .github/workflows/. Fase A kent
#      alleen de plekken die hieronder staan; de sweep vangt een verwijzing die iemand érgens anders
#      neerzet (nieuwe wrapper, hardgecodeerde image in compose).
#
# Comments worden vóór het matchen gestript: anders kan een uitgecommentarieerde oude waarde als
# geldige bron gaan gelden en valideert de guard documentatie in plaats van configuratie.
#
# LET OP — wat deze guard NIET controleert: de digest. De wrapper-Dockerfiles pinnen
# `repo:tag@digest`; Docker resolvet dan op de digest en negeert de tag. Een juiste tag naast een
# oude digest is hier dus onzichtbaar. Dat vergt een registry-lookup en hoort in een aparte,
# netwerk-afhankelijke controle — zie docs/openfsc-versiebeheer.md.
#
# Docs doen niet mee: daar staan versies met opzet in een historische context (spikes, design-
# notities, plannen); die moeten juist niet meebewegen.
set -euo pipefail

cd "$(dirname "$0")/../.."

fail=0
ref=""
refsrc=""

# Legt een gevonden versie vast en vergelijkt 'm met de eerste vondst.
record() {  # $1=bron $2=versie
  printf '  %-58s %s\n' "$1" "$2"
  if [ -z "$ref" ]; then
    ref="$2"; refsrc="$1"
  elif [ "$2" != "$ref" ]; then
    fail=1
  fi
}

# Haalt de versies uit de matches van een patroon en eist er minimaal $3.
# Onderscheidt "geen match" (grep exit 1) van een échte grep-fout (exit >= 2, bv. onleesbaar
# bestand): dat laatste mag nooit als "niets gevonden, dus niets mis" wegvallen.
scan() {  # $1=bestand $2=extended-regex $3=minimum aantal treffers
  local file="$1" pattern="$2" min="$3" body out rc match version n=0
  [ -f "$file" ] || { echo "FOUT: $file bestaat niet (guard loopt achter op de repo)" >&2; fail=1; return; }

  # Exit 1 betekent hier "alleen comments of leeg" — geen leesfout. Dat mag niet als leesfout
  # gemeld worden: de min-check hieronder verwoordt het correct ("0 treffers, minimaal N verwacht").
  set +e
  body=$(grep -vE '^[[:space:]]*#' "$file")
  rc=$?
  set -e
  if [ "$rc" -ge 2 ]; then
    echo "FOUT: kon $file niet lezen (grep exit $rc)" >&2; fail=1; return
  fi

  set +e
  out=$(printf '%s\n' "$body" | grep -oE "$pattern")
  rc=$?
  set -e
  if [ "$rc" -ge 2 ]; then
    echo "FOUT: grep faalde (exit $rc) op $file" >&2; fail=1; return
  fi

  while IFS= read -r match; do
    [ -n "$match" ] || continue
    version=$(printf '%s' "$match" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
    record "$file" "$version"
    n=$((n + 1))
  done <<<"$out"

  if [ "$n" -lt "$min" ]; then
    echo "FOUT: $file leverde $n treffer(s), minimaal $min verwacht — het patroon of het bestand" \
         "is verlopen, dus deze plek wordt niet meer bewaakt." >&2
    fail=1
  fi
}

echo "OpenFSC-versies in de deploy-configuratie:"

# --- Fase A: gerichte scans -------------------------------------------------------------------
# Waarden mogen wel/niet gequote zijn (beide geldig in YAML), anders ontwijkt een cosmetische
# herformattering de controle.
VERSIE='v[0-9]+\.[0-9]+\.[0-9]+'

# 1. De wrapper-Dockerfiles: `FROM …/<component>:vX.Y.Z@sha256:…`. Ontdekken i.p.v. opsommen, zodat
#    een nieuwe wrapper automatisch meedoet in plaats van stilzwijgend buiten de guard te vallen.
mapfile -t DOCKERFILES < <(find deploy/zad -name Dockerfile | sort)
if [ "${#DOCKERFILES[@]}" -lt 3 ]; then
  echo "FOUT: ${#DOCKERFILES[@]} wrapper-Dockerfile(s) gevonden onder deploy/zad, minimaal 3 verwacht." >&2
  fail=1
fi
for dockerfile in "${DOCKERFILES[@]}"; do
  scan "$dockerfile" "federatedserviceconnectivity/[a-z0-9-]+:${VERSIE}" 1
done

# 2. De build-workflows: de output-tag van de wrapper-images (input-defaults + fallback in de run).
#    build-manager-migrate heeft er drie (dispatch + workflow_call + fallback), build-migrate-images
#    twee (dispatch + fallback).
scan ".github/workflows/build-manager-migrate.yml" \
  "default:[[:space:]]*\"?${VERSIE}\"?|image_tag \|\| '${VERSIE}'" 3
scan ".github/workflows/build-migrate-images.yml" \
  "default:[[:space:]]*\"?${VERSIE}\"?|image_tag \|\| '${VERSIE}'" 2

# 3. De deploy-workflow: de stock-tag voor `dirui`, tevens default-tag voor de manager-wrapper.
scan ".github/workflows/zad-deploy-directory.yml" \
  "IMAGE_TAG_DEFAULT:[[:space:]]*\"?${VERSIE}\"?" 1

# 4. De lokale compose-omgeving plus de .env-template.
scan "deploy/local/docker-compose.yaml" "\\\$\\{IMAGE_TAG:-${VERSIE}\\}" 14
scan "deploy/local/.env.example" "^[[:space:]]*(export[[:space:]]+)?IMAGE_TAG=\"?${VERSIE}\"?" 1

# --- Fase B: sweep over alle OpenFSC-image-verwijzingen ---------------------------------------
# Vangt een verwijzing buiten de plekken hierboven: een hardgecodeerde image in compose, een nieuwe
# workflow, een wrapper op een pad dat fase A niet kent.
echo "Sweep (alle OpenFSC-image-verwijzingen in deploy/ en .github/workflows/):"
sweep_hits=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  sweep_file=${hit%%:*}
  sweep_version=$(printf '%s' "${hit#*:}" | grep -oE "$VERSIE")
  record "sweep: $sweep_file" "$sweep_version"
  sweep_hits=$((sweep_hits + 1))
# `grep -ro` (zonder -h) levert al `bestand:treffer` — één boomdoorloop. Een eerdere vorm haalde
# eerst de unieke images op en zocht daarna per image nogmaals de hele boom af; dat leverde
# hetzelfde resultaat met N+1 doorlopen in plaats van één.
done < <(grep -roE "federatedserviceconnectivity/[a-z0-9-]+:${VERSIE}" \
           --include='*.yaml' --include='*.yml' --include='Dockerfile' \
           deploy .github/workflows 2>/dev/null \
         | sort -u)
[ "$sweep_hits" -gt 0 ] || { echo "FOUT: sweep vond geen enkele OpenFSC-image-verwijzing meer." >&2; fail=1; }

# --- Uitslag ------------------------------------------------------------------------------------
if [ -z "$ref" ]; then
  echo "FOUT: geen enkele OpenFSC-versie gevonden — de patronen hierboven matchen niets meer." >&2
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  cat >&2 <<EOF

FOUT: de OpenFSC-versies lopen uiteen, of een bewaakte plek is uit beeld geraakt
(referentie: $ref, uit $refsrc).
Bump ze samen — \`.github/scripts/bump-openfsc.sh <versie>\` doet de tags in één keer; de digests in
de drie wrapper-Dockerfiles blijven handwerk. Zie contracts/bootstrap.md voor wat een
v1.x -> v2.x-sprong verder vergt.
EOF
  exit 1
fi

echo "OK: overal OpenFSC $ref (digests worden hier NIET gecontroleerd)."
