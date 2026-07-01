#!/usr/bin/env bash
# Smoke (#724): bewijst dat example-service gepubliceerd is en als GELDIGE publicatie
# vindbaar is bij de directory. Draait eerst de onboarding, pollt daarna de manager
# Internal-API (GET /v1/peers/{dir}/services) tot example-service verschijnt.
set -euo pipefail

HERE="$(dirname "$0")"
COMPOSE=(docker compose -f "$HERE/docker-compose.yaml")
SERVICE_NAME="example-service"
PROVIDER_OIN="00000000000000000030"
DIR_OIN="00000000000000000010"
TIMEOUT=10; INTERVAL=2

CERT=/pki/internal/example-provider/manager/cert.pem
KEY=/pki/internal/example-provider/manager/key.pem
CA=/pki/internal/example-provider/ca/root.pem
MANAGER=https://manager.example-provider.fsc-test.local:9443

echo "smoke-publish: onboarding draaien..."
bash "$HERE/publish-service.sh"

echo "smoke-publish: pollen tot $SERVICE_NAME vindbaar is bij de directory..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  out=$("${COMPOSE[@]}" exec -T toolbox curl -s \
          --cert "$CERT" --key "$KEY" --cacert "$CA" \
          "$MANAGER/v1/peers/$DIR_OIN/services?peer_id=$PROVIDER_OIN" || true)
  if printf '%s' "$out" | grep -q "\"$SERVICE_NAME\""; then
    echo "OK: $SERVICE_NAME is gepubliceerd en vindbaar in de directory."
    printf '%s\n' "$out"
    exit 0
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet vindbaar (${elapsed}s)"
done

echo "FAIL: $SERVICE_NAME niet vindbaar binnen ${TIMEOUT}s." >&2
echo "Debug: publicaties (eigen manager) + inways + logs:" >&2
"${COMPOSE[@]}" exec -T toolbox curl -s --cert "$CERT" --key "$KEY" --cacert "$CA" \
   "$MANAGER/v1/services/publications" >&2 || true
"${COMPOSE[@]}" logs --tail=50 manager-example-provider manager-directory inway-example-provider >&2 || true
exit 1
