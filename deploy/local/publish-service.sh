#!/usr/bin/env bash
# Onboarding (#724): maakt example-service aan op de controller Administration-API en
# publiceert 'm via een servicePublication-contract op de eigen manager Internal-API.
# Idempotent: slaat create/publish over als ze er al zijn. Manager hasht+signt het
# contract server-side; de directory (AUTO_SIGN_GRANTS=servicePublication) auto-accept.
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
SERVICE_NAME="example-service"
PROVIDER_OIN="00000000000000000030"
DIR_OIN="00000000000000000010"
GROUP_ID="moza-fbs-test"                 # zie runtime-onzekerheid 5
STUB_URL="http://stub-upstream:8080"

CERT=/pki/internal/example-provider/manager/cert.pem
KEY=/pki/internal/example-provider/manager/key.pem
CA=/pki/internal/example-provider/ca/root.pem
CONTROLLER=https://controller.example-provider.fsc-test.local:9444
MANAGER=https://manager.example-provider.fsc-test.local:9443

# curl binnen de toolbox, met de internal client-cert.
tb() { "${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
         --cert "$CERT" --key "$KEY" --cacert "$CA" "$@"; }

echo "publish: wachten op inway-registratie bij de controller..."
# inway->controller-registratie is asynchroon na boot; poll (spiegelt smoke-announce.sh)
# i.p.v. één harde fetch, anders racet een koude start de eerste publish-run.
INWAY_ADDR=""
elapsed=0
while [ "$elapsed" -lt 60 ]; do
  INWAY_ADDR=$(tb "$CONTROLLER/v1/inways" | grep -o '"[^"]*example-provider-inway[^"]*"' | head -1 | tr -d '"' || true)
  [ -n "$INWAY_ADDR" ] && break
  sleep 5; elapsed=$((elapsed + 5))
  echo "  ...inway nog niet geregistreerd (${elapsed}s)"
done
[ -n "$INWAY_ADDR" ] || { echo "FAIL: geen geregistreerde inway op de controller binnen 60s." >&2; exit 1; }
echo "  inway_address=$INWAY_ADDR"

echo "publish: example-service aanmaken (idempotent)..."
if tb "$CONTROLLER/v1/services" | grep -q "\"$SERVICE_NAME\""; then
  echo "  bestaat al, skip create."
else
  tb -X POST "$CONTROLLER/v1/services" -H 'Content-Type: application/json' \
     -d "{\"name\":\"$SERVICE_NAME\",\"endpoint_url\":\"$STUB_URL\",\"inway_address\":\"$INWAY_ADDR\"}"
  echo "  aangemaakt."
fi

echo "publish: servicePublication-contract indienen (idempotent)..."
if tb "$MANAGER/v1/services/publications" | grep -q "\"$SERVICE_NAME\""; then
  echo "  al gepubliceerd, skip contract."
else
  IV=$("${COMPOSE[@]}" exec -T toolbox cat /proc/sys/kernel/random/uuid)   # 36 tekens; zie onzekerheid 4
  NBF=$("${COMPOSE[@]}" exec -T toolbox date -u +%s)
  NAF=$((NBF + 315360000))                                                 # +10 jaar
  tb -X POST "$MANAGER/v1/contracts" -H 'Content-Type: application/json' -d "{
    \"contract_content\": {
      \"iv\": \"$IV\",
      \"group_id\": \"$GROUP_ID\",
      \"hash_algorithm\": \"HASH_ALGORITHM_SHA3_512\",
      \"created_at\": $NBF,
      \"validity\": { \"not_before\": $((NBF - 60)), \"not_after\": $NAF },
      \"grants\": [ {
        \"type\": \"GRANT_TYPE_SERVICE_PUBLICATION\",
        \"directory\": { \"peer_id\": \"$DIR_OIN\" },
        \"service\": { \"peer_id\": \"$PROVIDER_OIN\", \"name\": \"$SERVICE_NAME\", \"protocol\": \"PROTOCOL_TCP_HTTP_1.1\" }
      } ]
    }
  }"
  echo "  contract ingediend (manager signt; directory auto-accept)."
fi
echo "publish: klaar."
