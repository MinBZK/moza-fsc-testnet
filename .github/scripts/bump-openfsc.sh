#!/usr/bin/env bash
# Verzet de OpenFSC-versie op alle plekken die `check-openfsc-version.sh` bewaakt.
#
# Dependabot raakt alleen de `FROM`-regels in de wrapper-Dockerfiles; de workflow-defaults en de
# lokale compose zijn handwerk, dus elke gegroepeerde `openfsc-images`-PR komt anders binnen met een
# rode guard — ook een security-update. Digests laat dit script staan: die moeten uit de registry
# komen. Zie docs/openfsc-versiebeheer.md.
set -euo pipefail

cd "$(dirname "$0")/../.."

NEW="${1:-}"
# Strikte match, geen glob: de waarde gaat ongeëscapet een `sed`-vervanging in, waar `&` de hele
# match herhaalt en `/` het commando afbreekt. Een glob laat die tekens door en schrijft ze stil weg.
if ! [[ "$NEW" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Gebruik: $0 vX.Y.Z   (bv. $0 v2.5.3)" >&2
  exit 2
fi

# Onderscheidt "staat er niet in" (grep exit 1) van een échte leesfout (exit >= 2). Zonder dat
# onderscheid is een onleesbaar bestand niet te zien van een bestand zonder treffer.
version_in() {  # $1=bestand $2=extended-regex
  local out rc
  set +e; out=$(grep -oE "$2" "$1"); rc=$?; set -e
  [ "$rc" -lt 2 ] || { echo "FOUT: kon $1 niet lezen (grep exit $rc)." >&2; exit 1; }
  printf '%s' "$out" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true
}

# Huidige versie uit de group-regel. Bewust niet uit een wrapper-Dockerfile: Dependabot heeft die
# op een `openfsc-images`-PR al verzet, en dan leest dit script de nieuwe versie als de oude en doet
# het niets — precies op de PR waarvoor het bestaat.
OLD=$(version_in group/group-config.yaml 'openfsc_min_version:[[:space:]]*"?v[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$OLD" ] || {
  echo "FOUT: geen openfsc_min_version in group/group-config.yaml — de sleutel is hernoemd of weg." >&2
  exit 1
}

if [ "$OLD" = "$NEW" ]; then
  echo "De group-regel staat al op $NEW; dit script verzet niets meer."
  echo "Loopt er elders nog een oude versie rond, dan wijst .github/scripts/check-openfsc-version.sh 'm aan."
  exit 0
fi

echo "OpenFSC $OLD -> $NEW"

# Bewust géén repo-brede sed: docs houden hun historische versies en mogen niet meebewegen.
FILES=(
  .github/workflows/build-manager-migrate.yml
  .github/workflows/build-migrate-images.yml
  .github/workflows/zad-deploy-directory.yml
  deploy/local/docker-compose.yaml
  deploy/local/.env.example
)

# Wrappers ontdekken i.p.v. opsommen, zodat een nieuwe wrapper vanzelf meedoet. De ondergrens vangt
# af dat `find` niets meer vindt: nul treffers is anders niet te zien van "er zijn er geen".
mapfile -t WRAPPERS < <(find deploy/zad -name Dockerfile | sort)
[ "${#WRAPPERS[@]}" -ge 3 ] || {
  echo "FOUT: ${#WRAPPERS[@]} wrapper-Dockerfile(s) onder deploy/zad, minimaal 3 verwacht." >&2
  exit 1
}
FILES+=("${WRAPPERS[@]}")

# De group-regel als laatste: dat is de plek waaruit dit script zijn referentie leest. Breekt een
# run halverwege af, dan staat die er nog op de oude versie en maakt een volgende run het alsnog af.
FILES+=(group/group-config.yaml)

for file in "${FILES[@]}"; do
  [ -f "$file" ] || { echo "FOUT: bewaakte plek ontbreekt: $file" >&2; exit 1; }

  set +e; before=$(grep -cF "$OLD" "$file"); rc=$?; set -e
  [ "$rc" -lt 2 ] || { echo "FOUT: kon $file niet lezen (grep exit $rc)." >&2; exit 1; }

  if [ "$before" -eq 0 ]; then
    # Geen treffer is alleen onschuldig als deze plek al op $NEW staat (dat doet Dependabot in de
    # wrappers). Een derde versie is de halve bump die dit script juist hoort weg te nemen, dus
    # daar stil overheen lopen zou een geslaagde bump melden die er geen is.
    grep -qF "$NEW" "$file" || {
      echo "FOUT: $file draagt $OLD noch $NEW — deze plek loopt op een derde versie." >&2
      exit 1
    }
    echo "  $file: stond al op $NEW"
    continue
  fi

  sed -i "s/${OLD//./\\.}/${NEW}/g" "$file"
  # `sed -i` is stil als het niets vervangt; zonder deze controle zou een verlopen patroon of een
  # read-only bestand als geslaagd doorgaan.
  ! grep -qF "$OLD" "$file" || {
    echo "FOUT: $OLD staat na de vervanging nog in $file." >&2
    exit 1
  }
  echo "  $file: $before regel(s) verzet"
done

cat <<EOF

Nog met de hand doen:
  1. De digests in de wrapper-Dockerfiles onder deploy/zad/ (tag en digest horen bij elkaar; bij
     een Dependabot-PR staan ze er al goed in). Docker resolvet op de digest, dus een oude digest
     onder een nieuwe tag draait stil de oude versie.
  2. docs/ bijwerken waar de versie operationeel bedoeld is (docs/zad-directory-deploy.md).
  3. Bij een sprong over een major heen: docs/openfsc-versiebeheer.md doorlopen — contract-hash,
     grant-vorm en nieuwe verplichte vlaggen.

Controleren: .github/scripts/check-openfsc-version.sh
EOF
