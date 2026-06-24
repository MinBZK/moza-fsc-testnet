#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Genereert een lege CRL getekend door de intermediate (issuer van peer-certs) (#722).
#
# cfssl 1.6.x gencrl-variant: output is base64-gecodeerde DER (geen JSON, geen rauwe bytes).
# Decoded met `base64 -d`, geconverteerd naar PEM via `openssl crl -inform DER`.
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
CA_DIR="${BASE_DIR}/ca"
EMPTY="$(mktemp)"
trap 'rm -f "${EMPTY}"' EXIT

# cfssl gencrl <serials-file> <ca-cert> <ca-key> <expiry-uren> → base64(DER)
# Expiry 43800 uur = 5 jaar (ruim genoeg voor testnet-gebruik).
cfssl gencrl "${EMPTY}" "${CA_DIR}/intermediate.pem" "${CA_DIR}/intermediate-key.pem" 43800 \
  | base64 -d \
  | openssl crl -inform DER -out "${CA_DIR}/intermediate.crl"

echo "OK: intermediate.crl in ${CA_DIR}"
