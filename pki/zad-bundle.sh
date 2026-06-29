#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Verzamelt de upload-klare cert-set van één peer in pki/zad-upload/<peer>/ met een MANIFEST:
# per bestand het beoogde pod-pad (/etc/fsc/...) + de TLS_*-env-var(s). Voor het uploaden naar
# ZAD: de losse certs als attachments, de combined.pem voor "Publicatie op het web" modus 2
# (passthrough). Output is gitignored (bevat privésleutels). Draai eerst pki/issue.sh.
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PEER="${1:?usage: zad-bundle.sh <peer> (bv. directory)}"
OUT="${BASE_DIR}/zad-upload/${PEER}"
MANIFEST="${OUT}/MANIFEST.md"

[ -d "${BASE_DIR}/out/${PEER}" ] || { echo "Geen group-certs voor '${PEER}' (pki/issue.sh gedraaid?)" >&2; exit 1; }

# TLS_*-env-var(s) per relatief pad-patroon (spiegelt peers/directory/manager.env.example).
env_for() {
  case "$1" in
    ca/root.pem)            echo "TLS_GROUP_ROOT_CERT" ;;
    out/*/cert.pem)         echo "TLS_GROUP_CERT (+ TLS_GROUP_TOKEN_CERT, TLS_GROUP_CONTRACT_CERT)" ;;
    out/*/key.pem)          echo "TLS_GROUP_KEY (+ TLS_GROUP_TOKEN_KEY, TLS_GROUP_CONTRACT_KEY)" ;;
    internal/*/ca/root.pem) echo "TLS_ROOT_CERT (+ TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT)" ;;
    internal/*/cert.pem)    echo "TLS_CERT (+ TLS_INTERNAL_UNAUTHENTICATED_CERT)" ;;
    internal/*/key.pem)     echo "TLS_KEY (+ TLS_INTERNAL_UNAUTHENTICATED_KEY)" ;;
    *)                      echo "?" ;;
  esac
}

umask 077                                  # 0600: bevat privésleutels
rm -rf "${OUT}"; mkdir -p "${OUT}"

{
  echo "# ZAD-upload-set voor peer \`${PEER}\`"
  echo
  echo "Gegenereerd door \`pki/zad-bundle.sh\`. **Bevat privésleutels — niet committen, niet delen.**"
  echo "Hostnames zijn nog placeholder (\`*.fsc-test.local\`); de mesh valideert op OIN, niet op"
  echo "hostnaam (zie \`docs/spikes/zad-attachments.md\`, vraag 7, of de ZAD-hostnaam in de SAN moet)."
  echo
  echo "**Attachments** (losse files, op hun pod-pad) + **Publicatie op het web modus 2** (combined.pem):"
  echo
  echo "| Bestand | Beoogd pod-pad / gebruik | TLS_*-env-var(s) |"
  echo "|---------|---------------------------|-------------------|"
} > "${MANIFEST}"

copy_one() {                               # $1 = relatief pad onder pki/
  local rel="$1" src="${BASE_DIR}/$1" dst="${OUT}/$1"
  [ -s "${src}" ] || return 0
  mkdir -p "$(dirname "${dst}")"
  cp "${src}" "${dst}"
  printf '| `%s` | `/etc/fsc/%s` | %s |\n' "${rel}" "${rel}" "$(env_for "${rel}")" >> "${MANIFEST}"
}

# 1. group-trust-anchor (gedeeld door alle peers)
copy_one "ca/root.pem"

# 2. group-endpoints: cert, key + combined (cert+key) voor de passthrough-upload
for d in "${BASE_DIR}/out/${PEER}"/*/; do
  [ -d "${d}" ] || continue
  e="$(basename "${d}")"
  copy_one "out/${PEER}/${e}/cert.pem"
  copy_one "out/${PEER}/${e}/key.pem"
  if [ -s "${d}/cert.pem" ] && [ -s "${d}/key.pem" ]; then
    mkdir -p "${OUT}/out/${PEER}/${e}"
    cat "${d}/cert.pem" "${d}/key.pem" > "${OUT}/out/${PEER}/${e}/combined.pem"
    printf '| `out/%s/%s/combined.pem` | Publicatie op het web, modus 2 (passthrough) | — (cert+key in één PEM) |\n' \
      "${PEER}" "${e}" >> "${MANIFEST}"
  fi
done

# 3. internal-CA root + internal-endpoints (inter-component mTLS)
copy_one "internal/${PEER}/ca/root.pem"
for d in "${BASE_DIR}/internal/${PEER}"/*/; do
  [ -d "${d}" ] || continue
  e="$(basename "${d}")"
  [ "${e}" = "ca" ] && continue
  copy_one "internal/${PEER}/${e}/cert.pem"
  copy_one "internal/${PEER}/${e}/key.pem"
done

echo "OK: upload-set in ${OUT} (zie MANIFEST.md)."
