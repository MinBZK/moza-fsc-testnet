#!/usr/bin/env bash
# Smoke: bewijst dat de contracten in de group de FSC-standaardversie dragen die de group-regel
# voorschrijft (`group/group-config.yaml` -> rules.fsc_core_version).
#
# Waarom dit een eigen smoke is: versie-lockstep is een GROUP-invariant, en de bestaande guard
# (`.github/scripts/check-openfsc-version.sh`) bewaakt alleen déze repo. Peers deployen in hun eigen
# ZAD-project, dus een peer die op een oudere FSC-versie blijft valt STIL uit de group: zijn
# contracten dragen een andere `fsc_version`, worden niet als geldig herkend, en er komt nergens een
# "verkeerde versie"-fout. Deze smoke maakt dat zichtbaar op de plek waar het meetbaar is — in de
# contract-content zelf.
#
# GRENZEN, expliciet: dit toetst de contracten die deze lokale group kent, niet de draaiende
# softwareversie van een externe peer. Een peer die geen contract heeft opgesteld is hier onzichtbaar.
# Voor een echte group-brede controle moet elke peer zijn eigen deploy op `openfsc_min_version`
# houden; de group-regel is de afspraak, deze smoke is het bewijs achteraf.
set -euo pipefail

HERE="$(dirname "$0")"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
COMPOSE=(docker compose -f "$HERE/docker-compose.yaml")

GROUP_CONFIG="${GROUP_CONFIG:-${REPO_ROOT}/group/group-config.yaml}"

CERT=/pki/internal/example-provider/manager/cert.pem
KEY=/pki/internal/example-provider/manager/key.pem
CA=/pki/internal/example-provider/ca/root.pem
MANAGER=https://manager.example-provider.fsc-test.local:9443

ERRLOG=$(mktemp)
trap 'rm -f "$ERRLOG"' EXIT

# --- 1. De group-regel uitlezen ----------------------------------------------------------------
# Bewust grep i.p.v. een YAML-parser: geen extra host-dependency, en de regel is één scalar.
[ -r "$GROUP_CONFIG" ] || { echo "FAIL: group-config niet leesbaar: $GROUP_CONFIG" >&2; exit 1; }
EXPECTED=$(grep -oE 'fsc_core_version:[[:space:]]*"?[0-9]+\.[0-9]+\.[0-9]+"?' "$GROUP_CONFIG" \
             | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
[ -n "$EXPECTED" ] || {
  echo "FAIL: geen rules.fsc_core_version in $GROUP_CONFIG — de group-regel ontbreekt of is hernoemd." >&2
  exit 1
}
echo "smoke-groepsversie: group-regel eist FSC Core $EXPECTED"

# --- 2. Contracten ophalen bij de provider-manager ----------------------------------------------
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq niet gevonden op de host (repo-dependency)." >&2; exit 1; }

LIST=$("${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
         --cert "$CERT" --key "$KEY" --cacert "$CA" \
         "$MANAGER/v1/contracts" 2>"$ERRLOG") || {
  echo "FAIL: GET /v1/contracts faalde: ${LIST:-<leeg>} $(tail -n1 "$ERRLOG" 2>/dev/null)" >&2
  exit 1
}

# Shape-tolerant (spiegelt contracts/bootstrap.sh): `fsc_version` kan op contract-niveau of onder
# `.content` staan, afhankelijk van het endpoint. Recursief verzamelen i.p.v. één pad aannemen.
mapfile -t VERSIONS < <(printf '%s' "$LIST" | jq -r '[.. | objects | .fsc_version? // empty] | .[]' 2>/dev/null || true)

if [ "${#VERSIONS[@]}" -eq 0 ]; then
  echo "FAIL: geen enkel contract met een fsc_version gevonden." >&2
  echo "  Draai eerst publish-service.sh + contracts/bootstrap.sh. Staan er wél contracten maar" >&2
  echo "  zónder fsc_version, dan draait deze manager nog een pre-v2.0.0-versie." >&2
  printf '  Respons: %s\n' "$LIST" >&2
  exit 1
fi

# --- 3. Elk contract moet de group-versie dragen -------------------------------------------------
afwijkend=0
for version in "${VERSIONS[@]}"; do
  if [ "$version" != "$EXPECTED" ]; then
    echo "  AFWIJKING: contract draagt fsc_version=$version, group-regel eist $EXPECTED" >&2
    afwijkend=$((afwijkend + 1))
  fi
done

if [ "$afwijkend" -ne 0 ]; then
  echo "FAIL: $afwijkend van ${#VERSIONS[@]} contract(en) wijken af van de group-regel." >&2
  echo "  Een peer die een andere FSC-versie draait valt stil uit de group: zijn contract-hash" >&2
  echo "  wordt door de rest niet herkend. Zie group/group-config.yaml en" >&2
  echo "  docs/openfsc-versiebeheer.md." >&2
  exit 1
fi

echo "OK: alle ${#VERSIONS[@]} contract(en) dragen FSC Core $EXPECTED (group-regel gehaald)."
