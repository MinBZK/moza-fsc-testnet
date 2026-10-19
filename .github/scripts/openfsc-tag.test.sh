#!/usr/bin/env bash
# Regressietest voor openfsc-tag.sh. De build- en deploy-workflows taggen en deployen op wat dit
# script print, dus een stil verkeerde tag publiceert een image onder de verkeerde versie.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/openfsc-tag.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
fails=0
cases=0

# $1=omschrijving $2=verwachte exitcode $3=verwachte uitvoer ('' = geen eis) $4=Dockerfile
expect() {
  local desc="$1" want="$2" out_want="$3" file="$4" got=0 out
  cases=$((cases + 1))
  out=$("$SCRIPT" "$file" 2>/dev/null) || got=$?
  if [ "$got" -ne "$want" ]; then
    printf 'FAAL  %s: verwacht exit %s, kreeg %s\n' "$desc" "$want" "$got" >&2
    fails=$((fails + 1))
  elif [ -n "$out_want" ] && [ "$out" != "$out_want" ]; then
    printf 'FAAL  %s: verwacht "%s", kreeg "%s"\n' "$desc" "$out_want" "$out" >&2
    fails=$((fails + 1))
  else
    printf 'ok    %s (exit %s)\n' "$desc" "$got"
  fi
}

# Schrijft een Dockerfile met de gegeven regels en echoot het pad.
dockerfile() {
  local f; f="$TMP_ROOT/Dockerfile-$cases-$RANDOM"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

echo "Regressietest openfsc-tag.sh"

# --- 1. De echte wrappers: elke tag is leesbaar ------------------------------------------------
mapfile -t WRAPPERS < <(find "$REPO_ROOT/deploy/zad" -name Dockerfile | sort)
[ "${#WRAPPERS[@]}" -ge 3 ] || {
  echo "FAAL  opzet: ${#WRAPPERS[@]} wrapper-Dockerfile(s), minimaal 3 verwacht" >&2; exit 1; }
for wrapper in "${WRAPPERS[@]}"; do
  expect "echte wrapper ${wrapper#"$REPO_ROOT"/}" 0 "" "$wrapper"
done

# --- 2. Vorm van de FROM-regel -----------------------------------------------------------------
# De busybox-donor staat er in elke wrapper boven; die mag nooit de tag leveren.
expect "busybox-donor plus OpenFSC-FROM" 0 v1.2.3 "$(dockerfile \
  "FROM busybox:1.38.0-musl@$DIGEST AS busybox" \
  "FROM docker.io/federatedserviceconnectivity/manager:v1.2.3@$DIGEST")"
expect "zonder registry-prefix en digest" 0 v1.2.3 "$(dockerfile \
  "FROM federatedserviceconnectivity/manager:v1.2.3")"

# --- 3. Wat geen bron mag zijn -----------------------------------------------------------------
expect "uitgecommentarieerde FROM telt niet" 0 v1.2.3 "$(dockerfile \
  "# FROM docker.io/federatedserviceconnectivity/manager:v0.0.1@$DIGEST" \
  "FROM docker.io/federatedserviceconnectivity/manager:v1.2.3@$DIGEST")"
expect "alleen een comment" 1 "" "$(dockerfile \
  "# FROM docker.io/federatedserviceconnectivity/manager:v1.2.3@$DIGEST")"
expect "twee OpenFSC-FROM-regels" 1 "" "$(dockerfile \
  "FROM docker.io/federatedserviceconnectivity/manager:v1.2.3@$DIGEST" \
  "FROM docker.io/federatedserviceconnectivity/inway:v1.2.4@$DIGEST")"
expect "tag zonder v-prefix" 1 "" "$(dockerfile \
  "FROM docker.io/federatedserviceconnectivity/manager:1.2.3@$DIGEST")"
expect "tag met suffix" 1 "" "$(dockerfile \
  "FROM docker.io/federatedserviceconnectivity/manager:v1.2.3-rc1@$DIGEST")"
expect "leeg bestand" 1 "" "$(dockerfile "")"
expect "bestand bestaat niet" 1 "" "$TMP_ROOT/bestaat-niet"

echo
if [ "$fails" -ne 0 ]; then
  echo "REGRESSIETEST ROOD: $fails case(s) gefaald." >&2
  exit 1
fi
echo "Regressietest groen: alle $cases cases."
