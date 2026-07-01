#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Verzamelt de upload-klare cert-set van één peer in pki/zad-upload/<peer>/ met een MANIFEST:
# per bestand het beoogde pod-pad (/etc/fsc/...) + de TLS_*-env-var(s). Voor het uploaden naar
# ZAD: de losse certs als attachments. "Publicatie op het web" modus 2 (passthrough) heeft GEEN
# combined.pem nodig — de pod serveert de losse TLS_GROUP_CERT/KEY (zie docs/spikes/zad-attachments.md,
# vraag 5). combine-pem.sh blijft een losse optie. Output is gitignored (bevat privésleutels).
# Draai eerst pki/issue.sh.
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
  echo "Hostnames zijn nog placeholder (\`*.fsc-test.local\`). De mesh valideert op OIN; \`directory-ui\`"
  echo "doet wél hostnaam-verificatie, dus de group-cert heeft de ZAD-hostnaam in de SAN (wildcard)."
  echo
  echo "**Attachments** (losse files, elk op hun pod-pad). Modus 2 (passthrough) serveert deze los —"
  echo "geen \`combined.pem\` nodig (zie \`docs/spikes/zad-attachments.md\`, vraag 5):"
  echo
  echo "| Bestand | Beoogd pod-pad / gebruik | TLS_*-env-var(s) |"
  echo "|---------|---------------------------|-------------------|"
} > "${MANIFEST}"

copy_one() {                               # $1 = relatief pad onder pki/  [$2=required -> warn als leeg/weg]
  local rel="$1" src="${BASE_DIR}/$1" dst="${OUT}/$1"
  if [ ! -s "${src}" ]; then
    [ "${2:-}" = required ] && \
      echo "WAARSCHUWING: verplichte cert ontbreekt of is leeg: pki/${rel} — niet in de bundle (draai pki/issue.sh?)." >&2
    return 0
  fi
  mkdir -p "$(dirname "${dst}")"
  cp "${src}" "${dst}"
  printf '| `%s` | `/etc/fsc/%s` | %s |\n' "${rel}" "${rel}" "$(env_for "${rel}")" >> "${MANIFEST}"
}

# 1. group-trust-anchor (gedeeld door alle peers) — verplicht
copy_one "ca/root.pem" required

# 2. group-endpoints: losse cert + key (modus 2 serveert deze los; geen combined.pem)
for d in "${BASE_DIR}/out/${PEER}"/*/; do
  [ -d "${d}" ] || continue
  e="$(basename "${d}")"
  copy_one "out/${PEER}/${e}/cert.pem"
  copy_one "out/${PEER}/${e}/key.pem"
done

# 3. internal-CA root + internal-endpoints (inter-component mTLS)
copy_one "internal/${PEER}/ca/root.pem" required
for d in "${BASE_DIR}/internal/${PEER}"/*/; do
  [ -d "${d}" ] || continue
  e="$(basename "${d}")"
  [ "${e}" = "ca" ] && continue
  copy_one "internal/${PEER}/${e}/cert.pem"
  copy_one "internal/${PEER}/${e}/key.pem"
done

echo "OK: upload-set in ${OUT} (zie MANIFEST.md)."
