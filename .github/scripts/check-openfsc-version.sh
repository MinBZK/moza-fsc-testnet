#!/usr/bin/env bash
# Bewaakt dat er précies één OpenFSC-versie in deze repo rondgaat. De componenten draaien in
# lockstep, dus een halve bump laat de lokale omgeving of de group-regel iets anders draaien of
# beloven dan ZAD. Achtergrond en de lijst bewaakte plekken: docs/openfsc-versiebeheer.md.
#
# Fase A scant die plekken gericht, elk met een minimum aantal treffers: zonder ondergrens is
# "patroon matcht niets meer" niet te onderscheiden van "alles is consistent". Fase B sweept deploy/
# en .github/workflows/ op verwijzingen buiten die lijst. Fase C eist dat de workflows géén eigen
# versie dragen: die lezen 'm uit de Dockerfile. Digests en docs blijven buiten scope.
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

# Haalt de versies uit de matches van een patroon en eist er minimaal $3. Een échte grep-fout
# (exit >= 2, bv. onleesbaar bestand) mag nooit als "niets gevonden, dus niets mis" wegvallen.
scan() {  # $1=bestand $2=extended-regex $3=minimum aantal treffers
  local file="$1" pattern="$2" min="$3" body out rc match version n=0
  [ -f "$file" ] || { echo "FOUT: $file bestaat niet (guard loopt achter op de repo)" >&2; fail=1; return; }

  # Comments eruit vóór het matchen: anders geldt een uitgecommentarieerde oude waarde als bron en
  # valideert de guard documentatie in plaats van configuratie. Exit 1 is hier "alleen comments of
  # leeg" — geen leesfout; de min-check hieronder verwoordt dat correct.
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
# De patronen accepteren gequote én ongequote waarden (beide geldig in YAML), anders ontwijkt een
# cosmetische herformattering de controle.
VERSIE='v[0-9]+\.[0-9]+\.[0-9]+'

# 1. De wrapper-Dockerfiles. Ontdekken i.p.v. opsommen, zodat een nieuwe wrapper automatisch meedoet.
mapfile -t DOCKERFILES < <(find deploy/zad -name Dockerfile | sort)
if [ "${#DOCKERFILES[@]}" -lt 3 ]; then
  echo "FOUT: ${#DOCKERFILES[@]} wrapper-Dockerfile(s) gevonden onder deploy/zad, minimaal 3 verwacht." >&2
  fail=1
fi
for dockerfile in "${DOCKERFILES[@]}"; do
  scan "$dockerfile" "federatedserviceconnectivity/[a-z0-9-]+:${VERSIE}" 1
done

# 2. De lokale compose-omgeving plus de .env-template.
scan "deploy/local/docker-compose.yaml" "\\\$\\{IMAGE_TAG:-${VERSIE}\\}" 14
scan "deploy/local/.env.example" "^[[:space:]]*(export[[:space:]]+)?IMAGE_TAG=\"?${VERSIE}\"?" 1

# 3. De group-regel: `openfsc_min_version` is de versie die peer-teams moeten draaien. Loopt die
#    achter op wat wij zelf deployen, dan belooft de group-config iets anders dan het testnet doet
#    — en dat merkt niemand, want geen enkele deploy leest dit bestand. Het inline-comment op die
#    regel noemt óók een versie; het patroon ankert daarom op de sleutel.
scan "group/group-config.yaml" "openfsc_min_version:[[:space:]]*\"?${VERSIE}\"?" 1

# --- Fase B: sweep over alle OpenFSC-image-verwijzingen ---------------------------------------
echo "Sweep (alle OpenFSC-image-verwijzingen in deploy/ en .github/workflows/):"
sweep_hits=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  sweep_file=${hit%%:*}
  sweep_version=$(printf '%s' "${hit#*:}" | grep -oE "$VERSIE")
  record "sweep: $sweep_file" "$sweep_version"
  sweep_hits=$((sweep_hits + 1))
# `grep -ro` (zonder -h) levert al `bestand:treffer`, dus één boomdoorloop in plaats van één per image.
done < <(grep -roE "federatedserviceconnectivity/[a-z0-9-]+:${VERSIE}" \
           --include='*.yaml' --include='*.yml' --include='Dockerfile' \
           deploy .github/workflows 2>/dev/null \
         | sort -u)
[ "$sweep_hits" -gt 0 ] || { echo "FOUT: sweep vond geen enkele OpenFSC-image-verwijzing meer." >&2; fail=1; }

# --- Fase C: geen eigen versie in de workflows -------------------------------------------------
# De workflows leiden hun tag af via .github/scripts/openfsc-tag.sh; een literal beweegt niet mee
# met Dependabot. Bewust élke `vX.Y.Z`, niet alleen OpenFSC-tags: een versie-literal is in een
# workflow nergens nodig. Uitgezonderd zijn comments, SHA-gepinde actions (`uses: x@<sha> # vX.Y.Z`)
# en lokale `uses: ./…`. Een trailing comment telt wél mee, anders glipt `X: v1.2.3 # uses:` erdoor.
TOEGESTAAN='^[0-9]+:[[:space:]]*(#|(-[[:space:]]+)?uses:[[:space:]]*([^[:space:]@]+@[0-9a-f]{40}|\./[^[:space:]]+)([[:space:]]+#.*)?$)'
mapfile -t WORKFLOWS < <(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
[ "${#WORKFLOWS[@]}" -gt 0 ] || { echo "FOUT: geen workflows gevonden onder .github/workflows." >&2; fail=1; }
literal_hits=0
for workflow in "${WORKFLOWS[@]}"; do
  # Zelfde onderscheid als in scan(): een leesfout mag niet als "geen treffer" uitkomen.
  set +e
  numbered=$(grep -nE "$VERSIE" "$workflow")
  rc=$?
  set -e
  if [ "$rc" -ge 2 ]; then
    echo "FOUT: kon $workflow niet lezen (grep exit $rc)" >&2; fail=1; continue
  fi
  while IFS= read -r literal; do
    [ -n "$literal" ] || continue
    echo "FOUT: $workflow:${literal%%:*} draagt een eigen versie." >&2
    literal_hits=$((literal_hits + 1))
  done < <(printf '%s\n' "$numbered" | grep -vE "$TOEGESTAAN" || true)
done
echo "Workflows: ${#WORKFLOWS[@]} gescand, $literal_hits met een eigen versie."

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
fi
# Een literal los melden: bump-openfsc.sh raakt geen workflows, dus die uitweg werkt hier niet.
if [ "$literal_hits" -ne 0 ]; then
  cat >&2 <<EOF

FOUT: $literal_hits workflow-regel(s) dragen een eigen versie. Haal de literal weg en lees de versie
met \`.github/scripts/openfsc-tag.sh <Dockerfile>\` uit de wrapper-Dockerfile.
EOF
fi
if [ "$fail" -ne 0 ] || [ "$literal_hits" -ne 0 ]; then
  exit 1
fi

echo "OK: overal OpenFSC $ref (digests worden hier NIET gecontroleerd)."
