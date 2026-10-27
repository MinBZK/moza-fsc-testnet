#!/usr/bin/env bash
# Print de OpenFSC-tag uit de `FROM`-regel van een wrapper-Dockerfile. Die regel is de enige plek
# die Dependabot bijhoudt, dus de workflows leiden hun image-tag hieruit af in plaats van een eigen
# default te dragen die bij elke bump mee moet. Zie docs/openfsc-versiebeheer.md.
#
# De uitvoer is strikt `vX.Y.Z`: workflows plakken 'm ongevalideerd in image-referenties en de
# components-JSON van de ZAD-deploy.
set -euo pipefail

file="${1:-}"
[ -n "$file" ] || { echo "Gebruik: $0 <Dockerfile>" >&2; exit 2; }
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  echo "FOUT: $file is geen leesbaar bestand." >&2
  exit 1
fi

# Comments eruit, net als in check-openfsc-version.sh: een uitgecommentarieerde oude FROM mag niet
# als bron gelden. Precies één treffer eisen, anders is "welke van de twee?" een gok.
mapfile -t tags < <(grep -vE '^[[:space:]]*#' "$file" \
  | grep -oE '^FROM[[:space:]]+([a-z0-9.-]+/)?federatedserviceconnectivity/[a-z0-9-]+:v[0-9]+\.[0-9]+\.[0-9]+(@|[[:space:]]|$)' \
  | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true)

[ "${#tags[@]}" -eq 1 ] || {
  echo "FOUT: $file levert ${#tags[@]} OpenFSC-FROM-regel(s), precies 1 verwacht." >&2
  exit 1
}
printf '%s\n' "${tags[0]}"
