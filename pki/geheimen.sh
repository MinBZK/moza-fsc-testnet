#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Haalt de privésleutels van de test-PKI op uit de geheime repo, of slaat ze daar versleuteld op
# (SOPS + age, één bestand per sleutel). Wie wat kan ontsleutelen staat in pki/.sops.yaml, in déze
# repo: daar loopt een wijziging via een gereviewde PR. Runbook: docs/sleutelbeheer.md.
set -euo pipefail
umask 077

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
GEHEIMEN_DIR="${FSC_GEHEIMEN_DIR:-${BASE_DIR}/../../moza-fsc-testnet-geheimen}"
SOPS_CONFIG="${BASE_DIR}/.sops.yaml"
FORCE=0
SETS=()
TMP=""
trap '[ -z "${TMP}" ] || rm -rf "${TMP}"' EXIT

gebruik() {
  cat >&2 <<'EOF'
gebruik: pki/geheimen.sh <actie> [-f] [groep|root|<peer>…]

  ophalen     ontsleutel naar pki/ en draai verify.sh
  opslaan     versleutel gewijzigde sleutels naar de geheime repo; weigert als verify.sh rood is
  wis         verwijder lokale sleutels en afgeleide bestanden; weigert bij een niet-opgeslagen sleutel
  ontvangers  versleutel opnieuw voor de ontvangers in pki/.sops.yaml

Zonder sets: groep en alle peers; de root-sleutel alleen als je 'root' noemt (wis: alles).
-f: ophalen overschrijft een afwijkende lokale sleutel, wis verwijdert ook wat niet opgeslagen is.
De geheime repo: FSC_GEHEIMEN_DIR, standaard ../moza-fsc-testnet-geheimen naast deze repo.
EOF
  exit 2
}

fout() { echo "FAIL: $*" >&2; exit 1; }

# Lokaal sleutelpad (onder pki/) naar het pad in de geheime repo.
geheim_pad() {
  local p e
  case "$1" in
    ca/intermediate-key.pem)    echo "groep/intermediate-key.pem" ;;
    ca/root-key.pem)            echo "groep/root/root-key.pem" ;;
    out/*/*/key.pem)            p="${1#out/}"; e="${p#*/}"; echo "${p%%/*}/group/${e%/key.pem}-key.pem" ;;
    internal/*/ca/root-key.pem) p="${1#internal/}"; echo "${p%%/*}/internal/ca-key.pem" ;;
    internal/*/*/key.pem)       p="${1#internal/}"; e="${p#*/}"; echo "${p%%/*}/internal/${e%/key.pem}-key.pem" ;;
    *) return 1 ;;
  esac
}

alle_peers() {
  local d
  for d in "${BASE_DIR}"/out/*/ "${BASE_DIR}"/internal/*/; do
    [ -d "${d}" ] && basename "${d}"
  done | sort -u
}

# Sleutels van een set, afgeleid van de certificaten in git: een sleutel zonder cert is niets waard.
sleutels() {
  local c
  case "$1" in
    groep) echo "ca/intermediate-key.pem" ;;
    root)  echo "ca/root-key.pem" ;;
    *)
      for c in "${BASE_DIR}/out/$1"/*/cert.pem "${BASE_DIR}/internal/$1"/*/cert.pem; do
        [ -e "${c}" ] && { c="${c#"${BASE_DIR}/"}"; echo "${c%cert.pem}key.pem"; }
      done
      [ -e "${BASE_DIR}/internal/$1/ca/root.pem" ] && echo "internal/$1/ca/root-key.pem"
      ;;
  esac
  return 0
}

# Sleutels die lokaal staan, ook zonder cert: wis moet alles kunnen opruimen.
lokale_sleutels() {
  local f
  case "$1" in
    groep) f="${BASE_DIR}/ca/intermediate-key.pem"; [ -e "${f}" ] && echo "ca/intermediate-key.pem" ;;
    root)  f="${BASE_DIR}/ca/root-key.pem"; [ -e "${f}" ] && echo "ca/root-key.pem" ;;
    *)
      for f in "${BASE_DIR}/out/$1"/*/key.pem "${BASE_DIR}/internal/$1"/*/key.pem \
               "${BASE_DIR}/internal/$1/ca/root-key.pem"; do
        [ -e "${f}" ] && echo "${f#"${BASE_DIR}/"}"
      done
      ;;
  esac
  return 0
}

ontsleutel() { sops decrypt --input-type binary --output-type binary "$1" 2>/dev/null; }

# $1 = lokaal bestand, $2 = pad in de geheime repo. sops legt path_regex op het absolute pad, dus
# een regel moet als (^|/)groep/root/ geschreven zijn; controleer_root_regel bewaakt dat.
versleutel() {
  (cd "${GEHEIMEN_DIR}" && sops --config "${SOPS_CONFIG}" encrypt \
     --input-type binary --output-type binary --filename-override "$2" "$1")
}

# $1 = pad in de geheime repo; print de age-ontvangers die pki/.sops.yaml daarvoor kiest.
ontvangers_voor() {
  (cd "${GEHEIMEN_DIR}" && printf x | sops --config "${SOPS_CONFIG}" encrypt \
     --input-type binary --output-type binary --filename-override "$1") \
    | grep -o '"recipient": *"[^"]*"' | sort -u
}

# De eerste passende regel wint. Een root-regel die niet matcht, of een regel erboven die alles matcht
# (.* of zonder path_regex), zou de root-sleutel stil voor elke dagelijkse ontvanger versleutelen. De
# ontvangers vergelijken ziet dat niet zodra elke ontvanger ook root-houder is. Zonder YAML-parser eisen
# we daarom de vorm uit docs/sleutelbeheer.md: het eerste item onder creation_rules is de root-regel.
# Elke andere schrijfwijze wordt geweigerd.
controleer_root_regel() {
  local eerste r
  eerste="$(awk '/^creation_rules:[[:space:]]*(#.*)?$/ { binnen = 1; next }
                 binnen && !/^[[:space:]]*(#.*)?$/ { print; exit }' "${SOPS_CONFIG}")"
  grep -qE "^[[:space:]]*-[[:space:]]+path_regex:[[:space:]]*['\"]?[(]\^[|]/[)]groep/root/['\"]?[[:space:]]*(#.*)?$" \
      <<<"${eerste}" \
    || fout "het eerste item onder creation_rules in pki/.sops.yaml moet '- path_regex: (^|/)groep/root/' zijn, anders krijgt de root-sleutel stil de dagelijkse ontvangers (docs/sleutelbeheer.md)."
  r="$(ontvangers_voor groep/root/root-key.pem)" || fout "kan de ontvangers uit pki/.sops.yaml niet bepalen."
  [ -n "${r}" ] || fout "de root-regel in pki/.sops.yaml heeft geen ontvangers."
}

heeft_root() { local s; for s in "${SETS[@]}"; do [ "${s}" = root ] && return 0; done; return 1; }

# Waar als de geheime repo precies deze lokale sleutel bevat.
opgeslagen() {  # $1 = lokaal pad onder pki/
  local s
  s="${GEHEIMEN_DIR}/$(geheim_pad "$1")"
  [ -f "${s}" ] && cmp -s "${BASE_DIR}/$1" <(ontsleutel "${s}")
}

vereis_geheimen_dir() {
  [ -d "${GEHEIMEN_DIR}" ] \
    || fout "geheime repo niet gevonden in ${GEHEIMEN_DIR}. Clone MinBZK/moza-fsc-testnet-geheimen daar, of zet FSC_GEHEIMEN_DIR."
  GEHEIMEN_DIR="$(cd "${GEHEIMEN_DIR}" && pwd)"
}

vereis_config() {
  [ -f "${SOPS_CONFIG}" ] || fout "pki/.sops.yaml ontbreekt: zonder ontvangers kan er niets versleuteld worden."
}

# Vult SETS aan met de standaard en controleert de namen. $1 = bekende peers, $2 = 'met-root' voor wis.
bepaal_sets() {
  local peers="$1" s
  if [ "${#SETS[@]}" -eq 0 ]; then
    SETS=(groep)
    [ "${2:-}" = met-root ] && SETS+=(root)
    # shellcheck disable=SC2206  # peernamen zijn mapnamen zonder spaties
    SETS+=(${peers})
  fi
  for s in "${SETS[@]}"; do
    case "${s}" in
      groep|root) ;;
      *) grep -qxF -- "${s}" <<<"${peers}" || fout "onbekende set '${s}': kies groep, root of een peer ($(echo "${peers}" | tr '\n' ' '))" ;;
    esac
  done
}

ophalen() {
  local s k g n=0 probleem=0
  local -a lokaal=() tijdelijk=()
  vereis_geheimen_dir
  bepaal_sets "$(alle_peers)"
  TMP="$(mktemp -d)"
  # Eerst alles ontsleutelen en controleren, dan pas schrijven: geen half opgehaalde set.
  for s in "${SETS[@]}"; do
    while IFS= read -r k; do
      g="$(geheim_pad "${k}")"
      if [ ! -f "${GEHEIMEN_DIR}/${g}" ]; then
        echo "FAIL: ${g} ontbreekt in de geheime repo (voor pki/${k})" >&2; probleem=1; continue
      fi
      n=$((n + 1))
      if ! ontsleutel "${GEHEIMEN_DIR}/${g}" > "${TMP}/${n}"; then
        echo "FAIL: kan ${g} niet ontsleutelen; staat jouw age-sleutel in pki/.sops.yaml?" >&2; probleem=1; continue
      fi
      if [ -e "${BASE_DIR}/${k}" ] && ! cmp -s "${BASE_DIR}/${k}" "${TMP}/${n}" && [ "${FORCE}" -eq 0 ]; then
        echo "FAIL: pki/${k} wijkt af van de geheime repo. Eerst opslaan, of -f om te overschrijven." >&2
        probleem=1; continue
      fi
      lokaal+=("${k}"); tijdelijk+=("${TMP}/${n}")
    done < <(sleutels "${s}")
  done
  [ "${probleem}" -eq 0 ] || fout "niets opgehaald."
  # Lengte eerst: op bash 3.2 (macOS) faalt "${a[@]}" van een lege array onder set -u.
  [ "${#lokaal[@]}" -gt 0 ] || { echo "geen sleutels om op te halen"; return 0; }
  for n in "${!lokaal[@]}"; do
    k="${lokaal[${n}]}"
    mkdir -p "${BASE_DIR}/$(dirname "${k}")"
    chmod 700 "${BASE_DIR}/$(dirname "${k}")"
    mv "${tijdelijk[${n}]}" "${BASE_DIR}/${k}"
    chmod 600 "${BASE_DIR}/${k}"
    echo "opgehaald pki/${k}"
  done
  if ! "${BASE_DIR}/verify.sh"; then
    echo "Past een sleutel niet bij zijn cert: is de geheime repo bijgewerkt (git pull in ${GEHEIMEN_DIR})," >&2
    echo "en wacht er nog een PR met nieuwe certs op merge?" >&2
    return 1
  fi
}

opslaan() {
  local s k g n=0 rc=0
  vereis_geheimen_dir
  vereis_config
  bepaal_sets "$(alle_peers)"
  if heeft_root; then controleer_root_regel; fi
  if ! uit="$("${BASE_DIR}/verify.sh" 2>&1)"; then
    grep -E '^FAIL' <<<"${uit}" >&2 || true
    fout "verify.sh is rood; niets opgeslagen. Een sleutel die niet bij zijn cert past, hoort niet in de geheime repo."
  fi
  for s in "${SETS[@]}"; do
    while IFS= read -r k; do
      [ -e "${BASE_DIR}/${k}" ] || { echo "overgeslagen pki/${k} (niet lokaal)"; continue; }
      g="$(geheim_pad "${k}")"
      if [ -f "${GEHEIMEN_DIR}/${g}" ]; then
        if ! ontsleutel "${GEHEIMEN_DIR}/${g}" >/dev/null; then
          echo "FAIL: kan ${g} niet ontsleutelen om te vergelijken; niet overschreven." >&2; rc=1; continue
        fi
        if opgeslagen "${k}"; then echo "ongewijzigd ${g}"; continue; fi
      fi
      mkdir -p "${GEHEIMEN_DIR}/$(dirname "${g}")"
      versleutel "${BASE_DIR}/${k}" "${g}" > "${GEHEIMEN_DIR}/${g}.nieuw"
      mv "${GEHEIMEN_DIR}/${g}.nieuw" "${GEHEIMEN_DIR}/${g}"
      echo "opgeslagen ${g}"; n=$((n + 1))
    done < <(sleutels "${s}")
  done
  [ "${n}" -eq 0 ] || echo "Commit en push in de geheime repo: git -C ${GEHEIMEN_DIR} add -A && git -C ${GEHEIMEN_DIR} commit"
  return "${rc}"
}

wis() {
  local s k probleem=0
  local -a weg=()
  bepaal_sets "$(alle_peers)" met-root
  if [ "${FORCE}" -eq 0 ]; then vereis_geheimen_dir; fi
  for s in "${SETS[@]}"; do
    while IFS= read -r k; do
      if [ "${FORCE}" -eq 0 ] && ! opgeslagen "${k}"; then
        echo "FAIL: pki/${k} staat niet (zo) in de geheime repo, of je kunt dat niet nakijken. Eerst opslaan, of -f." >&2
        probleem=1
      fi
      weg+=("${BASE_DIR}/${k}")
    done < <(lokale_sleutels "${s}")
    case "${s}" in
      groep|root) ;;
      *) weg+=("${BASE_DIR}/out/${s}"/*/combined.pem "${BASE_DIR}/zad-upload/${s}") ;;
    esac
  done
  [ "${probleem}" -eq 0 ] || fout "niets gewist."
  [ "${#weg[@]}" -eq 0 ] || rm -rf "${weg[@]}"
  rmdir "${BASE_DIR}/zad-upload" 2>/dev/null || true
  echo "Lokale sleutels en afgeleide bestanden gewist."
}

# Alle peers in de geheime repo, ook die van andere repo's: intrekken moet ook hun bestanden raken.
geheime_peers() {
  local d
  for d in "${GEHEIMEN_DIR}"/*/; do
    [ -d "${d}" ] || continue
    d="$(basename "${d}")"
    [ "${d}" = groep ] || echo "${d}"
  done
}

ontvangers() {
  local s g rc=0
  vereis_geheimen_dir
  vereis_config
  bepaal_sets "$(geheime_peers)"
  if heeft_root; then controleer_root_regel; fi
  for s in "${SETS[@]}"; do
    case "${s}" in
      groep) set -- "${GEHEIMEN_DIR}"/groep/*-key.pem ;;
      root)  set -- "${GEHEIMEN_DIR}"/groep/root/*-key.pem ;;
      *)     set -- "${GEHEIMEN_DIR}/${s}"/*/*-key.pem ;;
    esac
    for g in "$@"; do
      [ -f "${g}" ] || continue
      g="${g#"${GEHEIMEN_DIR}/"}"
      if (cd "${GEHEIMEN_DIR}" && sops --config "${SOPS_CONFIG}" updatekeys --yes --input-type binary "${g}" >/dev/null 2>&1); then
        echo "bijgewerkt ${g}"
      else
        echo "FAIL: ontvangers van ${g} niet bijgewerkt (ontsleutelen gelukt?)" >&2; rc=1
      fi
    done
  done
  return "${rc}"
}

ACTIE="${1:-}"
[ "$#" -gt 0 ] && shift
for a in "$@"; do
  case "${a}" in
    -f) FORCE=1 ;;
    -*) gebruik ;;
    *)  SETS+=("${a}") ;;
  esac
done
command -v sops >/dev/null || fout "sops niet gevonden; zie docs/sleutelbeheer.md."

case "${ACTIE}" in
  ophalen|opslaan|wis|ontvangers) "${ACTIE}" ;;
  *) gebruik ;;
esac
