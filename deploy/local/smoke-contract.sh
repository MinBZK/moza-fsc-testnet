#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Smoke: bewijst dat het contract-bootstrap-mechanisme een geldig, wederzijds
# ondertekend serviceConnection-contract oplevert tussen example-consumer en example-provider,
# en dat het idempotent is zonder lokaal state-bestand.
#
# Draait de bootstrap drie keer en controleert na elke run met een eigen GET op de consumer-manager
# (los van de exit-code van de bootstrap) dat er voor deze combinatie precies één niet-ingetrokken
# contract staat, dat het 'valid' is met PROVIDER-accept, en dat het over de runs heen hetzelfde
# contract blijft. Een run die er een contract bij maakt, faalt hier dus. De matcher zelf toetst
# contracts/contracten.test.sh.
#
# Volgorde: `docker compose up` -> publish-service.sh (provider) -> smoke-discover.sh
#           -> smoke-contract.sh. De dienst moet bestaan om op te contracteren.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
COMPOSE=(docker compose -f "${HERE}/docker-compose.yaml")

# shellcheck source-path=SCRIPTDIR source=../../contracts/contracten.sh
. "${REPO_ROOT}/contracts/contracten.sh"

SERVICE_NAME="${SERVICE_NAME:-example-service}"
CONSUMER_OIN="${CONSUMER_OIN:-00000000000000000020}"
PROVIDER_OIN="${PROVIDER_OIN:-00000000000000000030}"
OUTWAY_CERT_HOST="${OUTWAY_CERT_HOST:-${REPO_ROOT}/pki/out/example-consumer/outway/cert.pem}"
RUNS="${RUNS:-3}"
# Nul of een tikfout zou nul rondes en toch GROEN opleveren.
case "$RUNS" in ""|*[!0-9]*|0) echo "FAIL: RUNS moet een positief geheel getal zijn, niet '$RUNS'." >&2; exit 1 ;; esac

# Verifieer vanaf de CONSUMER-manager: daar resolvet de outway de grant, dus daar moet het contract
# wederzijds getekend en 'valid' zijn.
CONS_MANAGER="https://manager.example-consumer.fsc-test.local:9443"
CERT=/pki/internal/example-consumer/manager/cert.pem
KEY=/pki/internal/example-consumer/manager/key.pem
CA=/pki/internal/example-consumer/ca/root.pem

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq niet gevonden op de host (zie deploy/local/README.md)." >&2; exit 1; }
THUMB=$(outway_thumbprint "$OUTWAY_CERT_HOST") \
  || { echo "FAIL: kon outway-thumbprint niet berekenen uit $OUTWAY_CERT_HOST." >&2; exit 1; }

cons() { "${COMPOSE[@]}" exec -T toolbox curl -sS --fail-with-body \
           --cert "$CERT" --key "$KEY" --cacert "$CA" "$@" </dev/null 2>"$ERRLOG"; }

debug_en_faal() {
  echo "Debug: contracten voor deze combinatie (consumer) + manager-logs:" >&2
  printf '%s\n' "${REGELS:-<geen>}" | sed 's/^/  /' >&2
  "${COMPOSE[@]}" logs --tail=50 manager-example-consumer manager-example-provider >&2 || true
  exit 1
}

EERSTE=""
for run in $(seq 1 "$RUNS"); do
  echo "smoke-contract: bootstrap-run ${run}/${RUNS}..."
  bash "${REPO_ROOT}/contracts/bootstrap.sh"

  JSON=$(contracten_paginas cons "$CONS_MANAGER/v1/contracts?limit=1000&grant_type=GRANT_TYPE_SERVICE_CONNECTION") || {
    echo "FAIL: GET /v1/contracts (consumer) faalde: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }
  REGELS=$(contract_voor_combinatie "$JSON" "$SERVICE_NAME" "$PROVIDER_OIN" "$CONSUMER_OIN" "$THUMB") || {
    echo "FAIL: contractenlijst (consumer) niet te lezen." >&2; exit 1; }

  AANTAL=$(printf '%s\n' "$REGELS" | grep -c . || true)
  [ "$AANTAL" -eq 1 ] || { echo "FAIL: na run ${run} ${AANTAL} contracten voor deze combinatie, verwacht precies 1." >&2; debug_en_faal; }

  HASH=$(geldige_contracten "$REGELS")
  [ -n "$HASH" ] || { echo "FAIL: na run ${run} is het contract niet 'valid' met provider-accept op de consumer-manager." >&2; debug_en_faal; }

  if [ -z "$EERSTE" ]; then
    EERSTE="$HASH"
  elif [ "$HASH" != "$EERSTE" ]; then
    echo "FAIL: run ${run} leverde contract $HASH op, run 1 contract $EERSTE (niet idempotent)." >&2; debug_en_faal
  fi
  echo "OK: run ${run}: precies één geldig contract $HASH, met provider-accept op de consumer-manager."
done

echo "SMOKE-CONTRACT GROEN."
