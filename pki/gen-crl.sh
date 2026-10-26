#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Genereert een lege CRL getekend door de intermediate (issuer van peer-certs).
#
# cfssl 1.6.x gencrl-variant: output is base64-gecodeerde DER (geen JSON, geen rauwe bytes).
# Decoded met `base64 -d`, geconverteerd naar PEM via `openssl crl -inform DER`.
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
CA_DIR="${BASE_DIR}/ca"
EMPTY="$(mktemp)"
trap 'rm -f "${EMPTY}"' EXIT

# cfssl gencrl <serials-file> <ca-cert> <ca-key> <geldigheid-in-seconden> → base64(DER)
# 5 jaar. Let op de eenheid: seconden, geen uren. De verloopcontrole meldt een naderende nextUpdate.
cfssl gencrl "${EMPTY}" "${CA_DIR}/intermediate.pem" "${CA_DIR}/intermediate-key.pem" $((5 * 365 * 24 * 3600)) \
  | base64 -d \
  | openssl crl -inform DER -out "${CA_DIR}/intermediate.crl"

echo "OK: intermediate.crl in ${CA_DIR}"
