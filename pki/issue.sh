#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Issued per-endpoint peer-certs uit pki/peers/*/*/csr.json (#722). -f = forceer her-uitgifte.
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

FORCE=0
[ "${1:-}" = "-f" ] && FORCE=1

# 1. Per-peer internal-CA root (self-signed). Eén per peer-map onder pki/peers/.
for PEER_DIR in "${BASE_DIR}"/peers/*/; do
  PEER="$(basename "${PEER_DIR}")"
  ICA_DIR="${BASE_DIR}/internal/${PEER}/ca"
  if [ -f "${ICA_DIR}/root.pem" ] && [ "${FORCE}" -eq 0 ]; then
    echo "skip internal-CA ${PEER} (geen -f)"
    continue
  fi
  mkdir -p "${ICA_DIR}"
  echo "internal-CA voor ${PEER}..."
  cfssl genkey -initca "${INTERNAL_CA_SPEC}" | cfssljson -bare "${ICA_DIR}/root"
  rm -f "${ICA_DIR}/root.csr"
done

# 2. Per endpoint: group-cert (extern) + internal-cert (per-peer CA). Zelfde csr.json.
find "${BASE_DIR}/peers" -name csr.json -print0 | while IFS= read -r -d '' CSR; do
  REL="$(dirname "${CSR#"${BASE_DIR}/peers/"}")"   # <peer>/<endpoint>
  PEER="${REL%%/*}"
  GROUP_OUT="${BASE_DIR}/out/${REL}"
  INT_OUT="${BASE_DIR}/internal/${REL}"
  ICA_DIR="${BASE_DIR}/internal/${PEER}/ca"

  # GROUP (extern, group-intermediate). Hecht intermediate aan voor de keten.
  if [ -f "${GROUP_OUT}/cert.pem" ] && [ "${FORCE}" -eq 0 ]; then
    echo "skip group ${REL} (geen -f)"
  else
    mkdir -p "${GROUP_OUT}"
    echo "group-cert voor ${REL}..."
    cfssl gencert -config "${CONFIG}" -ca "${CA_CERT}" -ca-key "${CA_KEY}" \
      -profile peer "${CSR}" | cfssljson -bare "${GROUP_OUT}/cert"
    cat "${CA_CERT}" >> "${GROUP_OUT}/cert.pem"          # hecht intermediate aan (keten)
    mv "${GROUP_OUT}/cert-key.pem" "${GROUP_OUT}/key.pem"
    rm -f "${GROUP_OUT}/cert.csr"
  fi

  # INTERNAL (per-peer internal-CA). Bare leaf; TLS_ROOT_CERT wijst los naar de internal-root.
  if [ -f "${INT_OUT}/cert.pem" ] && [ "${FORCE}" -eq 0 ]; then
    echo "skip internal ${REL} (geen -f)"
  else
    mkdir -p "${INT_OUT}"
    echo "internal-cert voor ${REL}..."
    cfssl gencert -config "${CONFIG}" -ca "${ICA_DIR}/root.pem" -ca-key "${ICA_DIR}/root-key.pem" \
      -profile peer "${CSR}" | cfssljson -bare "${INT_OUT}/cert"
    mv "${INT_OUT}/cert-key.pem" "${INT_OUT}/key.pem"
    rm -f "${INT_OUT}/cert.csr"
  fi
done
echo "OK: group-certs in ${BASE_DIR}/out, internal-certs in ${BASE_DIR}/internal"
