# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# shellcheck shell=bash
# Ankercontrole: lokaal PKI-materiaal moet aansluiten op het vertrouwensanker in git. Een
# zelfgemaakte CA of een niet-passende sleutel breekt de federatie anders stil. Gedeeld door
# issue.sh en verify.sh; verwacht BASE_DIR (= pki/). Elke bevinding is een "FAIL anker:"-regel.

ANKER_HERSTEL="Herstel: git checkout -- <pad> en pki/geheimen.sh ophalen; zie docs/sleutelbeheer.md (Certificaten vernieuwen)."

# $1 = pad onder pki/. Waar als het bestand in de laatste commit staat.
anker_in_git() { git -C "${BASE_DIR}" cat-file -e "HEAD:./$1" 2>/dev/null; }

# $1 = pad onder pki/. Waar als het lokale bestand gelijk is aan HEAD.
anker_gelijk_aan_git() { git -C "${BASE_DIR}" diff --quiet HEAD -- "$1" 2>/dev/null; }

# $1 = sleutel, $2 = certificaat. Waar als ze dezelfde publieke sleutel hebben.
anker_sleutel_past() {
  local a b
  a=$(openssl pkey -in "$1" -pubout 2>/dev/null) || return 1
  b=$(openssl x509 -in "$2" -noout -pubkey 2>/dev/null) || return 1
  [ -n "${a}" ] && [ "${a}" = "${b}" ]
}

# $1 = sleutel, $2 = certificaat (beide onder pki/). Alleen als de sleutel lokaal staat.
anker_sleutel_bij() {
  [ -e "${BASE_DIR}/$1" ] || return 0
  anker_sleutel_past "${BASE_DIR}/$1" "${BASE_DIR}/$2" && return 0
  echo "FAIL anker: pki/$1 past niet bij pki/$2. ${ANKER_HERSTEL}"
  return 1
}

anker_groep() {
  local rc=0
  if ! anker_in_git ca/root.pem; then
    echo "FAIL anker: pki/ca/root.pem staat niet in git; het anker van de federatie komt uit git. ${ANKER_HERSTEL}"
    return 1
  fi
  if ! anker_gelijk_aan_git ca/root.pem; then
    echo "FAIL anker: pki/ca/root.pem wijkt af van git; een zelfgemaakte CA sluit niet aan op de federatie. ${ANKER_HERSTEL}"
    return 1
  fi
  if ! openssl verify -CAfile "${BASE_DIR}/ca/root.pem" "${BASE_DIR}/ca/intermediate.pem" >/dev/null 2>&1; then
    echo "FAIL anker: pki/ca/intermediate.pem ketent niet naar pki/ca/root.pem. ${ANKER_HERSTEL}"
    rc=1
  fi
  anker_sleutel_bij ca/root-key.pem ca/root.pem || rc=1
  anker_sleutel_bij ca/intermediate-key.pem ca/intermediate.pem || rc=1
  return "${rc}"
}

# $1 = peer. Een gecommitte internal-root is wat de draaiende pods van die peer vertrouwen.
anker_intern() {
  local root="internal/$1/ca/root.pem" rc=0
  if anker_in_git "${root}" && ! anker_gelijk_aan_git "${root}"; then
    echo "FAIL anker: pki/${root} wijkt af van git; de pods van $1 vertrouwen de gecommitte versie. ${ANKER_HERSTEL}"
    rc=1
  fi
  anker_sleutel_bij "internal/$1/ca/root-key.pem" "${root}" || rc=1
  return "${rc}"
}

anker_alles() {
  local rc=0 ca
  anker_groep || rc=1
  for ca in "${BASE_DIR}"/internal/*/ca; do
    [ -d "${ca}" ] || continue
    anker_intern "$(basename "$(dirname "${ca}")")" || rc=1
  done
  return "${rc}"
}
