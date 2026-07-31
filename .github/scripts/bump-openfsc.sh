#!/usr/bin/env bash
# Verzet de OpenFSC-versie op alle plekken die `check-openfsc-version.sh` bewaakt.
#
# Waarom dit bestaat: Dependabot kan alleen de `FROM`-regels in de drie wrapper-Dockerfiles
# verzetten. De workflow-defaults en de lokale compose zijn handwerk, dus elke gegroepeerde
# `openfsc-images`-PR komt binnen met een rode versie-guard tot iemand de rest natrekt. Dat geldt
# ook voor security-updates. Dit script maakt die follow-up één commando in plaats van zes edits.
#
# Wat dit script NIET doet: de digests in de wrapper-Dockerfiles. Die horen bij de tag en moeten
# uit de registry komen; het script laat ze staan en waarschuwt erover. Bij een Dependabot-PR heeft
# Dependabot ze al meegenomen — dan is dit script alleen nog nodig voor de overige plekken.
set -euo pipefail

cd "$(dirname "$0")/../.."

NEW="${1:-}"
case "$NEW" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Gebruik: $0 vX.Y.Z   (bv. $0 v2.5.3)" >&2; exit 2 ;;
esac

# Huidige versie uit de manager-wrapper; die is de referentie van de guard.
OLD=$(grep -oE 'federatedserviceconnectivity/manager:v[0-9]+\.[0-9]+\.[0-9]+' \
        deploy/zad/manager-migrate/Dockerfile | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$OLD" ] || { echo "FOUT: kon de huidige versie niet uit manager-migrate/Dockerfile lezen." >&2; exit 1; }

if [ "$OLD" = "$NEW" ]; then
  echo "Niets te doen: staat al op $NEW."
  exit 0
fi

echo "OpenFSC $OLD -> $NEW"

# Alleen de bewaakte bestanden, en alleen exacte versiestrings. Bewust géén repo-brede sed: docs
# houden hun historische versies (spikes, design-notities) en mogen niet meebewegen.
FILES=(
  .github/workflows/build-manager-migrate.yml
  .github/workflows/build-migrate-images.yml
  .github/workflows/zad-deploy-directory.yml
  deploy/local/docker-compose.yaml
  deploy/local/.env.example
)
while IFS= read -r dockerfile; do FILES+=("$dockerfile"); done < <(find deploy/zad -name Dockerfile | sort)

for file in "${FILES[@]}"; do
  [ -f "$file" ] || { echo "  overgeslagen (bestaat niet): $file"; continue; }
  before=$(grep -cF "$OLD" "$file" || true)
  [ "$before" -gt 0 ] || continue
  sed -i "s/${OLD//./\\.}/${NEW}/g" "$file"
  echo "  $file: $before vervanging(en)"
done

cat <<EOF

Nog met de hand doen:
  1. De digests in de wrapper-Dockerfiles onder deploy/zad/ (tag en digest horen bij elkaar; bij
     een Dependabot-PR staan ze er al goed in).
  2. docs/ bijwerken waar de versie operationeel bedoeld is (docs/zad-directory-deploy.md).
  3. Bij een sprong over een major heen: docs/openfsc-versiebeheer.md doorlopen — contract-hash,
     grant-vorm en nieuwe verplichte vlaggen.

Controleren: .github/scripts/check-openfsc-version.sh
EOF
