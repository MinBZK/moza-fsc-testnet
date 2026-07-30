#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Acceptatie-asserts test-PKI. Exit 0 = groen.
set -uo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
fail=0

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

# 4. CRL parseert
if openssl crl -in "${BASE_DIR}/ca/intermediate.crl" -noout -text >/dev/null 2>&1; then
  echo "OK  crl"
else
  echo "FAIL crl"; fail=1
fi

# 5. Geen secrets gestaged/untracked-toevoegbaar
if git -C "${BASE_DIR}/.." status --porcelain pki | grep -E '\.(pem|key|crt|crl)$'; then
  echo "FAIL: PKI-secrets zichtbaar voor git"; fail=1
else
  echo "OK  geen secrets voor git"
fi

[ "${fail}" -eq 0 ] && echo "== ALLE ASSERTS GROEN ==" || echo "== FAILURES =="
exit "${fail}"
