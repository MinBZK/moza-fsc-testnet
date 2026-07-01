#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Ruimt een ZAD-deployment op (#729) via de v2 Operations Manager API: DELETE .../{deployment}.
# Eén bron voor CLI + de workflow zad-cleanup.yml. Generiek: werkt voor de directory én voor
# peer-projecten (parametriseer ZAD_PROJECT + de deployment-naam). Zie docs/zad-cleanup.md en
# [[zad-deploy-api-model]]; spiegelt de idiomen van deploy/zad/upsert-directory.sh.
#
# Model: PR = eigen deployment; main -> deployment `test`. Cleanup verwijdert een HÉLE deployment
# (de v2-API kent geen losse component-delete). Beschermde namen (test/main/production) vereisen
# ALLOW_PROTECTED=1 — het cluster is odcn-PRODUCTION, dus geen per-ongeluk-teardown van de gedeelde
# singleton. Idempotent: een niet-bestaande deployment = no-op (geen fout).
#
# Usage:
#   export ZAD_API_KEY=...                            # niet inline (echo't anders)
#   ./deploy/zad/cleanup.sh validate                  # read-only auth-check + lijst deployments
#   ./deploy/zad/cleanup.sh plan   <deployment>       # toont wat verwijderd wordt, muteert NIET
#   ./deploy/zad/cleanup.sh apply  <deployment>       # DELETE + pollt de task
# Env: ZAD_API_KEY (verplicht), ZAD_PROJECT (mft-tp9), ZAD_BASE (zad.rijksapp.nl), ALLOW_PROTECTED.
set -euo pipefail

MODE="${1:?usage: cleanup.sh <validate|plan|apply> [deployment]}"
DEPLOYMENT="${2:-}"
PROJECT="${ZAD_PROJECT:-mft-tp9}"
BASE="${ZAD_BASE:-https://zad.rijksapp.nl}"
ALLOW_PROTECTED="${ALLOW_PROTECTED:-0}"

case "${MODE}" in validate|plan|apply) ;; *) echo "mode = validate | plan | apply"; exit 1 ;; esac
if [ "${MODE}" != validate ]; then
  case "${DEPLOYMENT}" in
    "")            echo "deployment-naam vereist voor '${MODE}'"; exit 1 ;;
    *[!a-z0-9-]*)  echo "ongeldige deployment: '${DEPLOYMENT}' (alleen a-z0-9-)"; exit 1 ;;
  esac
  # Beschermde deployments niet per ongeluk slopen (prod-cluster, gedeelde singleton).
  case "${DEPLOYMENT}" in
    test|main|master|production|prod)
      [ "${ALLOW_PROTECTED}" = 1 ] \
        || { echo "GEWEIGERD: '${DEPLOYMENT}' is beschermd; zet ALLOW_PROTECTED=1 om te forceren." >&2; exit 1; } ;;
  esac
fi
: "${ZAD_API_KEY:?zet ZAD_API_KEY in je env}"

API="${BASE}/api/v2/projects/${PROJECT}"
resp="$(mktemp)"; trap 'rm -f "${resp}"' EXIT
hdr=(-H "X-API-Key: ${ZAD_API_KEY}")

poll_task() {  # $1=task_id  (mutaties zijn async — spiegelt upsert-directory.sh)
  local id="$1" status
  for _ in $(seq 1 45); do
    curl -sS "${hdr[@]}" "${BASE}/api/tasks/${id}" -o "${resp}"
    status="$(jq -r '.status' "${resp}")"
    case "${status}" in
      completed) echo "  task ${id}: completed"; return 0 ;;
      failed)    echo "  task ${id}: FAILED -> $(jq -r '.error_message // .result.error' "${resp}")"; return 1 ;;
      *)         sleep 2 ;;
    esac
  done
  echo "  task ${id}: nog bezig na ~90s (async ArgoCD-sync) — niet geblokkeerd, check later met 'validate'."
  return 0
}

# --- validate: auth + lijst bestaande deployments ---------------------------------------------
echo "== validate =="
code="$(curl -sS "${hdr[@]}" -o "${resp}" -w '%{http_code}' "${API}/deployments")"
[ "${code}" = 200 ] || { echo "auth/connectie faalt (HTTP ${code})"; cat "${resp}"; exit 1; }
echo "auth OK — bestaande deployments in ${PROJECT}:"
jq -r '.deployments[]? | "  - \(.name)"' "${resp}" 2>/dev/null || true
if [ "${MODE}" = validate ]; then echo "validate OK (read-only, niets gemuteerd)."; exit 0; fi

# Idempotent: bestaat de deployment niet (meer), dan is er niets op te ruimen.
if ! jq -e --arg d "${DEPLOYMENT}" '.deployments[]? | select(.name==$d)' "${resp}" >/dev/null 2>&1; then
  echo "deployment '${DEPLOYMENT}' bestaat niet in ${PROJECT} — niets te doen (idempotent)."
  exit 0
fi

if [ "${MODE}" = plan ]; then
  echo "### zou verwijderen (DELETE): ${API}/${DEPLOYMENT}"
  echo "(plan — niets gemuteerd)"; exit 0
fi

# --- apply: DELETE deployment + poll --------------------------------------------------------
echo "== deployment '${DEPLOYMENT}' verwijderen =="
code="$(curl -sS "${hdr[@]}" -X DELETE -o "${resp}" -w '%{http_code}' "${API}/${DEPLOYMENT}")"
echo "  -> HTTP ${code}"
case "${code}" in
  2*)  ;;
  404) echo "  al weg (404) — idempotent."; exit 0 ;;
  *)   jq . "${resp}" 2>/dev/null || cat "${resp}"; exit 1 ;;
esac
tid="$(jq -r '.task_id // empty' "${resp}")"
if [ -n "${tid}" ]; then poll_task "${tid}"; else jq . "${resp}" 2>/dev/null || true; fi
echo "Klaar. '${DEPLOYMENT}' opgeruimd uit ${PROJECT}."
