#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Acceptatie-asserts test-PKI. Exit 0 = groen.
set -uo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
# shellcheck source-path=SCRIPTDIR source=lib/anker.sh
. "${BASE_DIR}/lib/anker.sh"
fail=0

# 0. Anker: lokaal materiaal sluit aan op het vertrouwensanker in git
if anker_alles; then echo "OK  anker"; else fail=1; fi

# 1. Ketengeldigheid per group-leaf
for cert in "${BASE_DIR}"/out/*/*/cert.pem; do
  [ -e "${cert}" ] || { echo "FAIL group-certs ontbreken (issue.sh gedraaid?)"; fail=1; break; }
  if openssl verify -CAfile "${BASE_DIR}/ca/root.pem" \
       -untrusted "${BASE_DIR}/ca/intermediate.pem" "${cert}" >/dev/null 2>&1; then
    echo "OK  keten: ${cert#"${BASE_DIR}/"}"
  else
    echo "FAIL keten: ${cert#"${BASE_DIR}/"}"; fail=1
  fi
done

# 2. serialNumber (OIN) aanwezig in subject — group én internal (zelfde csr.json)
for cert in "${BASE_DIR}"/out/*/*/cert.pem "${BASE_DIR}"/internal/*/*/cert.pem; do
  [ -e "${cert}" ] || continue
  if openssl x509 -in "${cert}" -noout -subject -nameopt sep_multiline | grep -q 'serialNumber'; then
    echo "OK  OIN:   ${cert#"${BASE_DIR}/"}"
  else
    echo "FAIL OIN ontbreekt: ${cert#"${BASE_DIR}/"}"; fail=1
  fi
done

# 3. Internal-keten: elke internal-leaf valideert tegen de internal-CA van zíjn peer
for cert in "${BASE_DIR}"/internal/*/*/cert.pem; do
  [ -e "${cert}" ] || { echo "FAIL internal-certs ontbreken"; fail=1; break; }
  peer="$(basename "$(dirname "$(dirname "${cert}")")")"
  root="${BASE_DIR}/internal/${peer}/ca/root.pem"
  if openssl verify -CAfile "${root}" "${cert}" >/dev/null 2>&1; then
    echo "OK  internal: ${cert#"${BASE_DIR}/"}"
  else
    echo "FAIL internal-keten: ${cert#"${BASE_DIR}/"}"; fail=1
  fi
done

# 3b. ISOLATIE: internal-leaf mag NIET tegen de group-trust-anchor valideren,
#     en peer-A's leaf NIET tegen peer-B's internal-root. Slagen = boundary lek = FAIL.
for cert in "${BASE_DIR}"/internal/*/*/cert.pem; do
  [ -e "${cert}" ] || break
  rel="${cert#"${BASE_DIR}/internal/"}"
  peer="$(basename "$(dirname "$(dirname "${cert}")")")"
  if openssl verify -CAfile "${BASE_DIR}/ca/root.pem" \
       -untrusted "${BASE_DIR}/ca/intermediate.pem" "${cert}" >/dev/null 2>&1; then
    echo "FAIL isolatie: internal-leaf accepteert group-anchor: ${rel}"; fail=1
  fi
  for other_root in "${BASE_DIR}"/internal/*/ca/root.pem; do
    other_peer="$(basename "$(dirname "$(dirname "${other_root}")")")"
    [ "${other_peer}" = "${peer}" ] && continue
    if openssl verify -CAfile "${other_root}" "${cert}" >/dev/null 2>&1; then
      echo "FAIL isolatie: ${peer}-leaf accepteert ${other_peer}-internal-root: ${rel}"; fail=1
    fi
  done
done
[ "${fail}" -eq 0 ] && echo "OK  isolatie group<->internal + cross-peer"

# 3c. PARITEIT: elk group-endpoint heeft een internal-tegenhanger (en omgekeerd)
for g in "${BASE_DIR}"/out/*/*/cert.pem; do
  [ -e "${g}" ] || break
  rel="${g#"${BASE_DIR}/out/"}"
  [ -f "${BASE_DIR}/internal/${rel}" ] || { echo "FAIL pariteit: geen internal-cert voor ${rel%/cert.pem}"; fail=1; }
done

# 3d. Elke lokale leaf-sleutel hoort bij zijn certificaat (CA-sleutels: zie stap 0)
for key in "${BASE_DIR}"/out/*/*/key.pem "${BASE_DIR}"/internal/*/*/key.pem; do
  [ -e "${key}" ] || continue
  if anker_sleutel_past "${key}" "$(dirname "${key}")/cert.pem"; then
    echo "OK  sleutel: ${key#"${BASE_DIR}/"}"
  else
    echo "FAIL sleutel past niet bij cert.pem: ${key#"${BASE_DIR}/"}"; fail=1
  fi
done

# 4. CRL parseert
if openssl crl -in "${BASE_DIR}/ca/intermediate.crl" -noout -text >/dev/null 2>&1; then
  echo "OK  crl"
else
  echo "FAIL crl"; fail=1
fi

# 5. Geen sleutels in git: niets onder pki/ in HEAD, de index of toevoegbaar mag een privésleutel
#    zijn. Op inhoud zoals git die opslaat (een hernoemde kopie valt zo ook op), en op naam voor
#    sleutelcontainers zonder PEM-kop.
REPO="${BASE_DIR}/.."
PEM_SLEUTEL='-----BEGIN [A-Z ]*PRIVATE KEY-----'
lek=0
while IFS= read -r -d '' f; do
  echo "FAIL: privésleutel in git: ${f}"; lek=1
done < <(git -C "${REPO}" grep -z -l -e "${PEM_SLEUTEL}" --cached -- pki; \
         git -C "${REPO}" grep -z -l -e "${PEM_SLEUTEL}" HEAD -- pki 2>/dev/null)
while IFS= read -r -d '' f; do
  if grep -q -e "${PEM_SLEUTEL}" "${REPO}/${f}" 2>/dev/null; then
    echo "FAIL: privésleutel toevoegbaar voor git: ${f}"; lek=1
  fi
done < <(git -C "${REPO}" ls-files -z --others --exclude-standard -- pki)
while IFS= read -r -d '' f; do
  if [[ "${f}" =~ (key\.pem|combined\.pem|\.key|\.p12|\.pfx|\.pk8)$|^pki/zad-upload/ ]]; then
    echo "FAIL: sleutelbestand zichtbaar voor git: ${f}"; lek=1
  fi
done < <(git -C "${REPO}" ls-files -z --cached --others --exclude-standard -- pki)
if [ "${lek}" -eq 0 ]; then echo "OK  geen sleutels voor git"; else fail=1; fi

[ "${fail}" -eq 0 ] && echo "== ALLE ASSERTS GROEN ==" || echo "== FAILURES =="
exit "${fail}"
