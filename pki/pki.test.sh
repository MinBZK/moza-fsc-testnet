#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Regressietest voor de guards rond de test-PKI: de ankercontrole in verify.sh en issue.sh, de
# guard in init-ca.sh, de .gitignore die sleutels buiten git houdt, en geheimen.sh. Elke case
# muteert een kopie van één fixture-PKI (gebouwd met de echte scripts, in een tijdelijke git-repo)
# en toetst de exitcode. Vereist cfssl, cfssljson, openssl, sops en age.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fails=0
cases=0

git_commit() {
  git -C "$1" -c user.name=test -c user.email=test@example.org commit -qm "$2" --allow-empty
}

# Werkboom-kopie van de PKI-scripts en -configs plus twee peers. RSA 2048 in plaats van 4096: de
# sleutellengte doet voor deze guards niet ter zake en scheelt minuten.
kale_repo() {
  local dst="$1"
  mkdir -p "$dst/pki/peers"
  git -C "$dst" init -q
  cp "$REPO_ROOT/.gitignore" "$dst/"
  cp "$REPO_ROOT"/pki/*.sh "$REPO_ROOT"/pki/*.json "$dst/pki/"
  [ -d "$REPO_ROOT/pki/lib" ] && cp -r "$REPO_ROOT/pki/lib" "$dst/pki/"
  cp -r "$REPO_ROOT/pki/peers/directory" "$dst/pki/peers/"
  mkdir -p "$dst/pki/peers/example-provider"
  cp -r "$REPO_ROOT/pki/peers/example-provider/manager" "$dst/pki/peers/example-provider/"
  find "$dst/pki" -name '*.json' -exec sed -i 's/"size": 4096/"size": 2048/' {} +
}

FIXTURE="$TMP_ROOT/fixture"
echo "Fixture bouwen..."
kale_repo "$FIXTURE"
# Expliciet geketend: binnen `if !` geldt set -e niet.
if ! (
  cd "$FIXTURE" \
    && ./pki/init-ca.sh && ./pki/gen-crl.sh && git add -A && git_commit . "anker" \
    && ./pki/issue.sh && git add -A && git_commit . "certs"
) > "$TMP_ROOT/fixture.log" 2>&1; then
  echo "FAAL  fixture bouwen mislukt:" >&2
  tail -20 "$TMP_ROOT/fixture.log" >&2
  exit 1
fi

kopie() {  # [$1 = bron, standaard de fixture]
  local dst; dst="$TMP_ROOT/case-$(date +%s%N)-$RANDOM"
  cp -a "${1:-$FIXTURE}" "$dst"
  printf '%s' "$dst"
}

# $1=omschrijving $2=verwachte exitcode (of 'niet0') $3=map [$4=tekst in de uitvoer] -- commando
expect() {
  local desc="$1" want="$2" dir="$3" moet="" got=0 uit ok=1
  shift 3
  if [ "$1" != "--" ]; then moet="$1"; shift; fi
  shift
  cases=$((cases + 1))
  uit=$(cd "$dir" && "$@" 2>&1) || got=$?
  if [ "$want" = niet0 ]; then [ "$got" -ne 0 ] || ok=0; else [ "$got" -eq "$want" ] || ok=0; fi
  if [ "$ok" -eq 0 ]; then
    printf 'FAAL  %s: verwacht exit %s, kreeg %s\n%s\n' "$desc" "$want" "$got" "$(tail -15 <<<"$uit")" >&2
    fails=$((fails + 1))
  elif [ -n "$moet" ] && ! grep -qF -- "$moet" <<<"$uit"; then
    printf 'FAAL  %s: uitvoer noemt "%s" niet\n%s\n' "$desc" "$moet" "$(tail -15 <<<"$uit")" >&2
    fails=$((fails + 1))
  else
    printf 'ok    %s (exit %s)\n' "$desc" "$got"
  fi
}

# $1=omschrijving, rest = test-commando; voor beweringen die geen exitcode van een script zijn.
assert() {
  local desc="$1"; shift
  cases=$((cases + 1))
  if "$@"; then
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAAL  %s\n' "$desc" >&2
    fails=$((fails + 1))
  fi
}

# Vergelijkt met de fixture, niet met git: een niet-gecommit bestand is voor `git diff` altijd "gelijk".
ongewijzigd() { cmp -s "$FIXTURE/$2" "$1/$2"; }
vreemde_ca() {  # $1 = cert-pad, $2 = key-pad
  openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=vreemd -days 30 \
    -addext basicConstraints=critical,CA:TRUE -keyout "$2" -out "$1" 2>/dev/null
}

echo "Regressietest pki/"

# --- Basis -------------------------------------------------------------------------------------
d=$(kopie)
expect "fixture is groen" 0 "$d" -- ./pki/verify.sh

crl_langer_dan_jaar() {
  local eind
  eind=$(openssl crl -in "$FIXTURE/pki/ca/intermediate.crl" -noout -nextupdate) || return 1
  [ "$(date -u -d "${eind#nextUpdate=}" +%s)" -gt "$(date -u -d '+1 year' +%s)" ]
}
assert "gen-crl: CRL is langer dan een jaar geldig" crl_langer_dan_jaar

# --- .gitignore: sleutels eruit, openbare helft erin -------------------------------------------
d=$(kopie)
alle_sleutels_genegeerd() {
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    git -C "$d" check-ignore -q "$f" || { echo "niet genegeerd: $f" >&2; return 1; }
  done < <(cd "$d" && find pki -name '*key.pem')
  [ "$n" -gt 0 ]
}
openbare_helft_gecommit() {
  local f
  for f in pki/ca/root.pem pki/ca/intermediate.pem pki/ca/intermediate.crl \
           pki/out/directory/manager/cert.pem pki/internal/directory/ca/root.pem \
           pki/internal/example-provider/manager/cert.pem; do
    git -C "$d" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || { echo "niet in git: $f" >&2; return 1; }
  done
}
assert "elke *key.pem is genegeerd" alle_sleutels_genegeerd
assert "certificaten, ketens en CRL staan in git" openbare_helft_gecommit
(cd "$d" && ./pki/combine-pem.sh >/dev/null && ./pki/zad-bundle.sh directory >/dev/null)
assert "combined.pem is genegeerd" git -C "$d" check-ignore -q pki/out/directory/manager/combined.pem
assert "zad-upload is genegeerd" git -C "$d" check-ignore -q pki/zad-upload/directory/MANIFEST.md
touch "$d/pki/out/.DS_Store"
assert ".DS_Store is genegeerd" git -C "$d" check-ignore -q pki/out/.DS_Store
touch "$d/pki/out/directory/manager/key.pem.old" "$d/pki/ca/intermediate-key.pem.2026" \
  "$d/pki/out/directory/manager/cert.csr" "$d/pki/internal/directory/ca/root-key.txt"
assert "rondslingerende kopie van een sleutel is genegeerd" \
  git -C "$d" check-ignore -q pki/out/directory/manager/key.pem.old
assert "kopie naast de groepssleutel is genegeerd" git -C "$d" check-ignore -q pki/ca/intermediate-key.pem.2026
assert "csr is genegeerd" git -C "$d" check-ignore -q pki/out/directory/manager/cert.csr
assert "kopie in de internal-CA-map is genegeerd" git -C "$d" check-ignore -q pki/internal/directory/ca/root-key.txt

# --- init-ca.sh: geen tweede CA naast het anker ------------------------------------------------
d=$(kopie)
expect "init-ca weigert als het anker in git staat" niet0 "$d" "geheimen.sh ophalen" -- ./pki/init-ca.sh
expect "init-ca weigert ook met -f" niet0 "$d" -- ./pki/init-ca.sh -f
assert "anker onaangeroerd na init-ca" ongewijzigd "$d" pki/ca/root.pem

d="$TMP_ROOT/zonder-anker"
kale_repo "$d"
mkdir -p "$d/pki/ca" && cp "$FIXTURE/pki/ca/root.pem" "$d/pki/ca/"
expect "init-ca weigert een lokale CA zonder -f" niet0 "$d" -- ./pki/init-ca.sh
expect "init-ca vervangt een lokale CA met -f als er geen anker in git staat" 0 "$d" -- ./pki/init-ca.sh -f

# --- Ankercontrole: groep ----------------------------------------------------------------------
d=$(kopie)
vreemde_ca "$d/pki/ca/root.pem" "$d/pki/ca/root-key.pem"
rm -rf "$d/pki/out/directory/manager"
expect "verify: lokaal vervangen anker is rood met runbook-verwijzing" 1 "$d" "docs/sleutelbeheer.md" -- ./pki/verify.sh
expect "verify: herstelhint noemt wis -f voor een eigen lokale CA" 1 "$d" "wis -f" -- ./pki/verify.sh
expect "issue: weigert bij een vervangen anker" niet0 "$d" "FAIL anker" -- ./pki/issue.sh
assert "issue gaf niets uit bij een vervangen anker" test ! -e "$d/pki/out/directory/manager/cert.pem"

d=$(kopie)
openssl genrsa -out "$d/pki/ca/intermediate-key.pem" 2048 2>/dev/null
rm -rf "$d/pki/out/directory/manager"
expect "verify: intermediate-sleutel past niet bij intermediate.pem" 1 "$d" "FAIL anker" -- ./pki/verify.sh
expect "issue: weigert met een niet-passende intermediate-sleutel" niet0 "$d" "FAIL anker" -- ./pki/issue.sh

d=$(kopie)
openssl genrsa -out "$d/pki/ca/root-key.pem" 2048 2>/dev/null
expect "verify: root-sleutel past niet bij het anker" 1 "$d" "FAIL anker" -- ./pki/verify.sh

d=$(kopie)
vreemde_ca "$d/pki/ca/intermediate.pem" "$d/pki/ca/intermediate-key.pem"
expect "verify: intermediate ketent niet naar het anker" 1 "$d" "FAIL anker" -- ./pki/verify.sh

d=$(kopie)
git -C "$d" rm -q --cached pki/ca/root.pem && git_commit "$d" "anker uit git"
expect "verify: anker dat niet in git staat is rood" 1 "$d" "FAIL anker" -- ./pki/verify.sh

d=$(kopie)
rm "$d/pki/ca/intermediate-key.pem"
rm -rf "$d/pki/out/directory/manager"
expect "issue: noemt ophalen als de intermediate-sleutel ontbreekt" niet0 "$d" "geheimen.sh ophalen" -- ./pki/issue.sh

# --- Ankercontrole: internal-CA per peer -------------------------------------------------------
d=$(kopie)
openssl genrsa -out "$d/pki/internal/directory/ca/root-key.pem" 2048 2>/dev/null
expect "verify: internal-CA-sleutel past niet bij de gecommitte root" 1 "$d" "FAIL anker" -- ./pki/verify.sh

d=$(kopie)
vreemde_ca "$d/pki/internal/directory/ca/root.pem" "$d/pki/internal/directory/ca/root-key.pem"
expect "verify: gecommitte internal-root lokaal vervangen" 1 "$d" "FAIL anker" -- ./pki/verify.sh

d=$(kopie)
expect "issue -f geeft opnieuw uit" 0 "$d" -- ./pki/issue.sh -f
assert "issue -f laat een gecommitte internal-root staan" ongewijzigd "$d" pki/internal/directory/ca/root.pem
expect "verify na issue -f is groen" 0 "$d" -- ./pki/verify.sh

d=$(kopie)
rm "$d/pki/internal/directory/ca/root-key.pem"
rm -rf "$d/pki/internal/directory/manager"
expect "issue: noemt ophalen als de internal-CA-sleutel ontbreekt" niet0 "$d" "geheimen.sh ophalen" -- ./pki/issue.sh
assert "issue maakte geen nieuwe internal-root" ongewijzigd "$d" pki/internal/directory/ca/root.pem

# Vernieuwen met alleen de sleutels van de betrokken peer opgehaald: de andere peers blijven staan.
zonder_sleutels_van() {  # $1 = map, $2 = peer
  rm -f "$1"/pki/out/"$2"/*/key.pem "$1"/pki/internal/"$2"/*/key.pem "$1/pki/internal/$2/ca/root-key.pem"
}
d=$(kopie)
zonder_sleutels_van "$d" example-provider
rm -rf "$d/pki/out/directory"
expect "issue: group-keten van één peer vernieuwen" 0 "$d" -- ./pki/issue.sh
assert "issue laat een peer zonder opgehaalde sleutels onaangeroerd" \
  ongewijzigd "$d" pki/out/example-provider/manager/cert.pem
assert "vernieuwde peer heeft weer een group-cert" test -s "$d/pki/out/directory/manager/cert.pem"
expect "verify na vernieuwen van één peer" 0 "$d" -- ./pki/verify.sh

d=$(kopie)
zonder_sleutels_van "$d" example-provider
rm "$d/pki/ca/intermediate-key.pem"
rm -rf "$d/pki/internal/directory/manager"
expect "issue: één internal-cert vernieuwen zonder groepssleutel" 0 "$d" -- ./pki/issue.sh
assert "internal-cert opnieuw uitgegeven" test -s "$d/pki/internal/directory/manager/cert.pem"

d=$(kopie)
mkdir -p "$d/pki/peers/nieuw/manager"
sed 's/directory/nieuw/g' "$d/pki/peers/directory/manager/csr.json" > "$d/pki/peers/nieuw/manager/csr.json"
expect "issue: nieuwe peer krijgt een eigen internal-CA" 0 "$d" -- ./pki/issue.sh
expect "verify: nieuwe peer (nog niet in git) is groen" 0 "$d" -- ./pki/verify.sh

# De stappen uit docs/sleutelbeheer.md ("Een set vervangen", group-intermediate), letterlijk.
d=$(kopie)
vervang_intermediate() {
  cfssl genkey -initca pki/intermediate.json | cfssljson -bare pki/ca/intermediate \
    && cfssl sign -config pki/config.json -ca pki/ca/root.pem -ca-key pki/ca/root-key.pem \
         -profile intermediate pki/ca/intermediate.csr | cfssljson -bare pki/ca/intermediate \
    && rm pki/ca/intermediate.csr && pki/gen-crl.sh && rm -rf pki/out/*/ && pki/issue.sh && pki/verify.sh
}
expect "runbook: intermediate vervangen" 0 "$d" -- vervang_intermediate
assert "runbook: anker blijft gelijk" ongewijzigd "$d" pki/ca/root.pem
assert "runbook: intermediate is nieuw" test -n "$(cmp "$FIXTURE/pki/ca/intermediate.pem" "$d/pki/ca/intermediate.pem" 2>&1)"
assert "runbook: internal-certs onaangeroerd" ongewijzigd "$d" pki/internal/directory/manager/cert.pem

# --- Sleutel hoort bij certificaat ------------------------------------------------------------
d=$(kopie)
cp "$d/pki/out/directory/directory/key.pem" "$d/pki/out/directory/manager/key.pem"
expect "verify: group-sleutel past niet bij het cert" 1 "$d" -- ./pki/verify.sh

d=$(kopie)
cp "$d/pki/internal/directory/directory/key.pem" "$d/pki/internal/directory/manager/key.pem"
expect "verify: internal-sleutel past niet bij het cert" 1 "$d" -- ./pki/verify.sh

# --- Geen sleutels in git ---------------------------------------------------------------------
d=$(kopie)
git -C "$d" add -f pki/out/directory/manager/key.pem
expect "verify: gestagede sleutel is rood" 1 "$d" -- ./pki/verify.sh

d=$(kopie)
git -C "$d" add -f pki/out/directory/manager/key.pem && git_commit "$d" "per ongeluk"
expect "verify: gecommitte sleutel is rood" 1 "$d" -- ./pki/verify.sh

d=$(kopie)
cp "$d/pki/out/directory/manager/key.pem" "$d/pki/peers/directory/manager/lek.txt"
expect "verify: privésleutel buiten de bekende paden is rood" 1 "$d" -- ./pki/verify.sh

# Git bewaart de index en HEAD, niet de werkboom: de controle moet lezen wat git opslaat.
d=$(kopie)
cp "$d/pki/out/directory/manager/key.pem" "$d/pki/peers/directory/manager/lek.txt"
git -C "$d" add -f pki/peers/directory/manager/lek.txt
echo x > "$d/pki/peers/directory/manager/lek.txt"
expect "verify: gestagede sleutel, daarna op schijf overschreven, is rood" 1 "$d" -- ./pki/verify.sh

d=$(kopie)
cp "$d/pki/out/directory/manager/key.pem" "$d/pki/peers/directory/manager/lek.txt"
git -C "$d" add -f pki/peers/directory/manager/lek.txt && git_commit "$d" "per ongeluk"
rm "$d/pki/peers/directory/manager/lek.txt"
expect "verify: gecommitte sleutel die lokaal weg is, is rood" 1 "$d" -- ./pki/verify.sh

d=$(kopie)
printf 'binair' > "$d/pki/peers/directory/manager/sleutel.p12"
git -C "$d" add -f pki/peers/directory/manager/sleutel.p12
expect "verify: sleutelcontainer zonder PEM-kop is rood op naam" 1 "$d" -- ./pki/verify.sh

d=$(kopie)
mkdir -p "$d/pki/out/directory/é"
cp "$d/pki/out/directory/manager/key.pem" "$d/pki/out/directory/manager/cert.pem" "$d/pki/out/directory/é/"
git -C "$d" add -f "pki/out/directory/é/key.pem"
expect "verify: gestagede sleutel met niet-ASCII-pad is rood" 1 "$d" -- ./pki/verify.sh

# --- geheimen.sh -------------------------------------------------------------------------------
# Drie rollen: 'dagelijks' ontsleutelt alleen de dagelijkse sleutels, 'root' is root-houder én
# dagelijkse ontvanger, 'nieuw' komt er later bij. De geheime repo staat in secrets/ (gitignored).
AGE="$TMP_ROOT/age"
mkdir -p "$AGE"
for rol in dagelijks root nieuw; do age-keygen -o "$AGE/$rol.txt" 2>/dev/null; done
pub() { age-keygen -y "$AGE/$1.txt"; }

# Dezelfde vorm als het voorbeeld in docs/sleutelbeheer.md: root-regel eerst, key_groups met een lijst.
sops_config() {  # $1 = repo, $2 = dagelijkse ontvangers, $3 = root-ontvangers (komma-gescheiden)
  {
    printf 'creation_rules:\n  - path_regex: (^|/)groep/root/\n    key_groups:\n      - age:\n'
    tr ',' '\n' <<<"$3" | sed 's/^/          - /'
    printf '  - path_regex: .*\n    key_groups:\n      - age:\n'
    tr ',' '\n' <<<"$2" | sed 's/^/          - /'
  } > "$1/pki/.sops.yaml"
}

geheimen() {  # $1 = rol, rest = argumenten; draait in de huidige case-map
  local rol="$1"; shift
  FSC_GEHEIMEN_DIR="$PWD/secrets" SOPS_AGE_KEY_FILE="$AGE/$rol.txt" ./pki/geheimen.sh "$@"
}
ontsleutelbaar() {  # $1 = rol, $2 = bestand
  SOPS_AGE_KEY_FILE="$AGE/$1.txt" sops decrypt --input-type binary --output-type binary "$2" >/dev/null 2>&1
}
niet_ontsleutelbaar() { ! ontsleutelbaar "$@"; }
inhoud() { (cd "$1" && find . -type f -exec sha256sum {} + | sort); }

d=$(kopie)
mkdir -p "$d/secrets"
expect "opslaan zonder pki/.sops.yaml" niet0 "$d" ".sops.yaml" -- geheimen root opslaan
sops_config "$d" "$(pub dagelijks),$(pub root)" "$(pub root)"
expect "opslaan bewaart de dagelijkse sleutels" 0 "$d" -- geheimen root opslaan
spiegelt_pki() {
  local f
  for f in groep/intermediate-key.pem \
           directory/group/directory-key.pem directory/group/manager-key.pem \
           directory/internal/ca-key.pem directory/internal/directory-key.pem directory/internal/manager-key.pem \
           example-provider/group/manager-key.pem \
           example-provider/internal/ca-key.pem example-provider/internal/manager-key.pem; do
    [ -f "$d/secrets/$f" ] || { echo "ontbreekt: $f" >&2; return 1; }
  done
  [ "$(find "$d/secrets" -type f | wc -l)" -eq 9 ]
}
assert "geheime repo: één bestand per sleutel, per peer" spiegelt_pki
assert "root-sleutel alleen opgeslagen als je 'root' noemt" test ! -e "$d/secrets/groep/root/root-key.pem"
geen_klare_tekst() { ! grep -rq 'PRIVATE KEY' "$d/secrets"; }
assert "geen leesbare sleutel in de geheime repo" geen_klare_tekst
voor=$(inhoud "$d/secrets")
expect "opslaan zonder wijzigingen" 0 "$d" "ongewijzigd" -- geheimen root opslaan
assert "opslaan zonder wijzigingen versleutelt niets opnieuw" test "$voor" = "$(inhoud "$d/secrets")"
expect "opslaan root" 0 "$d" -- geheimen root opslaan root
assert "root-houder kan de root-sleutel ontsleutelen" ontsleutelbaar root "$d/secrets/groep/root/root-key.pem"
assert "dagelijkse ontvanger kan de root-sleutel niet ontsleutelen" \
  niet_ontsleutelbaar dagelijks "$d/secrets/groep/root/root-key.pem"
assert "dagelijkse ontvanger kan de groepssleutel ontsleutelen" \
  ontsleutelbaar dagelijks "$d/secrets/groep/intermediate-key.pem"
(cd "$d" && ./pki/combine-pem.sh >/dev/null && ./pki/zad-bundle.sh directory >/dev/null)
GEVULD="$d"

d=$(kopie "$GEVULD")
expect "wis weigert een sleutel die je niet kunt nakijken" niet0 "$d" "ca/root-key.pem" -- geheimen dagelijks wis
assert "na een geweigerde wis staan de sleutels er nog" test -e "$d/pki/ca/intermediate-key.pem"
expect "wis door een root-houder" 0 "$d" -- geheimen root wis
geen_lokale_sleutels() {
  [ -z "$(find "$d/pki" -name '*key.pem' -o -name combined.pem)" ] && [ ! -e "$d/pki/zad-upload" ]
}
assert "wis laat geen sleutel of afgeleid bestand achter" geen_lokale_sleutels
assert "wis laat de certificaten staan" test -e "$d/pki/out/directory/manager/cert.pem"
expect "ophalen draait verify.sh" 0 "$d" "ALLE ASSERTS GROEN" -- geheimen dagelijks ophalen
sleutels_terug() {
  local f
  while IFS= read -r f; do
    [ "$f" = pki/ca/root-key.pem ] && continue
    cmp -s "$FIXTURE/$f" "$d/$f" || { echo "anders: $f" >&2; return 1; }
  done < <(cd "$FIXTURE" && find pki -name '*key.pem')
}
assert "ophalen zet elke sleutel ongewijzigd terug" sleutels_terug
assert "ophalen haalt de root-sleutel niet zonder 'root'" test ! -e "$d/pki/ca/root-key.pem"
rechten_ok() {
  [ "$(stat -c %a "$d/pki/out/directory/manager/key.pem")" = 600 ] \
    && [ "$(stat -c %a "$d/pki/out/directory/manager")" = 700 ] \
    && [ "$(stat -c %a "$d/pki/ca")" = 700 ]
}
assert "opgehaalde sleutels 600, hun mappen 700" rechten_ok
expect "ophalen root zonder root-toegang" niet0 "$d" "ontsleutelen" -- geheimen dagelijks ophalen root
expect "ophalen root als root-houder" 0 "$d" -- geheimen root ophalen root
assert "root-sleutel ongewijzigd terug" cmp -s "$FIXTURE/pki/ca/root-key.pem" "$d/pki/ca/root-key.pem"

d=$(kopie "$GEVULD")
(cd "$d" && geheimen root wis >/dev/null)
expect "ophalen groep" 0 "$d" -- geheimen dagelijks ophalen groep
assert "ophalen groep haalt alleen de groepssleutel" \
  test -e "$d/pki/ca/intermediate-key.pem" -a ! -e "$d/pki/out/directory/manager/key.pem"

d=$(kopie "$GEVULD")
openssl genrsa -out "$d/pki/out/directory/manager/key.pem" 2048 2>/dev/null
cp "$d/pki/out/directory/manager/key.pem" "$TMP_ROOT/afwijkend.pem"
expect "ophalen overschrijft geen afwijkende lokale sleutel" niet0 "$d" "-f" -- geheimen dagelijks ophalen
assert "afwijkende sleutel blijft staan" cmp -s "$TMP_ROOT/afwijkend.pem" "$d/pki/out/directory/manager/key.pem"
expect "ophalen -f overschrijft" 0 "$d" -- geheimen dagelijks ophalen -f
assert "na -f staat de sleutel uit de geheime repo er" \
  cmp -s "$FIXTURE/pki/out/directory/manager/key.pem" "$d/pki/out/directory/manager/key.pem"

# Runbook: vernieuwen → opslaan → wis. Een vergeten opslaan mag de nieuwe sleutel niet kosten.
d=$(kopie "$GEVULD")
rm -rf "$d/pki/out/directory/manager"
(cd "$d" && ./pki/issue.sh >/dev/null 2>&1)
expect "wis weigert een niet-opgeslagen sleutel" niet0 "$d" "out/directory/manager/key.pem" -- geheimen root wis
assert "niet-opgeslagen sleutel blijft staan" test -e "$d/pki/out/directory/manager/key.pem"
expect "opslaan na vernieuwen" 0 "$d" "directory/group/manager-key.pem" -- geheimen dagelijks opslaan directory
expect "wis na opslaan" 0 "$d" -- geheimen root wis

d=$(kopie "$GEVULD")
cp "$d/pki/out/directory/directory/key.pem" "$d/pki/out/directory/manager/key.pem"
voor=$(inhoud "$d/secrets")
expect "opslaan weigert als verify.sh rood is" niet0 "$d" "verify.sh" -- geheimen dagelijks opslaan
assert "geheime repo onaangeroerd na een geweigerde opslaan" test "$voor" = "$(inhoud "$d/secrets")"

# Schrijfrechten op de geheime repo zijn ruimer dan ontsleutelrechten: een vervangen sleutel moet
# bij ophalen opvallen, ook als hij netjes versleuteld is.
d=$(kopie "$GEVULD")
openssl genrsa -out "$TMP_ROOT/vreemd-key.pem" 2048 2>/dev/null
(cd "$d/secrets" && sops --config ../pki/.sops.yaml encrypt --input-type binary --output-type binary \
  --filename-override directory/group/manager-key.pem "$TMP_ROOT/vreemd-key.pem" > "$TMP_ROOT/vreemd.enc") \
  && mv "$TMP_ROOT/vreemd.enc" "$d/secrets/directory/group/manager-key.pem"
(cd "$d" && geheimen root wis -f >/dev/null)
expect "ophalen van een vervangen sleutel is rood" niet0 "$d" "past niet" -- geheimen dagelijks ophalen
expect "ophalen wijst bij een niet-passende sleutel op git pull" niet0 "$d" "git pull" -- geheimen dagelijks ophalen

d=$(kopie "$GEVULD")
root_voor=$(sha256sum < "$d/secrets/groep/root/root-key.pem")
sops_config "$d" "$(pub nieuw),$(pub root)" "$(pub root)"
expect "ontvangers bijwerken" 0 "$d" -- geheimen root ontvangers
assert "nieuwe ontvanger kan ontsleutelen" ontsleutelbaar nieuw "$d/secrets/directory/internal/ca-key.pem"
assert "verwijderde ontvanger kan niet meer ontsleutelen" \
  niet_ontsleutelbaar dagelijks "$d/secrets/groep/intermediate-key.pem"
assert "ontvangers zonder 'root' laat de root-sleutel ongemoeid" \
  test "$root_voor" = "$(sha256sum < "$d/secrets/groep/root/root-key.pem")"

# sops matcht path_regex op het absolute pad: een regel met ^groep/root/ of een .*-regel bovenaan
# zou de root-sleutel stil aan elke dagelijkse ontvanger geven.
root_regel_fout() {  # $1 = repo, $2 = 'anker', 'volgorde' of 'zonder' (regel zonder path_regex)
  case "$2" in
    anker)
      printf 'creation_rules:\n  - path_regex: ^groep/root/\n    age: %s\n  - path_regex: .*\n    age: %s,%s\n' \
        "$(pub root)" "$(pub dagelijks)" "$(pub root)" > "$1/pki/.sops.yaml" ;;
    volgorde)
      printf 'creation_rules:\n  - path_regex: .*\n    age: %s,%s\n  - path_regex: (^|/)groep/root/\n    age: %s\n' \
        "$(pub dagelijks)" "$(pub root)" "$(pub root)" > "$1/pki/.sops.yaml" ;;
    zonder)
      printf 'creation_rules:\n  - age: %s,%s\n  - path_regex: (^|/)groep/root/\n    age: %s\n' \
        "$(pub dagelijks)" "$(pub root)" "$(pub root)" > "$1/pki/.sops.yaml" ;;
  esac
}
d=$(kopie "$GEVULD")
rm "$d/secrets/groep/root/root-key.pem"
root_regel_fout "$d" anker
expect "opslaan root weigert een root-regel die niet matcht" niet0 "$d" "root" -- geheimen root opslaan root
assert "geen root-sleutel opgeslagen met een niet-matchende regel" test ! -e "$d/secrets/groep/root/root-key.pem"
root_regel_fout "$d" volgorde
expect "opslaan root weigert een .*-regel vóór de root-regel" niet0 "$d" "root" -- geheimen root opslaan root
# Een regel zonder path_regex matcht in sops elk pad.
root_regel_fout "$d" zonder
expect "opslaan root weigert een regel zonder path_regex vóór de root-regel" niet0 "$d" "root" -- \
  geheimen root opslaan root
assert "geen root-sleutel opgeslagen onder een regel zonder path_regex" \
  test ! -e "$d/secrets/groep/root/root-key.pem"

d=$(kopie "$GEVULD")
root_regel_fout "$d" anker
expect "ontvangers root weigert een root-regel die niet matcht" niet0 "$d" "root" -- geheimen root ontvangers root
assert "root-sleutel blijft afgeschermd" niet_ontsleutelbaar dagelijks "$d/secrets/groep/root/root-key.pem"

# Is elke ontvanger ook root-houder, dan hebben beide regels dezelfde ontvangers. Dat is geldig.
d=$(kopie "$GEVULD")
sops_config "$d" "$(pub root)" "$(pub root)"
expect "ontvangers root met dezelfde ontvangers in beide regels" 0 "$d" -- geheimen root ontvangers root
rm "$d/secrets/groep/root/root-key.pem"
expect "opslaan root met dezelfde ontvangers in beide regels" 0 "$d" -- geheimen root opslaan root
assert "root-sleutel opgeslagen met dezelfde ontvangers in beide regels" \
  ontsleutelbaar root "$d/secrets/groep/root/root-key.pem"

# De geheime repo is gedeeld met andere repo's: intrekken moet ook hun bestanden raken.
d=$(kopie "$GEVULD")
mkdir -p "$d/secrets/andere-peer/group"
(cd "$d/secrets" && sops --config ../pki/.sops.yaml encrypt --input-type binary --output-type binary \
  --filename-override andere-peer/group/manager-key.pem "$FIXTURE/pki/out/directory/manager/key.pem" \
  > "$TMP_ROOT/andere.enc") && mv "$TMP_ROOT/andere.enc" "$d/secrets/andere-peer/group/manager-key.pem"
sops_config "$d" "$(pub nieuw),$(pub root)" "$(pub root)"
expect "ontvangers werkt ook peers bij die hier niet lokaal staan" 0 "$d" -- geheimen root ontvangers
assert "nieuwe ontvanger kan het bestand van die peer ontsleutelen" \
  ontsleutelbaar nieuw "$d/secrets/andere-peer/group/manager-key.pem"
expect "ontvangers accepteert een peer die alleen in de geheime repo staat" 0 "$d" -- geheimen root ontvangers andere-peer

d=$(kopie "$GEVULD")
expect "onbekende peer" niet0 "$d" "onbekend" -- geheimen dagelijks ophalen bestaat-niet
expect "onbekende actie" 2 "$d" -- geheimen dagelijks verwijder
expect "geheime repo niet gevonden" niet0 "$d" "FSC_GEHEIMEN_DIR" -- \
  env -u FSC_GEHEIMEN_DIR SOPS_AGE_KEY_FILE="$AGE/root.txt" ./pki/geheimen.sh ophalen

echo "${cases} cases, ${fails} gefaald"
[ "$fails" -eq 0 ]
