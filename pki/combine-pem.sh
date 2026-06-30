#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Bouwt per group-endpoint één PEM met cert + key voor de ZAD "Publicatie op het web"-
# passthrough-upload (modus 2: eigen certificaat op de pod). ZAD wil daar één bestand met
# cert + key; pki/issue.sh levert ze gescheiden. Output: pki/out/<peer>/<endpoint>/combined.pem
# (= leaf + intermediate-chain uit cert.pem, gevolgd door key.pem). Gitignored (bevat de key).
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

made=0
for cert in "${BASE_DIR}"/out/*/*/cert.pem; do
  [ -e "${cert}" ] || { echo "Geen group-certs in ${BASE_DIR}/out (issue.sh gedraaid?)" >&2; exit 1; }
  dir="$(dirname "${cert}")"
  key="${dir}/key.pem"
  rel="${dir#"${BASE_DIR}/out/"}"
  if [ ! -s "${key}" ]; then
    echo "FAIL: key ontbreekt voor ${rel} (${key})" >&2
    exit 1
  fi
  combined="${dir}/combined.pem"
  umask 077                       # 0600: het bestand bevat de privésleutel
  cat "${cert}" "${key}" > "${combined}"
  echo "OK  combined: out/${rel}/combined.pem"
  made=$((made + 1))
done
echo "Klaar: ${made} combined-PEM('s). Upload deze als 'eigen certificaat op de pod' (modus 2)."
