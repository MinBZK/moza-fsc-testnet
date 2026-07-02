#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Zet de directory op ZAD via de v2 Operations Manager API (#723). Eén bron voor CLI + de
# workflow zad-deploy-directory.yml. Zie docs/zad-directory-deploy.md en [[zad-deploy-api-model]].
#
# Model: PR = eigen deployment `pr-<PR-nummer>`; main -> deployment `test`. `:upsert-deployment` zet
# per component de {reference,image} (DAAR hangt het draaiende image van het deployment) én maakt/
# updatet het deployment; POST /components verrijkt elke component met env_vars/port/services/aliases.
# Previews kunnen `cloneFrom` een bestaande deployment (erven componenten; images uit de upsert-body).
# NIET via de API (UI-only): bijlagen (cert-mount) + "Publicatie op het web" (passthrough-TLS).
#
# DB: ZAD's managed Postgres (`postgresql-database`-service op de manager). De connection komt uit
# substitutievars ($DATABASE_SERVER_HOST/$DATABASE_DB/$DATABASE_SERVER_USER/$DATABASE_PASSWORD),
# via een alias in STORAGE_POSTGRES_DSN gegoten. Geen eigen postgres-component.
#
# Usage:
#   export ZAD_API_KEY=...                          # niet inline (echo't anders)
#   ./deploy/zad/upsert-directory.sh validate                       # read-only auth-check
#   ./deploy/zad/upsert-directory.sh plan   [deployment] [tag] [clone_from]   # toont bodies, muteert niet
#   ./deploy/zad/upsert-directory.sh apply  [deployment] [tag] [clone_from]   # muteert + pollt tasks
# Env: ZAD_API_KEY (verplicht), ZAD_PROJECT (mft-tp9), ZAD_BASE (zad.rijksapp.nl),
#      ZAD_BASE_DOMAIN (rig.prd1...), ZAD_MANAGER_TAG (ghcr manager-tag), ZAD_PG_SSLMODE (disable).
set -euo pipefail

MODE="${1:?usage: upsert-directory.sh <validate|plan|apply> [deployment=test] [tag=v1.43.7] [clone_from]}"
DEPLOYMENT="${2:-test}"
IMAGE_TAG="${3:-v1.43.7}"               # OpenFSC stock-tag (directory-ui, en default voor de manager)
CLONE_FROM="${4:-}"
MANAGER_TAG="${ZAD_MANAGER_TAG:-${IMAGE_TAG}}"   # manager-migrate (onze ghcr-image) kan een eigen tag hebben
PROJECT="${ZAD_PROJECT:-mft-tp9}"
BASE="${ZAD_BASE:-https://zad.rijksapp.nl}"
BASE_DOMAIN="${ZAD_BASE_DOMAIN:-rig.prd1.gn2.quattro.rijksapps.nl}"
PG_SSLMODE="${ZAD_PG_SSLMODE:-disable}"          # managed DB intra-cluster: plaintext (zoals berichtenbox-JDBC)

case "${MODE}" in validate|plan|apply) ;; *) echo "mode = validate | plan | apply"; exit 1 ;; esac
case "${DEPLOYMENT}" in ""|*[!a-z0-9-]*) echo "ongeldige deployment: '${DEPLOYMENT}'"; exit 1 ;; esac
case "${IMAGE_TAG}" in ""|*[!A-Za-z0-9._-]*) echo "ongeldige image_tag: '${IMAGE_TAG}'"; exit 1 ;; esac
case "${MANAGER_TAG}" in ""|*[!A-Za-z0-9._-]*) echo "ongeldige ZAD_MANAGER_TAG: '${MANAGER_TAG}'"; exit 1 ;; esac
case "${CLONE_FROM}" in *[!a-z0-9-]*) echo "ongeldige clone_from: '${CLONE_FROM}'"; exit 1 ;; esac
[ "${MODE}" = apply ] && : "${ZAD_API_KEY:?zet ZAD_API_KEY in je env}"

MANAGER_IMAGE="ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:${MANAGER_TAG}"
UI_IMAGE="docker.io/federatedserviceconnectivity/directory-ui:${IMAGE_TAG}"
MANAGER_HOST="dirmgr-${DEPLOYMENT}-${PROJECT}.${BASE_DOMAIN}"        # deze deployment (voor display)
# Deployment-agnostisch: ZAD vult $DEPLOYMENT_NAME per deployment in -> hoort in de aliases, zodat
# één (project-brede) component-definitie in elke deployment (test, pr-...) de juiste hostnaam krijgt.
SELF_HOST='dirmgr-$DEPLOYMENT_NAME-'"${PROJECT}.${BASE_DOMAIN}"

# --- env-blobs (KEY=value, newline-sep, plain). TLS_*-paden = de bijlage-mounts (UI, ontwerp A). ---
MANAGER_ENV="$(printf '%s\n' \
  "LOG_TYPE=live" "LOG_LEVEL=info" "AUDITLOG_TYPE=stdout" \
  "GROUP_ID=moza-fbs-test" \
  "DIRECTORY_PEER_ID=00000000000000000010" \
  "TX_LOG_API_ADDRESS=" \
  "AUTO_SIGN_GRANTS=servicePublication,delegatedServicePublication" \
  "LISTEN_ADDRESS_EXTERNAL=0.0.0.0:8443" \
  "LISTEN_ADDRESS_INTERNAL=0.0.0.0:9443" \
  "LISTEN_ADDRESS_INTERNAL_UNAUTHENTICATED=0.0.0.0:9444" \
  "MONITORING_ADDRESS=0.0.0.0:8080" \
  "DISABLE_CRL_CHECKS=true" \
  "TLS_GROUP_ROOT_CERT=/etc/fsc/ca/root.pem" \
  "TLS_GROUP_CERT=/etc/fsc/out/directory/directory/cert.pem" \
  "TLS_GROUP_KEY=/etc/fsc/out/directory/directory/key.pem" \
  "TLS_GROUP_TOKEN_CERT=/etc/fsc/out/directory/directory/cert.pem" \
  "TLS_GROUP_TOKEN_KEY=/etc/fsc/out/directory/directory/key.pem" \
  "TLS_GROUP_CONTRACT_CERT=/etc/fsc/out/directory/directory/cert.pem" \
  "TLS_GROUP_CONTRACT_KEY=/etc/fsc/out/directory/directory/key.pem" \
  "TLS_ROOT_CERT=/etc/fsc/internal/directory/ca/root.pem" \
  "TLS_CERT=/etc/fsc/internal/directory/directory/cert.pem" \
  "TLS_KEY=/etc/fsc/internal/directory/directory/key.pem" \
  "TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT=/etc/fsc/internal/directory/ca/root.pem" \
  "TLS_INTERNAL_UNAUTHENTICATED_CERT=/etc/fsc/internal/directory/directory/cert.pem" \
  "TLS_INTERNAL_UNAUTHENTICATED_KEY=/etc/fsc/internal/directory/directory/key.pem")"

# Aliases = env-vars met ZAD-substitutievars ($DEPLOYMENT_NAME voor de eigen hostnaam, $DATABASE_*
# voor de managed Postgres). \$ houdt ze letterlijk (ZAD vult ze per deployment in, niet de shell).
# :443 = de mesh-poort (ingress SNI-passthrough -> pod :8443). OpenFSC eist een expliciete poort in
# het manager-adres ("missing port in manager address" -> Fatal in create-self-peer) — dus niet weglaten.
MANAGER_ALIASES="$(printf '%s\n' \
  "SELF_ADDRESS=https://${SELF_HOST}:443" \
  "DIRECTORY_MANAGER_ADDRESS=https://${SELF_HOST}:443" \
  "STORAGE_POSTGRES_DSN=postgres://\$DATABASE_SERVER_USER:\$DATABASE_PASSWORD@\$DATABASE_SERVER_HOST:5432/\$DATABASE_DB?sslmode=${PG_SSLMODE}")"

UI_ENV="$(printf '%s\n' \
  "LOG_TYPE=live" "LOG_LEVEL=info" \
  "LISTEN_ADDRESS=0.0.0.0:8080" \
  "MONITORING_ADDRESS=0.0.0.0:8081" \
  "BASE_URL_PATH=/" \
  "TLS_GROUP_ROOT_CERT=/etc/fsc/ca/root.pem" \
  "TLS_GROUP_CERT=/etc/fsc/out/directory/directory/cert.pem" \
  "TLS_GROUP_KEY=/etc/fsc/out/directory/directory/key.pem")"
UI_ALIASES="DIRECTORY_MANAGER_ADDRESS=https://${SELF_HOST}:443"

# component-body (AddComponentRequest) via jq -> correcte JSON-escaping.
component_body() {  # $1=name $2=image $3=port $4=env  [$5=services_json=[]]  [$6=aliases=""]
  jq -n --arg name "$1" --arg image "$2" --argjson port "$3" --arg env "$4" \
        --argjson services "${5:-[]}" --arg aliases "${6:-}" --arg dep "${DEPLOYMENT}" \
    '{name:$name, image:$image, port:$port, env_vars:$env, deployment_names:[$dep]}
     + (if ($services|length) > 0 then {services:$services} else {} end)
     + (if $aliases == "" then {} else {aliases:$aliases} end)'
}

DEPLOY_BODY="$(jq -n --arg d "${DEPLOYMENT}" --arg cf "${CLONE_FROM}" \
  --arg mgr "${MANAGER_IMAGE}" --arg ui "${UI_IMAGE}" \
  '{deploymentName:$d, domain_format:"component-deployment-project",
    components:[{reference:"dirmgr", image:$mgr}, {reference:"dirui", image:$ui}]}
   + (if $cf=="" then {} else {cloneFrom:$cf, forceClone:true} end)')"

MANAGER_BODY="$(component_body dirmgr "${MANAGER_IMAGE}" 8443 "${MANAGER_ENV}" '["postgresql-database"]' "${MANAGER_ALIASES}")"
UI_BODY="$(component_body dirui "${UI_IMAGE}" 8080 "${UI_ENV}" '[]' "${UI_ALIASES}")"

# ---- plan: toon alleen ----
if [ "${MODE}" = plan ]; then
  echo "### deployment (:upsert-deployment)"; echo "${DEPLOY_BODY}"
  if [ -z "${CLONE_FROM}" ]; then
    echo "### component dirmgr (manager + managed Postgres)"; echo "${MANAGER_BODY}"
    echo "### component dirui";                               echo "${UI_BODY}"
  else
    echo "(cloneFrom=${CLONE_FROM} -> componenten geërfd; geen POST /components)"
  fi
  echo "Manager-hostnaam: ${MANAGER_HOST}  (SELF_ADDRESS / SNI / Publicatie-op-het-web modus 2)"
  exit 0
fi

API="${BASE}/api/v2/projects/${PROJECT}"
resp="$(mktemp)"; trap 'rm -f "${resp}"' EXIT
hdr=(-H "X-API-Key: ${ZAD_API_KEY}")

poll_task() {  # $1=task_id
  local id="$1" i status
  for i in $(seq 1 45); do
    # --fail: HTTP 4xx/5xx op de tasks-API mag niet als "nog bezig" (status=null) tellen; retry.
    if ! curl -sS --fail "${hdr[@]}" "${BASE}/api/tasks/${id}" -o "${resp}"; then
      echo "  task ${id}: tasks-API HTTP-fout (poging ${i}/45) — retry" >&2
      sleep 2; continue
    fi
    status="$(jq -r '.status' "${resp}")"
    case "${status}" in
      completed) echo "  task ${id}: completed"; return 0 ;;
      failed)    echo "  task ${id}: FAILED -> $(jq -r '.error_message // .result.error' "${resp}")" >&2; return 1 ;;
      *)         sleep 2 ;;
    esac
  done
  echo "  task ${id}: nog bezig na ~90s (async ArgoCD-sync) — niet geblokkeerd, check later met 'validate'." >&2
  return 0
}

post() {  # $1=label $2=path $3=body
  echo "POST ${2}  (${1})"
  local code; code="$(curl -sS "${hdr[@]}" -H 'Content-Type: application/json' \
    -X POST --data "${3}" -o "${resp}" -w '%{http_code}' "${API}${2}")"
  echo "  -> HTTP ${code}"
  case "${code}" in 2*) ;; *) jq . "${resp}" 2>/dev/null || cat "${resp}"; return 1 ;; esac
  local tid; tid="$(jq -r '.task_id // empty' "${resp}")"
  # if/then/else zodat poll_task's non-zero (FAILED-task) propageert i.p.v. gemaskeerd door `|| {…}`.
  if [ -n "${tid}" ]; then
    poll_task "${tid}"
  else
    jq . "${resp}"
  fi
}

# ---- apply ----
echo "== validate =="
code="$(curl -sS "${hdr[@]}" -o "${resp}" -w '%{http_code}' "${API}/deployments")"
[ "${code}" = 200 ] || { echo "auth/connectie faalt (HTTP ${code})"; cat "${resp}"; exit 1; }
echo "auth OK — deployments + componenten:"
jq -r '.deployments[]? | "  - \(.name): \([.components[]?.reference] | join(", "))"' "${resp}" 2>/dev/null || true
if [ "${MODE}" = validate ]; then echo "validate OK (read-only, niets gemuteerd)."; exit 0; fi

echo "== upsert deployment '${DEPLOYMENT}' =="
post "deployment" "/:upsert-deployment" "${DEPLOY_BODY}"

if [ -z "${CLONE_FROM}" ]; then
  echo "== componenten aanmaken =="
  post "dirmgr" "/components" "${MANAGER_BODY}"
  post "dirui"  "/components" "${UI_BODY}"
else
  echo "== cloneFrom=${CLONE_FROM}: componenten geërfd =="
fi

echo "Klaar. Nog handmatig (UI): bijlagen (certs op /etc/fsc/...) + Publicatie op het web modus 2 op dirmgr."
echo "Manager-hostnaam: ${MANAGER_HOST}"
