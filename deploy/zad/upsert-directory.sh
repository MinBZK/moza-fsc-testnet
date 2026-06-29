#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Zet de directory op ZAD via de v2 Operations Manager API (#723). Eén bron voor CLI + de
# workflow zad-deploy-directory.yml. Zie docs/zad-directory-deploy.md en [[zad-deploy-api-model]].
#
# Model: PR = eigen deployment; main -> deployment `test`. `:upsert-deployment` REFEREERT alleen
# bestaande componenten; componenten maak je met POST /components (incl. env_vars + port).
# Previews kunnen `cloneFrom` een bestaande deployment (erven componenten, alleen images zetten).
# NIET via de API (UI-only): bijlagen (cert-mount) + "Publicatie op het web" (passthrough-TLS).
#
# Usage:
#   export ZAD_API_KEY=...                          # niet inline (echo't anders)
#   ./deploy/zad/upsert-directory.sh validate                       # read-only auth-check
#   ./deploy/zad/upsert-directory.sh plan   [deployment] [tag] [clone_from]   # toont bodies, muteert niet
#   ./deploy/zad/upsert-directory.sh apply  [deployment] [tag] [clone_from]   # muteert + pollt tasks
# Env: ZAD_API_KEY (verplicht), ZAD_PROJECT (mft-tp9), ZAD_BASE (zad.rijksapp.nl),
#      ZAD_BASE_DOMAIN (rig.prd1.gn2.quattro.rijksapps.nl), ZAD_PG_PASSWORD (test-wachtwoord).
set -euo pipefail

MODE="${1:?usage: upsert-directory.sh <validate|plan|apply> [deployment=test] [tag=v1.43.7] [clone_from]}"
DEPLOYMENT="${2:-test}"
IMAGE_TAG="${3:-v1.43.7}"
CLONE_FROM="${4:-}"
PROJECT="${ZAD_PROJECT:-mft-tp9}"
BASE="${ZAD_BASE:-https://zad.rijksapp.nl}"
BASE_DOMAIN="${ZAD_BASE_DOMAIN:-rig.prd1.gn2.quattro.rijksapps.nl}"
PG_PASSWORD="${ZAD_PG_PASSWORD:-fsc-test-pw}"          # test-env; geen echte data

case "${MODE}" in validate|plan|apply) ;; *) echo "mode = validate | plan | apply"; exit 1 ;; esac
case "${DEPLOYMENT}" in ""|*[!a-z0-9-]*) echo "ongeldige deployment: '${DEPLOYMENT}'"; exit 1 ;; esac
case "${IMAGE_TAG}" in ""|*[!A-Za-z0-9._-]*) echo "ongeldige image_tag: '${IMAGE_TAG}'"; exit 1 ;; esac
case "${CLONE_FROM}" in *[!a-z0-9-]*) echo "ongeldige clone_from: '${CLONE_FROM}'"; exit 1 ;; esac
[ "${MODE}" = apply ] && : "${ZAD_API_KEY:?zet ZAD_API_KEY in je env}"

MANAGER_IMAGE="ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:${IMAGE_TAG}"
UI_IMAGE="docker.io/federatedserviceconnectivity/directory-ui:${IMAGE_TAG}"
MANAGER_HOST="directory-manager-${DEPLOYMENT}-${PROJECT}.${BASE_DOMAIN}"
DSN="postgres://fsc:${PG_PASSWORD}@directory-postgres:5432/fsc_directory?sslmode=disable"

# --- env-blobs (KEY=value, newline-sep). TLS_*-paden = de bijlage-mounts (UI, ontwerp A). ---
PG_ENV="$(printf '%s\n' \
  "POSTGRES_DB=fsc_directory" \
  "POSTGRES_USER=fsc" \
  "POSTGRES_PASSWORD=${PG_PASSWORD}")"

MANAGER_ENV="$(printf '%s\n' \
  "LOG_TYPE=live" "LOG_LEVEL=info" "AUDITLOG_TYPE=stdout" \
  "GROUP_ID=moza-fbs-test" \
  "DIRECTORY_PEER_ID=00000000000000000010" \
  "SELF_ADDRESS=https://${MANAGER_HOST}:443" \
  "DIRECTORY_MANAGER_ADDRESS=https://${MANAGER_HOST}:443" \
  "TX_LOG_API_ADDRESS=" \
  "AUTO_SIGN_GRANTS=servicePublication,delegatedServicePublication" \
  "LISTEN_ADDRESS_EXTERNAL=0.0.0.0:8443" \
  "LISTEN_ADDRESS_INTERNAL=0.0.0.0:9443" \
  "LISTEN_ADDRESS_INTERNAL_UNAUTHENTICATED=0.0.0.0:9444" \
  "MONITORING_ADDRESS=0.0.0.0:8080" \
  "STORAGE_POSTGRES_DSN=${DSN}" \
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

UI_ENV="$(printf '%s\n' \
  "LOG_TYPE=live" "LOG_LEVEL=info" \
  "LISTEN_ADDRESS=0.0.0.0:8080" \
  "MONITORING_ADDRESS=0.0.0.0:8081" \
  "DIRECTORY_MANAGER_ADDRESS=https://${MANAGER_HOST}:443" \
  "BASE_URL_PATH=/" \
  "TLS_GROUP_ROOT_CERT=/etc/fsc/ca/root.pem" \
  "TLS_GROUP_CERT=/etc/fsc/out/directory/directory/cert.pem" \
  "TLS_GROUP_KEY=/etc/fsc/out/directory/directory/key.pem")"

# component-body (AddComponentRequest) via jq -> correcte JSON-escaping.
component_body() {  # $1=name $2=image $3=port $4=env_blob
  jq -n --arg name "$1" --arg image "$2" --argjson port "$3" --arg env "$4" --arg dep "${DEPLOYMENT}" \
    '{name:$name, image:$image, port:$port, env_vars:$env, deployment_names:[$dep]}'
}

DEPLOY_BODY="$(jq -n --arg d "${DEPLOYMENT}" --arg cf "${CLONE_FROM}" \
  '{deploymentName:$d, domain_format:"component-deployment-project", components:[]}
   + (if $cf=="" then {} else {cloneFrom:$cf, forceClone:true} end)')"

PG_BODY="$(component_body directory-postgres "postgres:17" 5432 "${PG_ENV}")"
MANAGER_BODY="$(component_body directory-manager "${MANAGER_IMAGE}" 8443 "${MANAGER_ENV}")"
UI_BODY="$(component_body directory-ui "${UI_IMAGE}" 8080 "${UI_ENV}")"

# ---- plan: toon alleen ----
if [ "${MODE}" = plan ]; then
  echo "### deployment (:upsert-deployment)"; echo "${DEPLOY_BODY}"
  if [ -z "${CLONE_FROM}" ]; then
    echo "### component directory-postgres";  echo "${PG_BODY}"
    echo "### component directory-manager";   echo "${MANAGER_BODY}"
    echo "### component directory-ui";        echo "${UI_BODY}"
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
  for i in $(seq 1 30); do
    curl -sS "${hdr[@]}" "${BASE}/api/tasks/${id}" -o "${resp}"
    status="$(jq -r '.status' "${resp}")"
    case "${status}" in
      completed) echo "  task ${id}: completed"; return 0 ;;
      failed)    echo "  task ${id}: FAILED -> $(jq -r '.error_message // .result.error' "${resp}")"; return 1 ;;
      *)         sleep 2 ;;
    esac
  done
  echo "  task ${id}: timeout (laatste status ${status})"; return 1
}

post() {  # $1=label $2=path $3=body
  echo "POST ${2}  (${1})"
  local code; code="$(curl -sS "${hdr[@]}" -H 'Content-Type: application/json' \
    -X POST --data "${3}" -o "${resp}" -w '%{http_code}' "${API}${2}")"
  echo "  -> HTTP ${code}"
  case "${code}" in 2*) ;; *) jq . "${resp}" 2>/dev/null || cat "${resp}"; return 1 ;; esac
  local tid; tid="$(jq -r '.task_id // empty' "${resp}")"
  [ -n "${tid}" ] && poll_task "${tid}" || { jq . "${resp}"; }
}

# ---- apply ----
echo "== validate =="
code="$(curl -sS "${hdr[@]}" -o "${resp}" -w '%{http_code}' "${API}/deployments")"
[ "${code}" = 200 ] || { echo "auth/connectie faalt (HTTP ${code})"; cat "${resp}"; exit 1; }
echo "auth OK"

echo "== upsert deployment '${DEPLOYMENT}' =="
post "deployment" "/:upsert-deployment" "${DEPLOY_BODY}"

if [ -z "${CLONE_FROM}" ]; then
  echo "== componenten aanmaken =="
  post "directory-postgres" "/components" "${PG_BODY}"
  post "directory-manager"  "/components" "${MANAGER_BODY}"
  post "directory-ui"       "/components" "${UI_BODY}"
else
  echo "== cloneFrom=${CLONE_FROM}: componenten geërfd =="
fi

echo "Klaar. Nog handmatig (UI): bijlagen (certs op /etc/fsc/...) + Publicatie op het web modus 2 op directory-manager."
echo "Manager-hostnaam: ${MANAGER_HOST}"
