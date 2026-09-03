#!/usr/bin/env bash
# Regressietest voor bump-openfsc.sh. Waarom dat script zijn referentieversie uit de group-regel
# leest en niet uit een wrapper-Dockerfile: docs/openfsc-versiebeheer.md.
#
# Werking als in check-openfsc-version.test.sh: kopieer de WERKBOOM naar een tijdelijke map en
# muteer daar. `bump-openfsc.sh` en `check-openfsc-version.sh` doen zelf `cd "$(dirname "$0")/../.."`
# en draaien dus tegen de kopie.
#
# Elke kopie wordt eerst genormaliseerd naar één synthetische basisversie. Zonder dat erft een case
# de toestand van de werkboom, en die is op een `openfsc-images`-PR juist half gebumpt — dan zou
# deze test rood worden op precies de PR waarvoor het script bestaat.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
# `set -e` in een helper of een pipeline beëindigt de suite zonder uitslag; zeg dan tenminste waar.
trap 'echo "Regressietest afgebroken (regel $LINENO)" >&2' ERR

BASE=v0.0.1   # synthetische begintoestand
NEW=v9.9.9    # synthetisch doel; geen van beide bestaat upstream
fails=0
cases=0

fresh_copy() {
  local dst; dst="$TMP_ROOT/case-$(date +%s%N)-$RANDOM"
  mkdir -p "$dst"
  # --others --exclude-standard: neem óók ongestagede bestanden mee, net als de zusterttest.
  (cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard \
     | tar --null -T - -cf -) | tar -xf - -C "$dst"
  printf '%s' "$dst"
}

# Zet elke bewaakte plek in de kopie op $BASE. De inventaris komt uit de guard zelf — die print per
# plek `bestand versie` — zodat deze test de lijst niet dupliceert en niet stil achterloopt wanneer
# er een plek bij komt.
normalize() {  # $1=werkboomkopie
  local dir="$1" n=0 file version
  while read -r file version; do
    [ -n "$version" ] || continue
    sed -i "s/${version//./\\.}/${BASE}/g" "$dir/$file"
    n=$((n + 1))
  done < <("$dir/.github/scripts/check-openfsc-version.sh" 2>/dev/null \
             | awk 'NF==2 && $2 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/            {print $1, $2}
                    NF==3 && $1=="sweep:" && $3 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {print $2, $3}' \
             | sort -u)
  [ "$n" -ge 8 ] || {
    echo "FAAL  opzet: de guard leverde $n bewaakte plek(ken), minimaal 8 verwacht" >&2; exit 1; }
  "$dir/.github/scripts/check-openfsc-version.sh" >/dev/null 2>&1 || {
    echo "FAAL  opzet: de genormaliseerde kopie is niet groen" >&2; exit 1; }
}

# De versie die de group-regel draagt; dat is de referentie van bump-openfsc.sh.
current_version() {  # $1=werkboomkopie
  grep -oE 'openfsc_min_version:[[:space:]]*"?v[0-9]+\.[0-9]+\.[0-9]+' "$1/group/group-config.yaml" \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+'
}

# Toont de uitvoer van een gevallen case: zonder dat is een CI-falen niet te duiden, want de
# meest waarschijnlijke fouten van het script zelf zijn juist woordeloos.
dump() { sed 's/^/      | /' "$1" >&2; }

# $1=omschrijving $2=verwachte exitcode $3=kopie $4=tekst die in de uitvoer moet staan ('' = geen
# eis) $5...=argumenten voor bump-openfsc.sh
expect_bump() {
  local desc="$1" want="$2" dir="$3" needle="$4" got=0 log; shift 4
  cases=$((cases + 1))
  log="$TMP_ROOT/bump-$cases.log"
  "$dir/.github/scripts/bump-openfsc.sh" "$@" >"$log" 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    printf 'FAAL  %s: verwacht exit %s, kreeg %s\n' "$desc" "$want" "$got" >&2
    dump "$log"; fails=$((fails + 1)); return
  fi
  if [ -n "$needle" ] && ! grep -qF "$needle" "$log"; then
    printf 'FAAL  %s: de uitvoer noemt "%s" niet\n' "$desc" "$needle" >&2
    dump "$log"; fails=$((fails + 1)); return
  fi
  printf 'ok    %s (exit %s)\n' "$desc" "$got"
}

# De guard oordeelt over consistentie: lopen de bewaakte plekken na de bump nog uiteen?
expect_guard_green() {  # $1=omschrijving $2=kopie
  local desc="$1" dir="$2" got=0 log
  cases=$((cases + 1))
  log="$TMP_ROOT/guard-$cases.log"
  "$dir/.github/scripts/check-openfsc-version.sh" >"$log" 2>&1 || got=$?
  if [ "$got" -eq 0 ]; then
    printf 'ok    %s (guard groen)\n' "$desc"
  else
    printf 'FAAL  %s: guard gaf exit %s na de bump\n' "$desc" "$got" >&2
    dump "$log"; fails=$((fails + 1))
  fi
}

# Consistentie alléén is te weinig: een script dat overal dezelfde verkéérde versie schrijft, of dat
# niets doet, laat de guard ook groen. Daarom apart toetsen wélke versie er staat.
expect_version() {  # $1=omschrijving $2=kopie $3=verwachte versie
  local desc="$1" dir="$2" want="$3" got left
  cases=$((cases + 1))
  got=$(current_version "$dir")
  left=$(grep -rlF "$BASE" "$dir/deploy" "$dir/.github/workflows" "$dir/group" 2>/dev/null || true)
  if [ "$got" = "$want" ] && [ -z "$left" ]; then
    printf 'ok    %s (overal %s)\n' "$desc" "$want"
  else
    printf 'FAAL  %s: group-regel op %s (verwacht %s); nog op %s: %s\n' \
      "$desc" "$got" "$want" "$BASE" "$(echo "$left" | tr '\n' ' ')" >&2
    fails=$((fails + 1))
  fi
}

# $1=omschrijving $2=map A $3=map B
expect_identical() {
  local desc="$1" rc=0
  cases=$((cases + 1))
  diff -r "$2" "$3" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'ok    %s\n' "$desc" ;;
    1) printf 'FAAL  %s: de inhoud verschilt\n' "$desc" >&2; fails=$((fails + 1)) ;;
    *) printf 'FAAL  %s: diff faalde (exit %s)\n' "$desc" "$rc" >&2; fails=$((fails + 1)) ;;
  esac
}

echo "Regressietest bump-openfsc.sh"

# --- 1. De situatie waarvoor het script bestaat: Dependabot heeft de wrappers al verzet ---------
# De opzet is zelf een assertie: slaat de mutatie niet aan, dan is er geen halve bump meer om af te
# maken en zou deze case stilzwijgend hetzelfde toetsen als case 2.
d=$(fresh_copy); normalize "$d"
mapfile -t wrappers < <(find "$d/deploy/zad" -name Dockerfile | sort)
[ "${#wrappers[@]}" -ge 3 ] || {
  echo "FAAL  opzet case 1: ${#wrappers[@]} wrapper-Dockerfile(s), minimaal 3 verwacht" >&2; exit 1; }
for wrapper in "${wrappers[@]}"; do
  sed -i "s/${BASE//./\\.}/${NEW}/g" "$wrapper"
  grep -qF "$NEW" "$wrapper" || {
    echo "FAAL  opzet case 1: $wrapper staat niet op $NEW" >&2; exit 1; }
done
grep -qF "$BASE" "$d/group/group-config.yaml" || {
  echo "FAAL  opzet case 1: de group-regel loopt niet meer achter" >&2; exit 1; }

expect_bump "halve bump (Dependabot) wordt afgemaakt" 0 "$d" "" "$NEW"
expect_guard_green "halve bump (Dependabot)" "$d"
expect_version "halve bump (Dependabot)" "$d" "$NEW"

# --- 2. Het gewone geval: een consistente werkboom in één keer verzetten ------------------------
# De digest-herinnering hoort erbij: de guard controleert digests niet, dus die tekst is de enige
# maatregel tegen een nieuwe tag boven een oude digest.
d=$(fresh_copy); normalize "$d"
expect_bump "consistente werkboom verzetten" 0 "$d" "digests" "$NEW"
expect_guard_green "consistente werkboom verzetten" "$d"
expect_version "consistente werkboom verzetten" "$d" "$NEW"

# --- 3. docs/ beweegt niet mee (bump-openfsc.sh: bewust géén repo-brede sed) --------------------
# Historische versievermeldingen in docs/ zijn geen configuratie. De guard kijkt niet naar docs/,
# dus als het script ze toch herschrijft, merkt niets het.
#
# De echte docs dragen na het normaliseren de basisversie niet, dus een repo-brede sed zou er
# toevallig langslopen en de case niets bewijzen. Vandaar een gemerkt bestand in de kopie: dat
# draagt de versie die het script omzet, en verschijnt in beide kopieën zodat alleen een bump het
# verschil kan maken. Vergelijken gaat tegen een kopie, niet tegen de werkboom: die draagt ook
# bestanden die git negeert.
d=$(fresh_copy); normalize "$d"
ref=$(fresh_copy); normalize "$ref"
for dir in "$d" "$ref"; do printf 'OpenFSC %s\n' "$BASE" > "$dir/docs/.bump-marker"; done
expect_bump "bump raakt docs/ niet" 0 "$d" "" "$NEW"
expect_identical "docs/ blijft ongemoeid bij een bump" "$ref/docs" "$d/docs"

# --- 4. Een bewaakte plek op een dérde versie is een fout, geen stilte -------------------------
# Dat is de halve bump die dit script juist hoort weg te nemen: doorlopen zou een geslaagde bump
# melden terwijl de wrappers achterblijven, en de guard wijst daarna naar iets wat net gedaan leek.
d=$(fresh_copy); normalize "$d"
while IFS= read -r wrapper; do
  sed -i "s/${BASE//./\\.}/v0.0.2/g" "$wrapper"
done < <(find "$d/deploy/zad" -name Dockerfile)
expect_bump "bewaakte plek op een derde versie" 1 "$d" "derde versie" "$NEW"

# --- 5. Al op de gevraagde versie: geen wijziging, geen fout -----------------------------------
d=$(fresh_copy); normalize "$d"
ref=$(fresh_copy); normalize "$ref"
expect_bump "al op de gevraagde versie" 0 "$d" "verzet niets meer" "$BASE"
expect_identical "al op de gevraagde versie laat de kopie ongemoeid" "$ref" "$d"

# --- 6. Argumenten die geen versie zijn --------------------------------------------------------
# `&` en `/` zijn sed-metatekens: zonder strikte validatie schrijft het script daar stil onzin mee
# weg (`&` herhaalt de hele match) in plaats van te stoppen.
d=$(fresh_copy)
expect_bump "argument zonder v-prefix" 2 "$d" "Gebruik:" "9.9.9"
expect_bump "argument met sed-metateken" 2 "$d" "Gebruik:" "v9.9.9&x"
expect_bump "argument ontbreekt" 2 "$d" "Gebruik:" ""

echo
if [ "$fails" -ne 0 ]; then
  echo "Regressietest ROOD: $fails van de $cases cases faalden." >&2
  exit 1
fi
echo "Regressietest groen: alle $cases cases."
