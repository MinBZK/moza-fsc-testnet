#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Smoke (#727): bewijst dat het contract-bootstrap-mechanisme een geldig, wederzijds
# ondertekend serviceConnection-contract oplevert tussen example-consumer en example-provider.
# Draait eerst de bootstrap (idempotent) en verifieert daarna ONAFHANKELIJK vanaf de
# consumer-manager dat EXACT dat contract (op zijn globaal-unieke content_hash) mesh-breed
# gesynct/zichtbaar is — d.w.z. dat de accept ook aan de consumer-kant is aangekomen.
#
# Waarom scoped op content_hash: op beide managers staat óók het auto-geaccepteerde
# servicePublication-contract voor dezelfde example-service; een losse grep op servicenaam/OIN/
# "accept" zou daardoor altijd matchen (false green). De content_hash is uniek voor óns contract.
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
STATE_FILE="${STATE_FILE:-${REPO_ROOT}/contracts/.bootstrap-state/${CONSUMER_OIN}-${PROVIDER_OIN}-${SERVICE_NAME}.hash}"

# Verifieer vanaf de CONSUMER-manager (bootstrap verifieert vanaf de provider-manager) zodat
# beide kanten van de mesh het geaccepteerde contract zien.
CONS_MANAGER="https://manager.example-consumer.fsc-test.local:9443"
CERT=/pki/internal/example-consumer/manager/cert.pem
KEY=/pki/internal/example-consumer/manager/key.pem
CA=/pki/internal/example-consumer/ca/root.pem

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

echo "smoke-contract: bootstrap draaien (idempotent)..."
bash "${REPO_ROOT}/contracts/bootstrap.sh"

# De bootstrap schrijft de content_hash van het geaccepteerde contract naar de state-file.
[ -f "$STATE_FILE" ] || { echo "FAIL: geen state-file ($STATE_FILE) — bootstrap heeft geen contract vastgelegd." >&2; exit 1; }
HASH=$(cat "$STATE_FILE")
[ -n "$HASH" ] || { echo "FAIL: lege content_hash in $STATE_FILE." >&2; exit 1; }
echo "smoke-contract: verifiëren dat contract $HASH ook op de consumer-manager staat..."

OUT=$("${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
        --cert "$CERT" --key "$KEY" --cacert "$CA" \
        "$CONS_MANAGER/v1/contracts" 2>"$ERRLOG") || {
  echo "FAIL: GET /v1/contracts (consumer) faalde: $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }

if printf '%s' "$OUT" | grep -qF "$HASH"; then
  echo "OK: consumer-manager ziet het wederzijds ondertekende serviceConnection-contract $HASH."
  echo "SMOKE-CONTRACT GROEN."
  exit 0
fi

echo "FAIL: contract $HASH niet zichtbaar op de consumer-manager (mesh-sync na accept?)." >&2
echo "Debug: contracten (consumer) + manager-logs:" >&2
printf '%s\n' "$OUT" >&2
"${COMPOSE[@]}" logs --tail=50 manager-example-consumer manager-example-provider >&2 || true
exit 1
