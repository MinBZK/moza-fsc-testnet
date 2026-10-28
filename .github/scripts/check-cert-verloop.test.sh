#!/usr/bin/env bash
# Regressietest voor check-cert-verloop.sh. Een verloopcontrole die stil groen blijft, laat een
# certificaat ongemerkt verlopen tot de koppeling uitvalt. Elke case bouwt een tijdelijke repo met
# certificaten van een bekende looptijd en toetst de exitcode (0 = ok, 1 = verloopt, 2 = fout).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fails=0
cases=0

# Mini-CA via `openssl ca`: alleen daarmee zijn start- en einddatum in het verleden te zetten, en
# een CRL met een nextUpdate van uren in plaats van dagen.
CA="$TMP_ROOT/ca"
mkdir -p "$CA/nieuw"
: > "$CA/index.txt"
echo 1000 > "$CA/serial"
echo 1000 > "$CA/crlnumber"
cat > "$CA/ca.cnf" <<EOF
[ ca ]
default_ca = testca
[ testca ]
database = $CA/index.txt
new_certs_dir = $CA/nieuw
serial = $CA/serial
crlnumber = $CA/crlnumber
certificate = $CA/ca.pem
private_key = $CA/ca-key.pem
default_md = sha256
policy = beleid
unique_subject = no
[ beleid ]
commonName = supplied
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CA/ca-key.pem" -out "$CA/ca.pem" \
  -days 3650 -subj /CN=test-ca 2>/dev/null

# $1 = doelbestand, $2 = startdatum, $3 = einddatum (YYYYMMDDHHMMSSZ)
maak_cert() {
  local csr="$TMP_ROOT/req.csr"
  openssl req -newkey rsa:2048 -nodes -keyout /dev/null -out "$csr" -subj "/CN=$(basename "$1")" 2>/dev/null
  mkdir -p "$(dirname "$1")"
  openssl ca -batch -config "$CA/ca.cnf" -in "$csr" -out "$1" -notext \
    -startdate "$2" -enddate "$3" 2>/dev/null
}

# $1 = doelbestand, $2 = geldigheid in uren
maak_crl() {
  mkdir -p "$(dirname "$1")"
  openssl ca -gencrl -config "$CA/ca.cnf" -crlhours "$2" -out "$1" 2>/dev/null
}

datum() { date -u -d "$1" +%Y%m%d%H%M%SZ; }

# Lege repo met alleen het script; certs voegt elke case zelf toe.
nieuwe_repo() {
  local dst; dst="$TMP_ROOT/case-$(date +%s%N)-$RANDOM"
  mkdir -p "$dst/.github/scripts"
  cp "$REPO_ROOT/.github/scripts/check-cert-verloop.sh" "$dst/.github/scripts/"
  git -C "$dst" init -q
  printf '%s' "$dst"
}

commit_alles() {
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.org commit -qm fixture --allow-empty
}

# $1=omschrijving $2=verwachte exitcode $3=repo $4=termijn [$5=tekst die in de uitvoer moet staan]
expect() {
  local desc="$1" want="$2" dir="$3" dagen="$4" moet="${5:-}" got=0 uit
  cases=$((cases + 1))
  uit=$("$dir/.github/scripts/check-cert-verloop.sh" "$dagen" 2>&1) || got=$?
  if [ "$got" -ne "$want" ]; then
    printf 'FAAL  %s: verwacht exit %s, kreeg %s\n%s\n' "$desc" "$want" "$got" "$uit" >&2
    fails=$((fails + 1))
  elif [ -n "$moet" ] && ! grep -qF -- "$moet" <<<"$uit"; then
    printf 'FAAL  %s: uitvoer noemt %s niet\n%s\n' "$desc" "$moet" "$uit" >&2
    fails=$((fails + 1))
  else
    printf 'ok    %s (exit %s)\n' "$desc" "$got"
  fi
}

NU=$(datum now)
LANG_GELDIG=$(datum '+10 years')
MORGEN=$(datum '+1 day')

echo "Regressietest check-cert-verloop.sh"

# --- 0. Lange looptijd overal: groen, en elk bestand staat met einddatum in de uitvoer ----------
d=$(nieuwe_repo)
maak_cert "$d/pki/ca/root.pem" "$NU" "$LANG_GELDIG"
maak_cert "$d/pki/out/peer/manager/cert.pem" "$NU" "$LANG_GELDIG"
maak_crl "$d/pki/ca/intermediate.crl" $((24 * 3650))
commit_alles "$d"
expect "tien jaar geldig, termijn 30" 0 "$d" 30 "pki/out/peer/manager/cert.pem"
expect "CRL staat in de uitvoer" 0 "$d" 30 "pki/ca/intermediate.crl"

# --- 1. Cert van één dag valt binnen 30 dagen ---------------------------------------------------
d=$(nieuwe_repo)
maak_cert "$d/pki/ca/root.pem" "$NU" "$LANG_GELDIG"
maak_cert "$d/pki/internal/peer/inway/cert.pem" "$NU" "$MORGEN"
commit_alles "$d"
expect "cert van één dag, termijn 30" 1 "$d" 30 "pki/internal/peer/inway/cert.pem"
expect "cert van één dag, termijn 0 (nog niet verlopen)" 0 "$d" 0

# --- 2. Al verlopen cert is rood, ook met termijn 0 (de lint-stap) -----------------------------
d=$(nieuwe_repo)
maak_cert "$d/pki/out/peer/inway/cert.pem" 20200101000000Z 20200102000000Z
commit_alles "$d"
expect "verlopen cert, termijn 0" 1 "$d" 0 "pki/out/peer/inway/cert.pem"

# --- 3. CRL: nextUpdate binnen de termijn telt als verloop -------------------------------------
d=$(nieuwe_repo)
maak_crl "$d/pki/ca/intermediate.crl" 12
commit_alles "$d"
expect "CRL met nextUpdate over 12 uur, termijn 1" 1 "$d" 1 "pki/ca/intermediate.crl"
expect "CRL met nextUpdate over 12 uur, termijn 0" 0 "$d" 0

# --- 4. Alleen wat in git staat telt: dat is wat live draait -----------------------------------
d=$(nieuwe_repo)
maak_cert "$d/pki/ca/root.pem" "$NU" "$LANG_GELDIG"
commit_alles "$d"
maak_cert "$d/pki/out/peer/inway/cert.pem" 20200101000000Z 20200102000000Z
expect "verlopen maar niet gecommit cert telt niet" 0 "$d" 0

# --- 5. Een kapot certificaat is een fout, geen stil groen --------------------------------------
d=$(nieuwe_repo)
mkdir -p "$d/pki/ca"
printf -- '-----BEGIN CERTIFICATE-----\nZm91dA==\n-----END CERTIFICATE-----\n' > "$d/pki/ca/root.pem"
commit_alles "$d"
expect "onleesbaar certificaat" 2 "$d" 30 "pki/ca/root.pem"

# --- 6. Een .pem zonder cert of CRL (bv. een publieke sleutel) wordt overgeslagen ---------------
d=$(nieuwe_repo)
mkdir -p "$d/pki"
openssl pkey -in "$CA/ca-key.pem" -pubout -out "$d/pki/publiek.pem"
commit_alles "$d"
expect "publieke sleutel wordt overgeslagen" 0 "$d" 30

# --- 7. Geen certificaten: groen, maar wel gemeld ----------------------------------------------
d=$(nieuwe_repo)
commit_alles "$d"
expect "lege repo" 0 "$d" 30 "geen certificaten"

# --- 8. Ongeldige termijn ----------------------------------------------------------------------
d=$(nieuwe_repo)
expect "termijn is geen getal" 2 "$d" dertig

echo "${cases} cases, ${fails} gefaald"
[ "$fails" -eq 0 ]
