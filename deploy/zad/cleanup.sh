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
# NB: anders dan upsert-directory.sh's offline `plan`, checkt `plan`/`apply` hier de live-staat
# (bestaat de deployment?) -> ook `plan` vereist de API-key.
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

poll_task() {  # $1=task_id ; return 0=completed, 1=failed/onverwacht, 2=niet-bevestigd (timeout)
  local id="$1" status code
  for _ in $(seq 1 45); do
    # HTTP-code hard checken (zoals de rest van dit script): een 5xx/401-errorbody mag niet als
    # `null`-status de false-pending-lus in vallen en de destructieve delete "geslaagd" laten lijken.
    code="$(curl -sS "${hdr[@]}" -o "${resp}" -w '%{http_code}' "${BASE}/api/tasks/${id}")"
    case "${code}" in 2*) ;; *) echo "  task ${id}: poll HTTP ${code}"; jq . "${resp}" 2>/dev/null || cat "${resp}"; return 1 ;; esac
    status="$(jq -r '.status // empty' "${resp}" 2>/dev/null || true)"
    case "${status}" in
      completed) echo "  task ${id}: completed"; return 0 ;;
      failed)    echo "  task ${id}: FAILED -> $(jq -r '.error_message // .result.error // "?"' "${resp}")"; return 1 ;;
      pending|running|in_progress|queued|"") sleep 2 ;;   # alléén BEKENDE non-terminale statussen retryen
      *)         echo "  task ${id}: onverwachte status '${status}':"; jq . "${resp}" 2>/dev/null || cat "${resp}"; return 1 ;;
    esac
  done
  echo "  task ${id}: niet 'completed' binnen ~90s (async ArgoCD-sync)." >&2
  return 2
}

# --- validate: auth + lijst bestaande deployments ---------------------------------------------
echo "== validate =="
code="$(curl -sS "${hdr[@]}" -o "${resp}" -w '%{http_code}' "${API}/deployments")"
[ "${code}" = 200 ] || { echo "auth/connectie faalt (HTTP ${code})"; cat "${resp}"; exit 1; }
echo "auth OK — bestaande deployments in ${PROJECT}:"
jq -r '.deployments[]? | "  - \(.name)"' "${resp}" || true   # geen 2>/dev/null: laat shape-drift zien
if [ "${MODE}" = validate ]; then echo "validate OK (read-only, niets gemuteerd)."; exit 0; fi

# Body MOET geldige JSON zijn: anders een corrupte 200-body niet als "deployment weg" interpreteren
# (dat zou een nog-levende deployment op prod stil laten lekken + valse "niets te doen" melden).
jq -e . "${resp}" >/dev/null 2>&1 \
  || { echo "onverwachte /deployments-body (geen geldige JSON) — afbreken i.p.v. 'niets te doen':" >&2; cat "${resp}" >&2; exit 1; }
# Idempotent: bestaat de deployment niet (meer), dan is er niets op te ruimen. Geen 2>/dev/null
# op de select -> een echte jq-fout maskeert nooit als "bestaat niet".
if ! jq -e --arg d "${DEPLOYMENT}" '.deployments[]? | select(.name==$d)' "${resp}" >/dev/null; then
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
if [ -z "${tid}" ]; then
  # 2xx zonder task_id: geaccepteerd maar niet-async-bevestigbaar -> niet als "opgeruimd" claimen.
  echo "DELETE geaccepteerd (HTTP ${code}) zonder task_id; verifieer met 'validate'."
  jq . "${resp}" 2>/dev/null || true
  exit 0
fi
if poll_task "${tid}"; then
  echo "Klaar. '${DEPLOYMENT}' opgeruimd uit ${PROJECT}."
else
  echo "cleanup NIET bevestigd — task ${tid} niet 'completed'. Verifieer met 'validate'." >&2
  exit 2
fi
