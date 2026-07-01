#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Smoke (#727): bewijst dat het contract-bootstrap-mechanisme een geldig, wederzijds
# ondertekend serviceConnection-contract oplevert tussen example-consumer en example-provider.
# Draait eerst de bootstrap (idempotent) en verifieert daarna ONAFHANKELIJK vanaf de
# consumer-manager dat het contract bij BEIDE peers geaccepteerd is.
#
# Volgorde: `docker compose up` -> publish-service.sh (provider) -> smoke-discover.sh (#725)
#           -> smoke-contract.sh (#727). De dienst moet bestaan om op te contracteren.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
COMPOSE=(docker compose -f "${HERE}/docker-compose.yaml")

SERVICE_NAME="${SERVICE_NAME:-example-service}"
CONSUMER_OIN="${CONSUMER_OIN:-00000000000000000020}"
PROVIDER_OIN="${PROVIDER_OIN:-00000000000000000030}"

# Verifieer vanaf de CONSUMER-manager (bootstrap.sh verifieert vanaf de provider-manager) zodat
# beide kanten van de mesh het geaccepteerde contract zien.
CONS_MANAGER="https://manager.example-consumer.fsc-test.local:9443"
CERT=/pki/internal/example-consumer/manager/cert.pem
KEY=/pki/internal/example-consumer/manager/key.pem
CA=/pki/internal/example-consumer/ca/root.pem

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

echo "smoke-contract: bootstrap draaien (idempotent)..."
bash "${REPO_ROOT}/contracts/bootstrap.sh"

echo "smoke-contract: onafhankelijk verifiëren vanaf de consumer-manager..."
OUT=$("${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
        --cert "$CERT" --key "$KEY" --cacert "$CA" \
        "$CONS_MANAGER/v1/contracts" 2>"$ERRLOG" || true)

if printf '%s' "$OUT" | grep -q "\"$SERVICE_NAME\"" \
   && printf '%s' "$OUT" | grep -q "$CONSUMER_OIN" \
   && printf '%s' "$OUT" | grep -q "$PROVIDER_OIN" \
   && printf '%s' "$OUT" | grep -q '"accept"'; then
  echo "OK: consumer-manager ziet het wederzijds ondertekende serviceConnection-contract."
  echo "SMOKE-CONTRACT GROEN."
  exit 0
fi

echo "FAIL: geen wederzijds ondertekend $SERVICE_NAME-contract zichtbaar op de consumer-manager." >&2
[ -s "$ERRLOG" ] && { echo "  -> laatste curl-fout:" >&2; tail -n 3 "$ERRLOG" >&2; }
echo "Debug: contracten (consumer) + manager-logs:" >&2
printf '%s\n' "$OUT" >&2
"${COMPOSE[@]}" logs --tail=50 manager-example-consumer manager-example-provider >&2 || true
exit 1
