#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Upsert de directory op ZAD via de v2 Operations Manager API (#723). Eén bron voor zowel de
# CLI (jij, met de key in je env) als de workflow zad-deploy-directory.yml.
#
# Dekt alleen wat de deploy-API kan: deployment + component-referenties + images + domain_format.
# NIET via de API (UI-only, zie docs/zad-directory-deploy.md): bijlagen (cert-mount), env-vars,
# "Publicatie op het web" (passthrough-TLS).
#
# Model: een PR krijgt een eigen deployment; wat naar main gaat landt in `test`.
#
# Usage:
#   export ZAD_API_KEY=...              # niet inline (echo't anders)
#   ./deploy/zad/upsert-directory.sh validate            # read-only auth/connectie-check
#   ./deploy/zad/upsert-directory.sh apply [deployment] [image_tag]
# Env: ZAD_API_KEY (verplicht), ZAD_PROJECT (default mft-tp9), ZAD_BASE (default zad.rijksapp.nl).
set -euo pipefail

MODE="${1:?usage: upsert-directory.sh <validate|apply> [deployment=test] [image_tag=v1.43.7]}"
DEPLOYMENT="${2:-test}"
IMAGE_TAG="${3:-v1.43.7}"
PROJECT="${ZAD_PROJECT:-mft-tp9}"
BASE="${ZAD_BASE:-https://zad.rijksapp.nl}"
: "${ZAD_API_KEY:?zet ZAD_API_KEY in je env}"

case "${MODE}" in validate|apply) ;; *) echo "mode = validate of apply"; exit 1 ;; esac
case "${DEPLOYMENT}" in ""|*[!a-z0-9-]*) echo "ongeldige deployment: '${DEPLOYMENT}'"; exit 1 ;; esac
case "${IMAGE_TAG}" in ""|*[!A-Za-z0-9._-]*) echo "ongeldige image_tag: '${IMAGE_TAG}'"; exit 1 ;; esac

resp="$(mktemp)"; body="$(mktemp)"; trap 'rm -f "${resp}" "${body}"' EXIT

# 1. Validate (altijd): read-only GET — bewijst auth + connectie zonder te muteren.
code="$(curl -sS -o "${resp}" -w '%{http_code}' \
  -H "X-API-Key: ${ZAD_API_KEY}" \
  "${BASE}/api/v2/projects/${PROJECT}/deployments")"
echo "GET /deployments -> HTTP ${code}"
[ "${code}" = "200" ] || { echo "Auth/connectie faalt:"; cat "${resp}"; exit 1; }
jq . "${resp}" 2>/dev/null || cat "${resp}"
[ "${MODE}" = "validate" ] && { echo "validate OK"; exit 0; }

# 2. Apply: upsert het deployment met de 3 directory-componenten + voorspelbare hostnaam.
cat > "${body}" <<JSON
{
  "deploymentName": "${DEPLOYMENT}",
  "domain_format": "component-deployment-project",
  "components": [
    {"reference": "directory-postgres", "image": "postgres:17"},
    {"reference": "directory-manager", "image": "ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:${IMAGE_TAG}"},
    {"reference": "directory-ui", "image": "docker.io/federatedserviceconnectivity/directory-ui:${IMAGE_TAG}"}
  ]
}
JSON
echo "Upsert body (deployment '${DEPLOYMENT}'):"; jq . "${body}"
code="$(curl -sS -o "${resp}" -w '%{http_code}' -X POST \
  -H "X-API-Key: ${ZAD_API_KEY}" -H "Content-Type: application/json" \
  --data @"${body}" \
  "${BASE}/api/v2/projects/${PROJECT}/:upsert-deployment")"
echo "POST /:upsert-deployment -> HTTP ${code}"
jq . "${resp}" 2>/dev/null || cat "${resp}"
case "${code}" in 2*) echo "OK — upsert geaccepteerd (volg de task/UI).";; *) echo "FAIL"; exit 1;; esac
