#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Issued per-endpoint peer-certs uit pki/peers/*/*/csr.json. -f = forceer her-uitgifte.
#
# Twee cert-ketens per endpoint (gegrond op open-fsc `modd.conf`):
#   - GROUP (extern): getekend door de group-intermediate -> pki/out/<peer>/<endpoint>/
#       dekt TLS_GROUP_CERT/KEY + (hergebruikt) TLS_GROUP_TOKEN_* + TLS_GROUP_CONTRACT_*.
#   - INTERNAL: getekend door een PER-PEER internal-CA -> pki/internal/<peer>/<endpoint>/
#       dekt TLS_CERT/KEY + (hergebruikt) TLS_INTERNAL_UNAUTHENTICATED_*. De internal-CA
#       is een eigen self-signed root per peer (spiegelt open-fsc `pki/internal/<org>/ca/`).
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
CONFIG="${BASE_DIR}/config.json"
CA_CERT="${BASE_DIR}/ca/intermediate.pem"
CA_KEY="${BASE_DIR}/ca/intermediate-key.pem"
INTERNAL_CA_SPEC="${BASE_DIR}/internal-ca.json"
# shellcheck source-path=SCRIPTDIR source=lib/anker.sh
. "${BASE_DIR}/lib/anker.sh"

FORCE=0
[ "${1:-}" = "-f" ] && FORCE=1

# 0. Niets uitgeven onder een anker of sleutel die niet aansluit op git.
anker_alles || { echo "issue.sh: niets uitgegeven." >&2; exit 1; }

# 1. Per-peer internal-CA root (self-signed). Eén per peer-map onder pki/peers/.
for PEER_DIR in "${BASE_DIR}"/peers/*/; do
  PEER="$(basename "${PEER_DIR}")"
  ICA_DIR="${BASE_DIR}/internal/${PEER}/ca"
  # Een gecommitte internal-root vertrouwen de draaiende pods: nooit vervangen, ook niet met -f.
  if anker_in_git "internal/${PEER}/ca/root.pem"; then
    echo "skip internal-CA ${PEER} (staat in git)"
    continue
  fi
  if [ -s "${ICA_DIR}/root.pem" ] && [ -s "${ICA_DIR}/root-key.pem" ] && [ "${FORCE}" -eq 0 ]; then
    echo "skip internal-CA ${PEER} (geen -f)"
    continue
  fi
  mkdir -p "${ICA_DIR}"
  echo "internal-CA voor ${PEER}..."
  cfssl genkey -initca "${INTERNAL_CA_SPEC}" | cfssljson -bare "${ICA_DIR}/root"
  rm -f "${ICA_DIR}/root.csr"
  [ -s "${ICA_DIR}/root.pem" ] && [ -s "${ICA_DIR}/root-key.pem" ] \
    || { echo "FAIL: internal-CA ${PEER} onvolledig" >&2; exit 1; }
done

# 2. Per endpoint: group-cert (extern) + internal-cert (per-peer CA). Zelfde csr.json.
find "${BASE_DIR}/peers" -name csr.json -print0 | while IFS= read -r -d '' CSR; do
  REL="$(dirname "${CSR#"${BASE_DIR}/peers/"}")"   # <peer>/<endpoint>
  PEER="${REL%%/*}"
  GROUP_OUT="${BASE_DIR}/out/${REL}"
  INT_OUT="${BASE_DIR}/internal/${REL}"
  ICA_DIR="${BASE_DIR}/internal/${PEER}/ca"

  # GROUP (extern, group-intermediate). Hecht intermediate aan voor de keten.
  # Een cert zonder sleutel is een sleutel die niet is opgehaald, geen reden om opnieuw uit te geven.
  if [ -s "${GROUP_OUT}/cert.pem" ] && [ "${FORCE}" -eq 0 ]; then
    echo "skip group ${REL} (geen -f)"
  else
    [ -s "${CA_KEY}" ] || { echo "FAIL: pki/ca/intermediate-key.pem ontbreekt; pki/geheimen.sh ophalen groep" >&2; exit 1; }
    mkdir -p "${GROUP_OUT}"
    echo "group-cert voor ${REL}..."
    cfssl gencert -config "${CONFIG}" -ca "${CA_CERT}" -ca-key "${CA_KEY}" \
      -profile peer "${CSR}" | cfssljson -bare "${GROUP_OUT}/cert"
    cat "${CA_CERT}" >> "${GROUP_OUT}/cert.pem"          # hecht intermediate aan (keten)
    mv "${GROUP_OUT}/cert-key.pem" "${GROUP_OUT}/key.pem"
    rm -f "${GROUP_OUT}/cert.csr"
    [ -s "${GROUP_OUT}/cert.pem" ] && [ -s "${GROUP_OUT}/key.pem" ] \
      || { echo "FAIL: group-cert ${REL} onvolledig" >&2; exit 1; }
  fi

  # INTERNAL (per-peer internal-CA). Bare leaf; TLS_ROOT_CERT wijst los naar de internal-root.
  if [ -s "${INT_OUT}/cert.pem" ] && [ "${FORCE}" -eq 0 ]; then
    echo "skip internal ${REL} (geen -f)"
  else
    [ -s "${ICA_DIR}/root-key.pem" ] \
      || { echo "FAIL: pki/internal/${PEER}/ca/root-key.pem ontbreekt; pki/geheimen.sh ophalen ${PEER}" >&2; exit 1; }
    mkdir -p "${INT_OUT}"
    echo "internal-cert voor ${REL}..."
    cfssl gencert -config "${CONFIG}" -ca "${ICA_DIR}/root.pem" -ca-key "${ICA_DIR}/root-key.pem" \
      -profile peer "${CSR}" | cfssljson -bare "${INT_OUT}/cert"
    mv "${INT_OUT}/cert-key.pem" "${INT_OUT}/key.pem"
    rm -f "${INT_OUT}/cert.csr"
    [ -s "${INT_OUT}/cert.pem" ] && [ -s "${INT_OUT}/key.pem" ] \
      || { echo "FAIL: internal-cert ${REL} onvolledig" >&2; exit 1; }
  fi
done
echo "OK: group-certs in ${BASE_DIR}/out, internal-certs in ${BASE_DIR}/internal"
