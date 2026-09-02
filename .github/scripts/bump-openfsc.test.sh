#!/usr/bin/env bash
# Regressietest voor bump-openfsc.sh. Het script bestaat om één situatie op te lossen: een
# `openfsc-images`-PR waarin Dependabot alleen de wrapper-Dockerfiles heeft verzet. Leest het zijn
# referentieversie uit zo'n Dockerfile, dan ziet het oud en nieuw als gelijk en doet het niets —
# stil, met exit 0, dus je merkt het pas aan de rode guard. Case 1 hieronder houdt dat vast.
#
# Werking als in check-openfsc-version.test.sh: kopieer de WERKBOOM naar een tijdelijke map en
# muteer daar. Beide scripts doen zelf `cd "$(dirname "$0")/../.."` en draaien dus tegen de kopie.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

NEW=v9.9.9   # bestaat niet upstream; deze test raakt geen registry
fails=0
cases=0

fresh_copy() {
  local dst; dst="$TMP_ROOT/case-$(date +%s%N)-$RANDOM"
  mkdir -p "$dst"
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard \
     | tar --null -T - -cf -) | tar -xf - -C "$dst"
  printf '%s' "$dst"
}

# De versie die de werkboom nú draagt; de cases zetten zich daartegen af.
current_version() {  # $1=werkboomkopie
  grep -oE 'openfsc_min_version:[[:space:]]*"?v[0-9]+\.[0-9]+\.[0-9]+' "$1/group/group-config.yaml" \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+'
}

# $1=omschrijving $2=verwachte exitcode $3=werkboomkopie $4...=argumenten voor bump-openfsc.sh
expect_bump() {
  local desc="$1" want="$2" dir="$3" got=0; shift 3
  cases=$((cases + 1))
  "$dir/.github/scripts/bump-openfsc.sh" "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    printf 'ok    %s (exit %s)\n' "$desc" "$got"
  else
    printf 'FAAL  %s: verwacht exit %s, kreeg %s\n' "$desc" "$want" "$got" >&2
    fails=$((fails + 1))
  fi
}

# $1=omschrijving $2=werkboomkopie — de guard is het echte oordeel over een geslaagde bump.
expect_guard_green() {
  local desc="$1" dir="$2" got=0
  cases=$((cases + 1))
  "$dir/.github/scripts/check-openfsc-version.sh" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq 0 ]; then
    printf 'ok    %s (guard groen)\n' "$desc"
  else
    printf 'FAAL  %s: guard gaf exit %s na de bump\n' "$desc" "$got" >&2
    fails=$((fails + 1))
  fi
}

echo "Regressietest bump-openfsc.sh"

# --- 1. De situatie waarvoor het script bestaat: Dependabot heeft de wrappers al verzet ---------
d=$(fresh_copy); old=$(current_version "$d")
while IFS= read -r dockerfile; do
  sed -i "s/${old//./\\.}/${NEW}/g" "$dockerfile"
done < <(find "$d/deploy/zad" -name Dockerfile)
expect_bump "halve bump (Dependabot) wordt afgemaakt" 0 "$d" "$NEW"
expect_guard_green "halve bump (Dependabot)" "$d"

# --- 2. Het gewone geval: een consistente werkboom in één keer verzetten ------------------------
d=$(fresh_copy)
expect_bump "consistente werkboom verzetten" 0 "$d" "$NEW"
expect_guard_green "consistente werkboom verzetten" "$d"

# --- 3. Al op de gevraagde versie: geen wijziging, geen fout -----------------------------------
d=$(fresh_copy); old=$(current_version "$d")
expect_bump "al op de gevraagde versie" 0 "$d" "$old"
cases=$((cases + 1))
if git -C "$REPO_ROOT" diff --no-index --quiet "$REPO_ROOT/group/group-config.yaml" \
     "$d/group/group-config.yaml" 2>/dev/null; then
  printf 'ok    al op de gevraagde versie laat de werkboom met rust\n'
else
  printf 'FAAL  al op de gevraagde versie: de werkboom is toch gewijzigd\n' >&2
  fails=$((fails + 1))
fi

# --- 4. Een versie zonder `v`-prefix is geen versie --------------------------------------------
d=$(fresh_copy)
expect_bump "argument zonder v-prefix" 2 "$d" "9.9.9"

echo
if [ "$fails" -ne 0 ]; then
  echo "Regressietest ROOD: $fails van de $cases cases faalden." >&2
  exit 1
fi
echo "Regressietest groen: alle $cases cases."
