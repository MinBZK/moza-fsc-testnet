#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Regressietest voor wegwerp-pki.sh. De wegwerp-PKI moet de harness een complete set geven, en mag
# pki/ van de checkout nooit raken: daar staan de certs van de live federatie. Vereist cfssl,
# cfssljson en openssl.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/deploy/local/wegwerp-pki.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fails=0
cases=0
check() {  # $1 = omschrijving, rest = commando dat moet slagen
  local desc="$1"; shift
  cases=$((cases + 1))
  if "$@" >/dev/null 2>&1; then echo "ok    ${desc}"; else echo "FAAL  ${desc}"; fails=$((fails + 1)); fi
}
faalt() { ! "$@"; }

# Ook genegeerde bestanden: de sleutels van wie wél toegang heeft, staan daar.
pki_staat() { (cd "$REPO_ROOT" && find pki -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
voor=$(pki_staat)

# Een ontwikkelaar kan globaal commit-signing of hooks aan hebben; de wegwerp-repo mag daar niet op
# stuklopen of om een wachtwoord vragen.
mkdir -p "$TMP_ROOT/hooks"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/hooks/pre-commit"; chmod +x "$TMP_ROOT/hooks/pre-commit"
printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n[core]\n\thooksPath = %s\n' \
  "$TMP_ROOT/hooks" > "$TMP_ROOT/gitconfig"

W="$TMP_ROOT/wegwerp"
check "bouwt een PKI in een lege map buiten de checkout, ook met signing en hooks in de git-config" \
  env GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig" "$SCRIPT" "$W"
check "verify.sh van de wegwerp-PKI is groen" "$W/pki/verify.sh"
for k in out/directory/directory/key.pem internal/directory/directory/key.pem \
         out/example-provider/manager/key.pem internal/example-provider/inway/key.pem \
         out/example-consumer/outway/key.pem internal/example-consumer/ca/root-key.pem; do
  check "sleutel voor de stack: ${k}" test -s "$W/pki/${k}"
done
if [ -f "$REPO_ROOT/pki/ca/root.pem" ]; then
  check "eigen anker, niet dat van het testnet" faalt cmp -s "$W/pki/ca/root.pem" "$REPO_ROOT/pki/ca/root.pem"
fi
check "pki/ van de checkout is onaangeroerd" test "$voor" = "$(pki_staat)"

check "weigert een niet-lege doelmap" faalt "$SCRIPT" "$W"
binnen="$REPO_ROOT/deploy/local/.wegwerp-test-$$"
check "weigert een doelmap binnen de checkout" faalt "$SCRIPT" "$binnen"
check "laat binnen de checkout niets achter" test ! -e "$binnen"
check "weigert een geneste doelmap binnen de checkout" faalt "$SCRIPT" "$binnen/dieper"
check "laat bij een geneste doelmap niets achter" test ! -e "$binnen"

echo "${cases} cases, ${fails} gefaald"
[ "$fails" -eq 0 ]
