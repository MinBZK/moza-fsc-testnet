#!/usr/bin/env bash
# Onboarding: maakt example-service aan op de controller Administration-API en
# publiceert 'm via een servicePublication-contract op de eigen manager Internal-API.
# Idempotent: slaat create/publish over als ze er al zijn. Manager hasht+signt het
# contract server-side; de directory (AUTO_SIGN_GRANTS=servicePublication) auto-accept.
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
SERVICE_NAME="example-service"
PROVIDER_OIN="00000000000000000030"
DIR_OIN="00000000000000000010"
GROUP_ID="moza-fbs-test"                 # = GROUP_ID env-var op de manager; als de manager een directory-adres verwacht, gebruik DIRECTORY_MANAGER_ADDRESS
STUB_URL="http://stub-upstream:8080"

CERT=/pki/internal/example-provider/manager/cert.pem
KEY=/pki/internal/example-provider/manager/key.pem
CA=/pki/internal/example-provider/ca/root.pem
CONTROLLER=https://controller.example-provider.fsc-test.local:9444
MANAGER=https://manager.example-provider.fsc-test.local:9443

# Vang curl-/toolbox-stderr op i.p.v. weg te gooien: een mTLS-/netwerk-/dode-container-fout
# mag niet als "nog niet klaar" maskeren (spiegelt smoke-announce.sh). Surface 'm in de loop.
ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

# curl binnen de toolbox, met de internal client-cert. Stderr -> ERRLOG.
tb() { "${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
         --cert "$CERT" --key "$KEY" --cacert "$CA" "$@" 2>"$ERRLOG"; }

echo "publish: wachten op inway-registratie bij de controller..."
# inway->controller-registratie is asynchroon na boot; poll (spiegelt smoke-announce.sh)
# i.p.v. één harde fetch, anders racet een koude start de eerste publish-run.
INWAY_ADDR=""
elapsed=0
while [ "$elapsed" -lt 60 ]; do
  # CreateService verwacht het inway-ADRES (https://...:443, = SELF_ADDRESS), niet de naam.
  INWAY_ADDR=$(tb "$CONTROLLER/v1/inways" | grep -o 'https://inway\.example-provider\.fsc-test\.local:443' | head -1 || true)
  [ -n "$INWAY_ADDR" ] && break
  # Persistente fout (verkeerd cert-pad, dode toolbox, DNS) mag niet als "traag boot" maskeren.
  [ -s "$ERRLOG" ] && { echo "  WARN: controller-fout: $(tail -n1 "$ERRLOG")" >&2; : >"$ERRLOG"; }
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
  # UUID + timestamp zijn host-lokaal (geen container-context nodig) -> host-builtins i.p.v. toolbox-exec.
  # UUID v4 (36 tekens): /proc is Linux-only, op macOS valt 'ie terug op uuidgen (lowercase).
  # Als de manager 400 geeft op het iv-formaat, genereer UUID v7.
  IV=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  # Docker Desktop (macOS) draait in een VM waarvan de klok op de host kan achterlopen; de manager
  # weigert dan created_at "in the future" (HTTP 500). Backdate met een skew-marge — op Linux is de
  # skew ~0, dus onschadelijk. Blijft persistent falen? Herstart de Docker-VM (klok resynct).
  NBF=$(( $(date -u +%s) - 60 ))
  NAF=$((NBF + 315360000))                 # +10 jaar
  # --fail-with-body laat curl bij 4xx/5xx non-zero exiten MAAR print de body; vang beide (spiegelt
  # bootstrap.sh) zodat `set -e` ons niet vóór de diagnostiek killt en de manager-respons zichtbaar is.
  RESP=$(tb -X POST "$MANAGER/v1/contracts" -H 'Content-Type: application/json' -d "{
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
  }") || { echo "FAIL: POST /v1/contracts geweigerd (iv=$IV): ${RESP:-<leeg>} $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2; exit 1; }
  # Een 2xx zónder content_hash duidt op een geweigerd formaat (iv/group_id).
  printf '%s' "$RESP" | grep -q '"content_hash"' \
    || { echo "FAIL: contract-respons zonder content_hash (mogelijk geweigerd iv/group_id-formaat): $RESP" >&2; exit 1; }
  echo "  contract ingediend (manager signt; directory auto-accept): $RESP"
fi
echo "publish: klaar."
