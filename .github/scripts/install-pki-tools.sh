#!/usr/bin/env bash
# Installeert cfssl, sops en age, gepind op versie en sha256, in <doelmap> voor pki/pki.test.sh.
#
# Staat hier en niet in lint.yml: check-openfsc-version.sh weigert elke versie-literal in een workflow.
# Dependabot ziet deze downloads niet: versie en sha256 met de hand bijwerken (cfssl en sops publiceren
# checksums bij de release, voor age is de hash bij het pinnen berekend).
set -euo pipefail

bin="${1:?gebruik: $0 <doelmap>}"
mkdir -p "$bin"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

haal() { curl -fsSL --retry 3 -o "$2" "$1" && echo "$3  $2" | sha256sum -c -; }
haal https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssl_1.6.5_linux_amd64 cfssl \
  ff4d3a1387ea3e1ee74f4bb8e5ffe9cbab5bee43c710333c206d14199543ebdf
haal https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssljson_1.6.5_linux_amd64 cfssljson \
  09fbcb7a3b3d6394936ea61eabff1e8a59a8ac3b528deeb14cf66cdbbe9a534f
haal https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64 sops \
  e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
haal https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-linux-amd64.tar.gz age.tar.gz \
  cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
tar -xzf age.tar.gz age/age age/age-keygen
install -m 755 cfssl cfssljson sops age/age age/age-keygen "$bin/"
