#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Issued per-endpoint peer-certs uit pki/peers/*/*/csr.json (#722). -f = forceer her-uitgifte.
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
CONFIG="${BASE_DIR}/config.json"
CA_CERT="${BASE_DIR}/ca/intermediate.pem"
CA_KEY="${BASE_DIR}/ca/intermediate-key.pem"

FORCE=0
[ "${1:-}" = "-f" ] && FORCE=1

find "${BASE_DIR}/peers" -name csr.json -print0 | while IFS= read -r -d '' CSR; do
  REL="$(dirname "${CSR#"${BASE_DIR}/peers/"}")"   # <peer>/<endpoint>
  OUT_DIR="${BASE_DIR}/out/${REL}"

  if [ -f "${OUT_DIR}/cert.pem" ] && [ "${FORCE}" -eq 0 ]; then
    echo "skip ${REL} (geen -f)"
    continue
  fi

  mkdir -p "${OUT_DIR}"
  echo "cert voor ${REL}..."
  cfssl gencert -config "${CONFIG}" -ca "${CA_CERT}" -ca-key "${CA_KEY}" \
    -profile peer "${CSR}" | cfssljson -bare "${OUT_DIR}/cert"

  cat "${CA_CERT}" >> "${OUT_DIR}/cert.pem"          # hecht intermediate aan (keten)
  mv "${OUT_DIR}/cert-key.pem" "${OUT_DIR}/key.pem"
  rm -f "${OUT_DIR}/cert.csr"
done
echo "OK: certs in ${BASE_DIR}/out"
