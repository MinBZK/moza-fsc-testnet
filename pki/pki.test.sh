#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Regressietest voor de guards rond de test-PKI: de ankercontrole in verify.sh en issue.sh, de
# guard in init-ca.sh en de .gitignore die sleutels buiten git houdt. Elke case muteert een kopie
# van één fixture-PKI (gebouwd met de echte scripts, in een tijdelijke git-repo) en toetst de
# exitcode. Vereist cfssl, cfssljson en openssl.
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

kopie() {
  local dst; dst="$TMP_ROOT/case-$(date +%s%N)-$RANDOM"
  cp -a "$FIXTURE" "$dst"
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

d=$(kopie)
mkdir -p "$d/pki/peers/nieuw/manager"
sed 's/directory/nieuw/g' "$d/pki/peers/directory/manager/csr.json" > "$d/pki/peers/nieuw/manager/csr.json"
expect "issue: nieuwe peer krijgt een eigen internal-CA" 0 "$d" -- ./pki/issue.sh
expect "verify: nieuwe peer (nog niet in git) is groen" 0 "$d" -- ./pki/verify.sh

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

echo "${cases} cases, ${fails} gefaald"
[ "$fails" -eq 0 ]
