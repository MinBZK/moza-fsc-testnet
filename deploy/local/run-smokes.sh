#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Host-runner (#727+): draait de VOLLEDIGE bewijs-keten van de lokale harness in één klap, zodat
# je een PR host-side kunt verifiëren. Groeit per issue mee (nieuwe smokes onderaan toevoegen).
#
#   certs (indien afwezig) -> .env -> docker compose up -d --build -> smokes op volgorde
#
# Bedoeld voor de docker-host waar deze repo volume-gemount is (geen push/pull nodig).
# Vereist: docker + docker compose v2, en cfssl/cfssljson/openssl voor de cert-generatie
# (zie pki/README.md). Draai vanuit een willekeurige map; paden worden zelf bepaald.
#
# Opties:
#   --no-build     compose up zónder --build (sneller als de wrapper-image al bestaat)
#   --regen-certs  forceer cert-hergeneratie (pki/issue.sh -f) ook als ze al bestaan
#   --keep         laat de stack draaien na afloop (default: `down -v` bij succes én falen)
#   -h|--help      toon deze hulp
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
COMPOSE=(docker compose -f "${HERE}/docker-compose.yaml")

BUILD="--build"; REGEN_CERTS=0; KEEP=0
for arg in "$@"; do
  case "$arg" in
    --no-build)    BUILD="" ;;
    --regen-certs) REGEN_CERTS=1 ;;
    --keep)        KEEP=1 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "onbekende optie: $arg (zie --help)" >&2; exit 2 ;;
  esac
done

teardown() { [ "$KEEP" -eq 1 ] && { echo ">> --keep: stack blijft draaien."; return; }
             echo ">> opruimen (down -v)..."; "${COMPOSE[@]}" down -v || true; }
fail() { echo "XX run-smokes FAALT: $1" >&2; teardown; exit 1; }

cd "$REPO_ROOT"

# --- 1. Certs (test-CA + per-peer). Regenereer alleen als afwezig of geforceerd. ---------------
if [ "$REGEN_CERTS" -eq 1 ] || [ ! -d pki/out ] || [ ! -d pki/internal ]; then
  echo ">> certs genereren (test-CA + per-peer)..."
  [ -f pki/ca/root.pem ] || ./pki/init-ca.sh
  ./pki/issue.sh -f
  ./pki/gen-crl.sh
  ./pki/fix-permissions.sh
  ./pki/verify.sh || fail "pki/verify.sh rood — certs onvolledig."
else
  echo ">> certs aanwezig (gebruik --regen-certs om te herbouwen)."
fi

# --- 2. .env: zorg dat HOST_UID/GID = de huidige gebruiker (last-wins append, non-destructief) --
[ -f deploy/local/.env ] || cp deploy/local/.env.example deploy/local/.env
printf 'HOST_UID=%s\nHOST_GID=%s\n' "$(id -u)" "$(id -g)" >> deploy/local/.env

# --- 3. Stack starten --------------------------------------------------------------------------
echo ">> docker compose up -d ${BUILD}..."
# shellcheck disable=SC2086
"${COMPOSE[@]}" up -d $BUILD || fail "compose up faalde."

# --- 4. Smokes op volgorde (elke stap fail-hard). Groeit per issue. ----------------------------
run() { echo; echo "======== $1 ========"; bash "${HERE}/$1" || fail "$1 rood."; }

run smoke-announce.sh    # #723/#724 — provider announce
run smoke-publish.sh     # #724     — dienst publiceren + vindbaar
run smoke-discover.sh    # #725     — consumer announce + discovery
run smoke-contract.sh    # #727     — wederzijds ondertekend serviceConnection-contract
# TODO(#728): run smoke-e2e.sh    — echte data-call + token + transactie-logging

echo; echo "==================================================="
echo "ALLE SMOKES GROEN."
echo "==================================================="
teardown
