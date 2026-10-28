#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Bouwt een wegwerp-PKI voor de lokale harness in <doelmap>: een eigen root, intermediate en certs
# voor elke peer onder pki/peers, met de scripts uit deze checkout. Voor wie geen toegang heeft tot
# de geheime repo; run-smokes.sh --wegwerp-ca wijst PKI_DIR naar <doelmap>/pki.
#
# pki/ van de checkout blijft onaangeroerd: daar staan de certs van de live federatie. <doelmap> is
# een eigen git-repo met het nieuwe anker gecommit, zodat de ankercontrole er gewoon werkt.
#
#   deploy/local/wegwerp-pki.sh <lege doelmap buiten de checkout>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
doel="${1:?gebruik: $0 <lege doelmap buiten de checkout>}"

binnen_checkout() {
  case "$1/" in "${REPO_ROOT}/"*) echo "FAIL: $1 ligt binnen de checkout; kies een map erbuiten (bv. mktemp -d)." >&2; exit 1 ;; esac
}
# Eerst de bovenliggende map: binnen de checkout mag niets worden aangemaakt, ook geen tussenmap.
ouder="$(dirname "${doel}")"
[ -d "${ouder}" ] || { echo "FAIL: ${ouder} bestaat niet." >&2; exit 1; }
binnen_checkout "$(cd "${ouder}" && pwd -P)"
mkdir -p "${doel}"
doel="$(cd "${doel}" && pwd -P)"
binnen_checkout "${doel}"
[ -z "$(ls -A "${doel}")" ] || { echo "FAIL: ${doel} is niet leeg." >&2; exit 1; }

# Gevolgde scripts, configs en CSR-templates uit de werkboom, zonder het materiaal van de federatie.
(cd "${REPO_ROOT}" && git ls-files -z -- .gitignore pki ':!pki/ca' ':!pki/out' ':!pki/internal' \
  | tar --null -T - -cf -) | tar -xf - -C "${doel}"

cd "${doel}"
# Signing en hooks uit de globale git-config horen niet bij deze wegwerp-repo.
g() {
  git -c user.name=wegwerp-pki -c user.email=wegwerp-pki@localhost -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null "$@"
}
g init -q
g add -A && g commit -qm "tooling"
./pki/init-ca.sh
./pki/gen-crl.sh
g add pki/ca/root.pem pki/ca/intermediate.pem pki/ca/intermediate.crl && g commit -qm "anker"
./pki/issue.sh
./pki/fix-permissions.sh
./pki/verify.sh
