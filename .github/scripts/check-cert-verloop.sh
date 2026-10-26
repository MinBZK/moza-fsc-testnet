#!/usr/bin/env bash
# Meldt gecommitte certificaten en CRL's die binnen [dagen] (standaard 30) verlopen.
# Exit 0 = alles langer geldig, 1 = iets verloopt binnen de termijn of is al verlopen,
# 2 = onleesbaar bestand of verkeerd gebruik.
#
# Alleen wat in git staat telt: ZAD-bijlagen zijn niet terug te lezen, dus git is de plek die
# bijhoudt wat er live staat (zie docs/sleutelbeheer.md). Van een bundel (leaf + keten) telt het
# eerste certificaat; de ketencertificaten staan zelf ook in git en worden apart gecontroleerd.
set -euo pipefail

DAGEN="${1:-30}"
if ! [[ "$DAGEN" =~ ^[0-9]+$ ]]; then
  echo "gebruik: $(basename "$0") [dagen]" >&2
  exit 2
fi
cd "$(dirname "$0")/../.."

TERMIJN=$((DAGEN * 86400))
GRENS=$(( $(date -u +%s) + TERMIJN ))

# OpenSSL-datum ("Jun 28 09:39:00 2041 GMT") naar epoch; BSD-date als terugval voor macOS.
epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%b %e %T %Y %Z' "$1" +%s; }

rc=0
n=0
while IFS= read -r -d '' f; do
  if grep -q -- '-----BEGIN CERTIFICATE-----' "$f"; then
    if ! eind=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null); then
      echo "FOUT       onleesbaar certificaat: $f"; rc=2; continue
    fi
    eind="${eind#notAfter=}"
    if openssl x509 -in "$f" -noout -checkend "$TERMIJN" >/dev/null; then
      echo "OK         ${eind}  $f"
    else
      echo "VERLOOPT   ${eind}  $f"; [ "$rc" -eq 2 ] || rc=1
    fi
  elif grep -q -- '-----BEGIN X509 CRL-----' "$f"; then
    if ! eind=$(openssl crl -in "$f" -noout -nextupdate 2>/dev/null); then
      echo "FOUT       onleesbare CRL: $f"; rc=2; continue
    fi
    eind="${eind#nextUpdate=}"
    if ! t=$(epoch "$eind"); then
      echo "FOUT       onleesbare nextUpdate '${eind}': $f"; rc=2; continue
    fi
    if [ "$t" -gt "$GRENS" ]; then
      echo "OK         ${eind}  $f (nextUpdate)"
    else
      echo "VERLOOPT   ${eind}  $f (nextUpdate)"; [ "$rc" -eq 2 ] || rc=1
    fi
  else
    continue
  fi
  n=$((n + 1))
done < <(git ls-files -z -- '*.pem' '*.crt' '*.crl')

if [ "$n" -eq 0 ] && [ "$rc" -eq 0 ]; then
  echo "geen certificaten of CRL's in git gevonden"
fi
[ "$rc" -eq 1 ] && echo "Verloopt binnen ${DAGEN} dagen: vernieuw volgens docs/sleutelbeheer.md (Certificaten vernieuwen)."
exit "$rc"
