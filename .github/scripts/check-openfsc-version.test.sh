#!/usr/bin/env bash
# Regressietest voor check-openfsc-version.sh: een guard die stil groen blijft is erger dan geen
# guard, want dan is de handmatige controle weggeorganiseerd zonder vervanging. Elke case hieronder
# is een mutatie die de guard rood hoort te maken.
#
# Werking: kopieer de WERKBOOM (niet HEAD — je toetst wat je op het punt staat te committen) naar
# een tijdelijke map en muteer daar één ding. De guard doet zelf `cd "$(dirname "$0")/../.."` en
# draait dus vanzelf tegen de kopie.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fails=0
cases=0

# Zet een verse kopie van de werkboom neer en echoot het pad. Draait in een command-substitution
# (subshell), dus tellen gebeurt bewust in expect() — een teller hier zou nooit doorwerken.
fresh_copy() {
  local dst; dst="$TMP_ROOT/case-$(date +%s%N)-$RANDOM"
  mkdir -p "$dst"
  # --others --exclude-standard: neem óók ongestagede bestanden mee. Met alleen `--cached` valt een
  # nieuw wrapper-Dockerfile buiten de kopie — precies het geval waar de guard voor bestaat.
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard \
     | tar --null -T - -cf -) | tar -xf - -C "$dst"
  printf '%s' "$dst"
}

# $1=omschrijving $2=verwachte exitcode $3=werkboomkopie
expect() {
  local desc="$1" want="$2" dir="$3" got=0
  cases=$((cases + 1))
  "$dir/.github/scripts/check-openfsc-version.sh" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    %s (exit %s)\n' "$desc" "$got"
  else
    printf 'FAAL  %s: verwacht exit %s, kreeg %s\n' "$desc" "$want" "$got" >&2
    fails=$((fails + 1))
  fi
}

echo "Regressietest check-openfsc-version.sh"

# --- 0. De ongewijzigde werkboom hoort groen te zijn -------------------------------------------
d=$(fresh_copy)
expect "ongewijzigde werkboom is groen" 0 "$d"

# --- 1. Versie-skew in een wrapper-Dockerfile (de basisfunctie) --------------------------------
d=$(fresh_copy)
sed -i 's|txlog-api:v[0-9.]*|txlog-api:v1.43.7|' "$d/deploy/zad/txlog-migrate/Dockerfile"
expect "skew in txlog-migrate/Dockerfile" 1 "$d"

# --- 2. Gequote waarde: cosmetische YAML-herformattering mag de guard niet ontwijken -----------
d=$(fresh_copy)
sed -i 's|IMAGE_TAG_DEFAULT: v[0-9.]*|IMAGE_TAG_DEFAULT: "v1.43.7"|' "$d/.github/workflows/zad-deploy-directory.yml"
expect "gequote IMAGE_TAG_DEFAULT met oude versie" 1 "$d"

# --- 3. Ontquote workflow-default ---------------------------------------------------------------
d=$(fresh_copy)
sed -i '0,/default: "v[0-9.]*"/s||default: v1.43.7|' "$d/.github/workflows/build-manager-migrate.yml"
expect "ontquote workflow-default met oude versie" 1 "$d"

# --- 4. Hernoemde compose-variabele: alle 14 images vallen in één klap buiten beeld ------------
d=$(fresh_copy)
sed -i 's|${IMAGE_TAG:-|${OPENFSC_TAG:-|g' "$d/deploy/local/docker-compose.yaml"
expect "hernoemde compose-variabele (patroon verlopen)" 1 "$d"

# --- 5. `export`-vorm in .env.example met een oude versie --------------------------------------
d=$(fresh_copy)
sed -i 's|^IMAGE_TAG=.*|export IMAGE_TAG=v1.43.7|' "$d/deploy/local/.env.example"
expect "export IMAGE_TAG met oude versie" 1 "$d"

# --- 6. Nieuwe wrapper die niet in een hardgecodeerde lijst zou staan --------------------------
d=$(fresh_copy)
mkdir -p "$d/deploy/zad/inway-migrate"
cat > "$d/deploy/zad/inway-migrate/Dockerfile" <<'DOCKERFILE'
FROM docker.io/federatedserviceconnectivity/inway:v1.43.7@sha256:0000000000000000000000000000000000000000000000000000000000000000
DOCKERFILE
expect "nieuwe wrapper op een oude versie" 1 "$d"

# --- 7. Hardgecodeerde image in compose (fase A ziet alleen de variabele-vorm) -----------------
d=$(fresh_copy)
python3 - "$d/deploy/local/docker-compose.yaml" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r'federatedserviceconnectivity/inway:\$\{IMAGE_TAG:-[^}]*\}',
           'federatedserviceconnectivity/inway:v1.43.7', t, count=1)
open(p, 'w').write(t)
PY
expect "hardgecodeerde oude image in compose (sweep)" 1 "$d"

# --- 8. Leeg Dockerfile: pin volledig weg -------------------------------------------------------
d=$(fresh_copy)
: > "$d/deploy/zad/txlog-migrate/Dockerfile"
expect "leeg wrapper-Dockerfile (pin weg)" 1 "$d"

# --- 9. Uitgecommentarieerde nieuwe versie naast een live oude ---------------------------------
d=$(fresh_copy)
sed -i 's|^\(  IMAGE_TAG_DEFAULT: \)v[0-9.]*|  # was: \1v2.5.2\n\1v1.43.7|' \
  "$d/.github/workflows/zad-deploy-directory.yml"
expect "comment mag niet als bron gelden" 1 "$d"

# --- 10. Bewaakt bestand verdwenen --------------------------------------------------------------
d=$(fresh_copy)
rm -f "$d/deploy/local/.env.example"
expect "bewaakt bestand verwijderd" 1 "$d"

echo
if [ "$fails" -ne 0 ]; then
  echo "REGRESSIETEST ROOD: $fails case(s) gefaald." >&2
  exit 1
fi
echo "Regressietest groen: alle $cases cases."
