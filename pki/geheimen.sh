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

Zonder sets: groep en alle peers; de root-sleutel alleen als je 'root' noemt (wis: alles). Bij ophalen
alleen de peers die in de geheime repo staan: een ander team beheert zijn sleutels zelf.
-f: ophalen overschrijft een afwijkende lokale sleutel, opslaan ook een sleutel die niet bij het cert
in je checkout past, wis verwijdert ook wat niet opgeslagen is.
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

# Lokaal sleutelpad naar het cert dat erbij hoort.
cert_bij() {
  case "$1" in
    ca/intermediate-key.pem)    echo "ca/intermediate.pem" ;;
    ca/root-key.pem)            echo "ca/root.pem" ;;
    internal/*/ca/root-key.pem) echo "${1%root-key.pem}root.pem" ;;
    *)                          echo "${1%key.pem}cert.pem" ;;
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

# Zoals opgeslagen, maar ook gecommit: een bestand dat alleen in de werkboom van de geheime repo staat,
# gaat verloren bij een checkout, stash of nieuwe clone.
gecommit_opgeslagen() {  # $1 = lokaal pad onder pki/
  local g
  g="$(geheim_pad "$1")"
  opgeslagen "$1" \
    && git -C "${GEHEIMEN_DIR}" ls-files --error-unmatch -- "${g}" >/dev/null 2>&1 \
    && git -C "${GEHEIMEN_DIR}" diff --quiet HEAD -- "${g}" 2>/dev/null
}

# Waar als de sleutel in de geheime repo bij het cert in HEAD van deze checkout past, of als HEAD dat
# cert niet heeft. Past hij niet, dan heeft iemand anders vernieuwd en is deze checkout verouderd.
past_bij_head() {  # $1 = lokaal pad onder pki/, $2 = ontsleutelde sleutel
  local c
  c="$(cert_bij "$1")"
  git -C "${BASE_DIR}" cat-file -e "HEAD:./${c}" 2>/dev/null || return 0
  [ "$(git -C "${BASE_DIR}" show "HEAD:./${c}" | openssl x509 -noout -pubkey 2>/dev/null)" \
    = "$(openssl pkey -in "$2" -pubout 2>/dev/null)" ]
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
  # Zonder sets alleen de peers met sleutels in de geheime repo. Een peer van een ander team heeft
  # zijn certs wel in git, maar beheert zijn sleutels zelf.
  if [ "${#SETS[@]}" -eq 0 ]; then
    SETS=(groep)
    while IFS= read -r s; do SETS+=("${s}"); done < <(comm -12 <(alle_peers) <(geheime_peers | sort))
    # Ook een vergeten push of een verouderde geheime repo ziet er zo uit: meld het dus.
    while IFS= read -r s; do
      echo "overgeslagen ${s}: geen sleutels in de geheime repo (eigen sleutels van een ander team, of git pull in ${GEHEIMEN_DIR}?)"
    done < <(comm -23 <(alle_peers) <(geheime_peers | sort))
  fi
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
        echo "FAIL: pki/${k} wijkt af van de geheime repo. Zelf net vernieuwd: eerst opslaan. Anders is je checkout verouderd: git pull in deze repo. -f overschrijft je lokale sleutel." >&2
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
  local s k g rc=0
  local -a nieuw=()
  vereis_geheimen_dir
  vereis_config
  bepaal_sets "$(alle_peers)"
  if heeft_root; then controleer_root_regel; fi
  if ! uit="$("${BASE_DIR}/verify.sh" 2>&1)"; then
    grep -E '^FAIL' <<<"${uit}" >&2 || true
    fout "verify.sh is rood; niets opgeslagen. Een sleutel die niet bij zijn cert past, hoort niet in de geheime repo."
  fi
  TMP="$(mktemp -d)"
  for s in "${SETS[@]}"; do
    while IFS= read -r k; do
      [ -e "${BASE_DIR}/${k}" ] || { echo "overgeslagen pki/${k} (niet lokaal)"; continue; }
      g="$(geheim_pad "${k}")"
      if [ -f "${GEHEIMEN_DIR}/${g}" ]; then
        if ! ontsleutel "${GEHEIMEN_DIR}/${g}" > "${TMP}/bestaand"; then
          echo "FAIL: kan ${g} niet ontsleutelen om te vergelijken; niet overschreven." >&2; rc=1; continue
        fi
        if cmp -s "${BASE_DIR}/${k}" "${TMP}/bestaand"; then echo "ongewijzigd ${g}"; continue; fi
        if [ "${FORCE}" -eq 0 ] && ! past_bij_head "${k}" "${TMP}/bestaand"; then
          echo "FAIL: ${g} in de geheime repo past niet bij pki/$(cert_bij "${k}") in je checkout: iemand anders heeft vernieuwd, of je checkout is verouderd. git pull in deze repo en ophalen; -f overschrijft toch." >&2
          rc=1; continue
        fi
      fi
      mkdir -p "${GEHEIMEN_DIR}/$(dirname "${g}")"
      versleutel "${BASE_DIR}/${k}" "${g}" > "${GEHEIMEN_DIR}/${g}.nieuw"
      mv "${GEHEIMEN_DIR}/${g}.nieuw" "${GEHEIMEN_DIR}/${g}"
      echo "opgeslagen ${g}"; nieuw+=("${g}")
    done < <(sleutels "${s}")
  done
  # Lengte eerst: op bash 3.2 (macOS) faalt "${a[@]}" van een lege array onder set -u.
  if [ "${#nieuw[@]}" -gt 0 ]; then
    echo "Commit in de geheime repo; push pas na de merge van de PR met de certs:"
    echo "  git -C ${GEHEIMEN_DIR} add ${nieuw[*]} && git -C ${GEHEIMEN_DIR} commit"
  fi
  return "${rc}"
}

wis() {
  local s k probleem=0
  local -a weg=()
  bepaal_sets "$(alle_peers)" met-root
  if [ "${FORCE}" -eq 0 ]; then vereis_geheimen_dir; fi
  for s in "${SETS[@]}"; do
    while IFS= read -r k; do
      if [ "${FORCE}" -eq 0 ] && ! gecommit_opgeslagen "${k}"; then
        echo "FAIL: pki/${k} staat niet (zo) gecommit in de geheime repo, of je kunt dat niet nakijken. Eerst opslaan en committen, of -f." >&2
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
  if [ "${FORCE}" -eq 0 ]; then
    local voor
    voor="$(git -C "${GEHEIMEN_DIR}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    [ "${voor}" -eq 0 ] \
      || echo "Let op: ${voor} commit(s) in de geheime repo zijn nog niet gepusht; tot dan staan de sleutels alleen hier."
  fi
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
# wis -f ontsleutelt niets: ook wie geen sops heeft, kan na een eigen lokale CA opruimen.
if [ "${ACTIE}" != wis ] || [ "${FORCE}" -eq 0 ]; then
  command -v sops >/dev/null || fout "sops niet gevonden; zie docs/sleutelbeheer.md."
fi

case "${ACTIE}" in
  ophalen|opslaan|wis|ontvangers) "${ACTIE}" ;;
  *) gebruik ;;
esac
