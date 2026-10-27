#!/usr/bin/env bash
# Regressietest voor check-openfsc-version.sh: een guard die stil groen blijft is erger dan geen
# guard, want dan is de handmatige controle weggeorganiseerd zonder vervanging. Elke case hieronder
# is een mutatie met een verwachte uitslag: de meeste horen rood te zijn, een paar bewaken juist
# een uitzondering die groen moet blijven.
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

# --- 2. Eigen versie in een workflow-env: beweegt niet mee met Dependabot ----------------------
d=$(fresh_copy)
sed -i 's|^\(  ZAD_API_BASE: .*\)$|\1\n  IMAGE_TAG_DEFAULT: "v1.43.7"|' \
  "$d/.github/workflows/zad-deploy-directory.yml"
grep -qF 'IMAGE_TAG_DEFAULT: "v1.43.7"' "$d/.github/workflows/zad-deploy-directory.yml" || {
  echo "FAAL  opzet case 2: de mutatie sloeg niet aan" >&2; exit 1; }
expect "eigen versie in een workflow-env" 1 "$d"

# --- 3. Eigen versie als input-default, ongequote ----------------------------------------------
d=$(fresh_copy)
sed -i '0,/default: ""/s||default: v1.43.7|' "$d/.github/workflows/build-manager-migrate.yml"
grep -qF 'default: v1.43.7' "$d/.github/workflows/build-manager-migrate.yml" || {
  echo "FAAL  opzet case 3: de mutatie sloeg niet aan" >&2; exit 1; }
expect "eigen versie als workflow-input-default" 1 "$d"

# --- 4. Hernoemde compose-variabele: alle 14 images vallen in één klap buiten beeld ------------
d=$(fresh_copy)
# shellcheck disable=SC2016  # `${IMAGE_TAG:-` is de letterlijke compose-tekst, geen shell-expansie.
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
sed -i 's|^IMAGE_TAG=\(.*\)$|# was: IMAGE_TAG=\1\nIMAGE_TAG=v1.43.7|' "$d/deploy/local/.env.example"
expect "comment mag niet als bron gelden" 1 "$d"

# --- 9b. Een versie in een workflow-comment is geen eigen versie --------------------------------
# Fase C slaat comment-regels over; zonder dat zou elk voorbeeld in een comment de lint rood maken.
d=$(fresh_copy)
sed -i '1i # bv. v1.43.7' "$d/.github/workflows/build-manager-migrate.yml"
expect "versie in een workflow-comment blijft groen" 0 "$d"

# --- 9c. Literal gelijk aan de huidige versie ---------------------------------------------------
# Zo ontstaat elke default: iemand schrijft de versie die er nú staat. Een skew-check ziet dat niet,
# alleen het verbod op literals. De huidige versie komt uit de Dockerfile, niet uit de group-regel:
# die loopt op een Dependabot-PR juist achter.
d=$(fresh_copy)
cur=$("$d/.github/scripts/openfsc-tag.sh" "$d/deploy/zad/manager-migrate/Dockerfile")
sed -i "s|^\(  ZAD_API_BASE: .*\)$|\1\n  IMAGE_TAG_DEFAULT: $cur|" \
  "$d/.github/workflows/zad-deploy-directory.yml"
grep -qF "IMAGE_TAG_DEFAULT: $cur" "$d/.github/workflows/zad-deploy-directory.yml" || {
  echo "FAAL  opzet case 9c: de mutatie sloeg niet aan" >&2; exit 1; }
expect "literal gelijk aan de huidige versie in een workflow" 1 "$d"

# --- 9d. Literal in een `.yaml`-workflow: GitHub draait beide extensies --------------------------
d=$(fresh_copy)
printf 'name: x\non: push\nenv:\n  IMAGE_TAG: v1.43.7\n' > "$d/.github/workflows/extra.yaml"
expect "literal in een .yaml-workflow" 1 "$d"

# --- 9e. `uses: docker://…:vX.Y.Z` is geen SHA-pin ----------------------------------------------
d=$(fresh_copy)
sed -i '0,/^\(      - name: Checkout\)$/s||      - uses: docker://ghcr.io/minbzk/moza-fsc-testnet-manager-migrate:v1.43.7\n\1|' \
  "$d/.github/workflows/build-manager-migrate.yml"
grep -qF 'docker://ghcr.io/minbzk/moza-fsc-testnet-manager-migrate:v1.43.7' \
  "$d/.github/workflows/build-manager-migrate.yml" || {
  echo "FAAL  opzet case 9e: de mutatie sloeg niet aan" >&2; exit 1; }
expect "uses: docker:// met een versie" 1 "$d"

# --- 9f. Literal in de `with:` onder een lokale `uses:` -----------------------------------------
d=$(fresh_copy)
sed -i 's|^\(      image_tag: \)\${{ needs.meta.outputs.image_base }}$|\1v1.43.7|' \
  "$d/.github/workflows/zad-deploy-directory.yml"
grep -qE '^      image_tag: v1\.43\.7$' "$d/.github/workflows/zad-deploy-directory.yml" || {
  echo "FAAL  opzet case 9f: de mutatie sloeg niet aan" >&2; exit 1; }
expect "literal in de with: onder een lokale uses:" 1 "$d"

# --- 9g. Een trailing comment maakt een literal niet onschuldig ---------------------------------
d=$(fresh_copy)
sed -i "s|^\(  ZAD_API_BASE: .*\)$|\1\n  IMAGE_TAG_DEFAULT: $cur # zie uses:|" \
  "$d/.github/workflows/zad-deploy-directory.yml"
expect "literal met trailing comment" 1 "$d"

# --- 10. Group-regel achtergebleven: geen enkele deploy leest dit bestand, dus alleen de guard
#         merkt dat de afspraak met peer-teams iets anders belooft dan wij draaien ---------------
d=$(fresh_copy)
sed -i 's|openfsc_min_version: "v[0-9.]*"|openfsc_min_version: "v1.43.7"|' \
  "$d/group/group-config.yaml"
expect "achtergebleven openfsc_min_version in de group-regel" 1 "$d"

# --- 11. Bewaakt bestand verdwenen --------------------------------------------------------------
d=$(fresh_copy)
rm -f "$d/deploy/local/.env.example"
expect "bewaakt bestand verwijderd" 1 "$d"

echo
if [ "$fails" -ne 0 ]; then
  echo "REGRESSIETEST ROOD: $fails case(s) gefaald." >&2
  exit 1
fi
echo "Regressietest groen: alle $cases cases."
