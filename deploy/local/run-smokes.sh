#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Host-runner: draait de VOLLEDIGE bewijs-keten van de lokale harness in één klap, zodat
# je een PR host-side kunt verifiëren. Groeit per issue mee (nieuwe smokes onderaan toevoegen).
#
#   certs (indien afwezig) -> .env -> docker compose up -d --build -> smokes op volgorde
#
# Bedoeld voor de docker-host waar deze repo volume-gemount is (geen push/pull nodig).
# Vereist: docker + docker compose v2, en sops + age met toegang tot de geheime repo voor de
# sleutels (zie docs/sleutelbeheer.md), of --wegwerp-ca; cfssl alleen voor nieuwe certs. Draai
# vanuit een willekeurige map; paden worden zelf bepaald.
#
# Opties:
#   --wegwerp-ca   eigen test-CA in een tijdelijke map, zonder de geheime repo (vereist cfssl); voor
#                  wie geen toegang heeft. pki/ van de checkout blijft onaangeroerd.
#   --no-build     compose up zónder --build (sneller als de wrapper-image al bestaat)
#   --keep         laat de stack draaien na afloop (default: `down -v` bij succes én falen)
#   -h|--help      toon deze hulp
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
COMPOSE=(docker compose -f "${HERE}/docker-compose.yaml")

BUILD="--build"; KEEP=0; WEGWERP=0; WEGWERP_DIR=""
for arg in "$@"; do
  case "$arg" in
    --wegwerp-ca)  WEGWERP=1 ;;
    --no-build)    BUILD="" ;;
    # De certs staan in git en draaien ook op ZAD: alles opnieuw uitgeven voor een lokale smoke
    # zou de live set vervangen. Zie docs/sleutelbeheer.md.
    --regen-certs) echo "--regen-certs is vervallen: certs staan in git, sleutels in de geheime repo." >&2; exit 2 ;;
    --keep)        KEEP=1 ;;
    -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "onbekende optie: $arg (zie --help)" >&2; exit 2 ;;
  esac
done

teardown() {
  if [ "$KEEP" -eq 1 ]; then
    echo ">> --keep: stack blijft draaien."
    if [ -n "$WEGWERP_DIR" ]; then
      echo ">> de stack leest de wegwerp-PKI in ${WEGWERP_DIR}; ruim die na 'down' zelf op."
    fi
    return 0
  fi
  echo ">> opruimen (down -v --remove-orphans)..."; "${COMPOSE[@]}" down -v --remove-orphans || true
  [ -z "$WEGWERP_DIR" ] || rm -rf "$WEGWERP_DIR"
}
fail() { echo "XX run-smokes FAALT: $1" >&2; teardown; exit 1; }
# Ook bij Ctrl-C opruimen, zoals bij elke andere fout.
trap 'fail "afgebroken"' INT TERM

cd "$REPO_ROOT"

# --- 0. Harde host-dependencies vooraf. De contract-bootstrap en smoke-groepsversie.sh hebben jq
#        nodig. Zonder deze check valt dat pas op midden in de reeks: dan staan de certs, de stack
#        en de eerste groene smokes er al, en gooit de teardown `down -v` het weer allemaal weg om
#        een ontbrekend hostpakket. Faal vóór er iets gebouwd is. --------------------------------
command -v jq >/dev/null 2>&1 || fail "jq niet gevonden — de contract-bootstrap vereist 't (zie README, Benodigdheden)."

# --- 1. Certs en sleutels. De certs staan in git, de sleutels in de geheime repo. Een CSR zonder
#        cert (bv. een nieuw endpoint zoals txlog) krijgt er een via issue.sh; anders skipt
#        'aanwezig' die stil. Met --wegwerp-ca een eigen PKI buiten de checkout. --------------------
# Alleen de peers die docker-compose.yaml mount; de groepssleutel heeft de stack niet nodig.
STACK_PEERS=(directory example-provider example-consumer)
need_keys() {
  local p c
  for p in "${STACK_PEERS[@]}"; do
    for c in "pki/out/$p"/*/cert.pem "pki/internal/$p"/*/cert.pem; do
      [ -e "$c" ] || continue
      [ -s "${c%cert.pem}key.pem" ] || return 0
    done
  done
  return 1
}
need_certs() {
  { [ ! -d pki/out ] || [ ! -d pki/internal ]; } && return 0
  local csr rel
  while IFS= read -r csr; do
    rel=${csr#pki/peers/}; rel=${rel%/csr.json}
    [ -s "pki/internal/${rel}/cert.pem" ] && [ -s "pki/out/${rel}/cert.pem" ] || return 0
  done < <(find pki/peers -name csr.json)
  return 1
}
echte_pki() {
  if need_keys; then
    echo ">> sleutels ophalen uit de geheime repo (${STACK_PEERS[*]})..."
    ./pki/geheimen.sh ophalen "${STACK_PEERS[@]}" \
      || fail "pki/geheimen.sh ophalen faalde (zie docs/sleutelbeheer.md). Geen toegang tot de geheime repo? Draai met --wegwerp-ca."
  fi
  if need_certs; then
    echo ">> certs uitgeven voor nieuwe CSR's..."
    ./pki/issue.sh || fail "pki/issue.sh faalde."
    ./pki/fix-permissions.sh || fail "pki/fix-permissions.sh faalde."
    echo ">> nieuwe certs: sla de sleutels op (pki/geheimen.sh opslaan) en commit de certs."
    # Draaiende containers hebben de OUDE certs nog in geheugen; force-recreate zodat alles de
    # nieuwe set herlaadt.
    RECREATE="--force-recreate"
  else
    echo ">> certs aanwezig + compleet."
  fi
  # Altijd verifiëren — óók op het "al aanwezig"-pad: stale/onvolledige certs (bv. onderbroken run)
  # mogen niet ongemerkt de stack in en zich later als vage mTLS-fouten voordoen.
  ./pki/verify.sh || fail "pki/verify.sh rood (zie docs/sleutelbeheer.md)."
}
RECREATE=""
if [ "$WEGWERP" -eq 1 ]; then
  # Onder $HOME en niet in /tmp: niet elke docker-host deelt /tmp met de containers (snap-docker,
  # Colima).
  wegwerp_basis="${XDG_CACHE_HOME:-$HOME/.cache}/moza-fsc-testnet"
  mkdir -p "$wegwerp_basis"
  WEGWERP_DIR=$(mktemp -d "${wegwerp_basis}/wegwerp-pki.XXXXXX")
  echo ">> wegwerp-PKI bouwen in ${WEGWERP_DIR}..."
  "${HERE}/wegwerp-pki.sh" "$WEGWERP_DIR" || fail "deploy/local/wegwerp-pki.sh faalde."
  # Gaat vóór PKI_DIR uit .env, ook voor de compose-aanroepen in de smokes.
  export PKI_DIR="${WEGWERP_DIR}/pki"
  # De contract-bootstrap rekent de grant-thumbprint op de host uit, standaard uit pki/ van de
  # checkout; die moet bij het outway-cert in de stack passen.
  export OUTWAY_CERT_HOST="${PKI_DIR}/out/example-consumer/outway/cert.pem"
  # Containers van een eerdere run kennen een andere CA.
  RECREATE="--force-recreate"
else
  echte_pki
fi

# --- 2. .env: zet HOST_UID/GID = de huidige gebruiker (idempotent: bestaande regels vervangen) --
ENV_FILE=deploy/local/.env
[ -f "$ENV_FILE" ] || cp deploy/local/.env.example "$ENV_FILE"
# Strip eventuele eerdere HOST_UID/HOST_GID-regels en zet ze één keer opnieuw (geen ongebreidelde
# aangroei van dubbele regels bij herhaald draaien).
tmp_env=$(mktemp)
grep -vE '^HOST_(UID|GID)=' "$ENV_FILE" > "$tmp_env" || true
printf 'HOST_UID=%s\nHOST_GID=%s\n' "$(id -u)" "$(id -g)" >> "$tmp_env"
mv "$tmp_env" "$ENV_FILE"

# POSTGRES_PASSWORD: eenmalig genereren, daarna met rust laten. Anders dan HOST_UID/GID mag deze
# NIET bij elke run overschreven worden — postgres bakt het wachtwoord bij `initdb` in het volume,
# dus een nieuwe waarde op een bestaand volume geeft auth-fouten in plaats van een verse start.
# .env.example laat de regel uitgecommentarieerd, juist zodat deze test alleen naar een échte
# waarde kijkt en een handmatig gezet wachtwoord nooit overschrijft.
if ! grep -qE '^POSTGRES_PASSWORD=.+$' "$ENV_FILE"; then
  command -v openssl >/dev/null 2>&1 || fail "openssl niet gevonden — nodig om POSTGRES_PASSWORD te genereren."
  tmp_env=$(mktemp)
  grep -vE '^POSTGRES_PASSWORD=' "$ENV_FILE" > "$tmp_env" || true
  printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 16)" >> "$tmp_env"
  mv "$tmp_env" "$ENV_FILE"
  echo ">> POSTGRES_PASSWORD gegenereerd in $ENV_FILE (eenmalig; blijft staan bij volgende runs)."
fi

# --- 3. Stack starten --------------------------------------------------------------------------
# --remove-orphans: ruim containers op van een vórige (hernoemde) compose (bv. het oude
# `controller` vóór de rename naar `controller-example-provider`) die anders een host-poort
# bezet houden (`port is already allocated`).
echo ">> docker compose up -d ${BUILD} --remove-orphans ${RECREATE}..."
# shellcheck disable=SC2086
"${COMPOSE[@]}" up -d $BUILD --remove-orphans $RECREATE || fail "compose up faalde."

# --- 4. Smokes op volgorde (elke stap fail-hard). Groeit per issue. ----------------------------
run() { echo; echo "======== $1 ========"; bash "${HERE}/$1" || fail "$1 rood."; }

run smoke-announce.sh    # provider announce
run smoke-publish.sh     # dienst publiceren + vindbaar
run smoke-discover.sh    # consumer announce + discovery
run smoke-contract.sh    # wederzijds ondertekend serviceConnection-contract
run smoke-e2e.sh         # echte data-call + token-afdwinging + tx-log-correlatie
run smoke-groepsversie.sh  # contracten dragen de FSC-versie uit de group-regel

echo; echo "==================================================="
echo "ALLE SMOKES GROEN."
echo "==================================================="
teardown
