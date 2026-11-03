#!/usr/bin/env bash
# Bouwt cfssl, sops en age in <doelmap> voor pki/pki.test.sh, uit broncode op de versies in
# .github/pki-tools/go.mod. Dependabot (gomod) houdt die versies bij en go.sum pint de broncode.
set -euo pipefail

bin="${1:?gebruik: $0 <doelmap>}"
mkdir -p "$bin"
bin=$(cd "$bin" && pwd)
cd "$(dirname "$0")/../pki-tools"

# De lijst staat in tools.go. -e: die importeert programma's, wat go list anders een fout vindt.
mapfile -t tools < <(go list -e -tags tools -f '{{join .Imports "\n"}}' .)
# Zonder cgo: alleen de certdb van cfssl (sqlite) vraagt erom, en die gebruiken we niet.
CGO_ENABLED=0 go build -o "$bin/" "${tools[@]}"
