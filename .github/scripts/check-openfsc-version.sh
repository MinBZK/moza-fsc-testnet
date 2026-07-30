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
# Wat we NIET meenemen: docs. Daar staan versies met opzet in een historische context (spikes,
# design-notities, plannen); die moeten juist niet meebewegen.
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

# Haalt alle `vX.Y.Z` uit de matches van een patroon en meldt ze onder de bestandsnaam.
scan() {  # $1=bestand $2=extended-regex
  local file="$1" pattern="$2" match version
  [ -f "$file" ] || { echo "FOUT: $file bestaat niet (guard loopt achter op de repo)" >&2; fail=1; return; }
  while IFS= read -r match; do
    version=$(printf '%s' "$match" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
    record "$file" "$version"
  done < <(grep -hoE "$pattern" "$file" || true)
}

echo "OpenFSC-versies in de deploy-configuratie:"

# 1. De wrapper-Dockerfiles: `FROM …/<component>:vX.Y.Z@sha256:…`
for component in manager controller txlog; do
  scan "deploy/zad/${component}-migrate/Dockerfile" \
    'federatedserviceconnectivity/[a-z-]+:v[0-9]+\.[0-9]+\.[0-9]+'
done

# 2. De build-workflows: de output-tag van de wrapper-images (input-default + fallback in de run).
for workflow in build-manager-migrate build-migrate-images; do
  scan ".github/workflows/${workflow}.yml" \
    'default: "v[0-9]+\.[0-9]+\.[0-9]+"|image_tag \|\| .v[0-9]+\.[0-9]+\.[0-9]+.'
done

# 3. De deploy-workflow: de stock-tag waarmee directory-ui en de manager gedeployd worden.
scan ".github/workflows/zad-deploy-directory.yml" 'IMAGE_TAG_DEFAULT: v[0-9]+\.[0-9]+\.[0-9]+'

# 4. De lokale compose-omgeving: `${IMAGE_TAG:-vX.Y.Z}` plus de .env-template.
scan "deploy/local/docker-compose.yaml" '\$\{IMAGE_TAG:-v[0-9]+\.[0-9]+\.[0-9]+\}'
scan "deploy/local/.env.example" '^IMAGE_TAG=v[0-9]+\.[0-9]+\.[0-9]+'

if [ -z "$ref" ]; then
  echo "FOUT: geen enkele OpenFSC-versie gevonden — de patronen hierboven matchen niets meer." >&2
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  cat >&2 <<EOF

FOUT: niet alle OpenFSC-versies zijn gelijk (referentie: $ref, uit $refsrc).
Bump ze samen: de drie wrapper-Dockerfiles (tag én digest), de workflow-defaults en de lokale
compose/.env.example. Zie contracts/bootstrap.md voor wat een v1.x -> v2.x-sprong verder vergt.
EOF
  exit 1
fi

echo "OK: overal OpenFSC $ref."
