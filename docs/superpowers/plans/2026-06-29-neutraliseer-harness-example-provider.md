# Plan 1 — Neutraliseer harness naar `example-provider` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verwijder de FBS-specifieke peers uit dit repo en herbedraad de lokale harness naar één neutrale `example-provider`-peer, zodat de announce-smoke groen blijft zonder FBS-namen/OINs.

**Architecture:** Dit is fase 1 van [Spec A](../specs/2026-06-29-fsc-generiek-provider-onboarding-design.md). De PKI-scripts (`pki/issue.sh`, `pki/verify.sh`) ontdekken peers automatisch via `pki/peers/*/`, dus een peer vervangen = mappen verwijderen/toevoegen. De harness (`deploy/local/`) verwijst alleen naar `directory` + `magazijn-a`; we hernoemen `magazijn-a` → `example-provider` overal.

**Tech Stack:** cfssl (PKI), docker-compose, haproxy (SNI-passthrough), postgres, OpenFSC manager/controller/directory-ui images, bash smoke-test.

## Global Constraints

- **example-provider OIN:** `00000000000000000030` (synthetisch; in lockstep tussen `pki/peers/example-provider/*/csr.json` veld `serialnumber` en `peers/example-provider/values.example.yaml` veld `peer.oin`).
- **directory OIN:** `00000000000000000010` (ongewijzigd).
- **GROUP_ID:** `moza-fbs-test` (ongewijzigd in dit plan; rename is een los open punt — niet hier).
- **Secrets nooit committen:** `pki/ca/`, `pki/out/`, `pki/internal/` zijn gitignored. Alleen `csr.json` + `.example`-templates worden gecommit.
- **Branch:** `feature/peer-magazijn-724`.
- **Commit-trailer:** elke commit eindigt met `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Taal:** Nederlands; FSC-idiomen (inway, outway, manager, directory, peer, grant) niet vertalen.
- **Out of scope (latere plannen):** ca-cfssl + ca-certportal, inway + stub-upstream, dienst-publicatie, docs-herschrijven (`topologie.md`/`README.md`/`CLAUDE.md`/`pki/README.md`), ZAD-env-templates.

---

### Task 1: PKI + peer-config → `example-provider`

Verwijder de FBS-peers en maak één neutrale `example-provider`-peer. De PKI-scripts adapteren automatisch.

**Files:**

- Delete: `peers/magazijn-a/`, `peers/magazijn-b/`, `peers/uitvraag-org/` (volledige mappen)
- Delete: `pki/peers/magazijn-a/`, `pki/peers/magazijn-b/`, `pki/peers/uitvraag-org/` (volledige mappen)
- Create: `pki/peers/example-provider/manager/csr.json`
- Create: `pki/peers/example-provider/inway/csr.json`
- Create: `peers/example-provider/values.example.yaml`
- Test (bestaand, generiek): `pki/verify.sh`

**Interfaces:**

- Produces: peer-naam `example-provider`, OIN `00000000000000000030`, endpoints `manager` + `inway`, cert-paden `pki/out/example-provider/{manager,inway}/{cert,key}.pem` en `pki/internal/example-provider/{ca/root,manager/{cert,key},inway/{cert,key}}.pem`. Task 2 (harness) consumeert deze paden.

- [ ] **Step 1: Verwijder de FBS-peer-mappen**

```bash
cd /home/claude/projects/moza-fsc-testnet
git rm -r peers/magazijn-a peers/magazijn-b peers/uitvraag-org
git rm -r pki/peers/magazijn-a pki/peers/magazijn-b pki/peers/uitvraag-org
```

- [ ] **Step 2: Maak de example-provider manager-CSR**

Create `pki/peers/example-provider/manager/csr.json`:

```json
{
  "CN": "manager.example-provider.fsc-test.local",
  "key": { "algo": "rsa", "size": 4096 },
  "hosts": ["manager.example-provider.fsc-test.local"],
  "serialnumber": "00000000000000000030",
  "names": [{ "O": "example-provider", "C": "NL" }]
}
```

- [ ] **Step 3: Maak de example-provider inway-CSR**

Create `pki/peers/example-provider/inway/csr.json`:

```json
{
  "CN": "inway.example-provider.fsc-test.local",
  "key": { "algo": "rsa", "size": 4096 },
  "hosts": ["inway.example-provider.fsc-test.local"],
  "serialnumber": "00000000000000000030",
  "names": [{ "O": "example-provider", "C": "NL" }]
}
```

- [ ] **Step 4: Maak de example-provider peer-values-template**

Create `peers/example-provider/values.example.yaml`:

```yaml
# Helm-values voor de neutrale voorbeeld-provider-peer (Spec A, #724).
# Consumeert de OpenFSC Helm-charts (https://gitlab.com/rinis-oss/fsc/open-fsc, helm/charts).
#
# example-provider = neutraal voorbeeld dat de generieke provider-onboarding bewijst.
# GEEN echte organisatie. Houd de OIN 1:1 in lockstep met
# pki/peers/example-provider/<endpoint>/csr.json -> veld `serialnumber`.
peer:
  oin: "00000000000000000030"                   # synthetische voorbeeld-OIN -> wordt Peer ID
  name: "example-provider"                       # -> subject.organization in het cert
manager:
  managementAddress: "example-provider-manager:8443"
  postgresDsn: "postgres://fsc:fsc@example-provider-postgres:5432/fsc?sslmode=disable"
inway:
  name: "example-provider-inway"
  selfAddress: "example-provider-inway:443"      # eigen SNI-hostnaam (passthrough-Route)
  directoryRegistrationAddress: "directory-manager:8443"
  upstream: "example-upstream:8080"              # neutrale stub-upstream (geen FBS-app)

# TODO(#724): dit skelet toont alleen de hoofd-adressen. Een werkende OpenFSC-deploy
# vereist daarnaast (zie open-fsc helm/charts), uitgewerkt in vervolgplannen:
#   - certificaten: certificates.group.* + certificates.internal.* +
#     certificates.internalUnauthenticated.* (inter-component mTLS, manager<->inway);
#   - interne manager-poorten 9443 (authenticated) en 9444 (unauthenticated);
#   - transaction-log: txlog-api-adres voor manager én inway (verplichte logging-extensie).
# `upstream` is een neutrale stub die de business-app vervangt.
# Echte secrets/certs worden via ZAD `attachments` gemount, nooit hier ingevuld.
```

- [ ] **Step 5: Zorg dat de group-CA bestaat (alleen als `pki/ca/` ontbreekt)**

Run:

```bash
[ -s pki/ca/intermediate.pem ] || ./pki/init-ca.sh && ./pki/gen-crl.sh
```

Expected: `pki/ca/root.pem`, `pki/ca/intermediate.pem`, `pki/ca/intermediate.crl` bestaan.

- [ ] **Step 6: (Her)genereer de certs en run de acceptatie-asserts**

Run:

```bash
./pki/issue.sh -f && ./pki/fix-permissions.sh && ./pki/verify.sh
```

Expected: laatste regel `== ALLE ASSERTS GROEN ==`, exit 0. De output toont `OK keten: out/example-provider/manager/cert.pem`, `out/example-provider/inway/cert.pem` en bijbehorende internal-certs; geen `magazijn`/`uitvraag` meer.

- [ ] **Step 7: Verifieer dat geen FBS-OIN/namen in de gecommitte config staan**

Run:

```bash
grep -rn '00000001003214345000\|00000001823288444000\|magazijn\|uitvraag-org' peers/ pki/peers/
```

Expected: geen treffers (exit 1 / lege output).

- [ ] **Step 8: Commit**

```bash
git add peers/example-provider pki/peers/example-provider
git add -u peers pki/peers
git commit -m "$(cat <<'EOF'
refactor(local): vervang FBS-peers door neutrale example-provider (#724)

Verwijdert magazijn-a/-b + uitvraag-org (echte FBS-OINs, berichtenmagazijn-
upstream) uit dit infra-repo en zet er één neutrale example-provider voor in
de plaats (synthetische OIN 00000000000000000030). PKI-scripts ontdekken
peers via pki/peers/*/ en adapteren automatisch; verify.sh groen.

Onderdeel van het FBS-agnostisch maken van het repo (Spec A); de FBS-peers
worden opnieuw opgezet in moza-poc-fbs-berichtenbox (Spec B).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Herbedraad de lokale harness `magazijn-a` → `example-provider`

Hernoem elke `magazijn-a`-referentie in de harness naar `example-provider`. De harness blijft functioneel identiek (manager + controller + directory + directory-ui), alleen de peer-naam/OIN/DB's/SNI wijzigen.

**Files:**

- Modify: `deploy/local/docker-compose.yaml`
- Modify: `deploy/local/haproxy.cfg`
- Modify: `deploy/local/postgres-init.sql`
- Modify: `deploy/local/smoke-announce.sh`
- Test (bestaand): `deploy/local/smoke-announce.sh`

**Interfaces:**

- Consumes: cert-paden uit Task 1 (`pki/out/example-provider/...`, `pki/internal/example-provider/...`).
- Produces: compose-services `migrate-example-provider`, `manager-example-provider`; DB's `fsc_example_provider`, `fsc_controller_example_provider`; SNI-host `example-provider.fsc-test.local`; smoke pollt op OIN `...030`.

- [ ] **Step 1: Pas de smoke-test eerst aan (faalt nu tegen de oude compose)**

In `deploy/local/smoke-announce.sh`:

- Regel 9: `MAGA_OIN="00000001003214345000"` → `PROVIDER_OIN="00000000000000000030"`
- Vervang overal in het bestand `magazijn-a` → `example-provider` (regels 2–4, 20, 27, 38) en `$MAGA_OIN` → `$PROVIDER_OIN` (regels 20, 26).
- Regel 55: in de `logs --tail=50`-lijst `migrate-magazijn-a manager-magazijn-a` → `migrate-example-provider manager-example-provider`.

Concreet worden de load-bearing regels:

```bash
PROVIDER_OIN="00000000000000000030"
DIR_OIN="00000000000000000010"
```

```bash
  if printf '%s\n' "$rows" | grep -qx "$PROVIDER_OIN"; then
    echo "OK: example-provider is aangemeld bij de directory (manager_address op :443)."
```

- [ ] **Step 2: Run de smoke tegen de nog-niet-aangepaste compose en bevestig dat hij faalt**

Run:

```bash
cd deploy/local && docker compose up -d --build && ./smoke-announce.sh; cd -
```

Expected: FAIL — de smoke pollt op OIN `...030`, maar de compose meldt nog `magazijn-a` (`...030` komt niet in `peers.peers`). Dit bevestigt dat de smoke de nieuwe peer afdwingt. (Ruim daarna op: `cd deploy/local && docker compose down -v; cd -`.)

- [ ] **Step 3: Herbedraad `docker-compose.yaml`**

Voer in `deploy/local/docker-compose.yaml` deze exacte vervangingen door (alle occurrences):

- `magazijn-a` → `example-provider`  (dekt servicenamen `migrate-magazijn-a`/`manager-magazijn-a`, SNI-aliassen `magazijn-a.fsc-test.local` + `manager.magazijn-a.fsc-test.local`, en cert-paden `/pki/out/magazijn-a/...` + `/pki/internal/magazijn-a/...`)
- `magazijn_a` → `example_provider`  (dekt DB's `fsc_magazijn_a`, `fsc_controller_magazijn_a`)
- YAML-anchors voor leesbaarheid: `maga-grp` → `ep-grp`, `maga-grp-key` → `ep-grp-key`, `maga-introot` → `ep-introot`, `maga-int` → `ep-int`, `maga-int-key` → `ep-int-key` (zowel de `&`-definitie als de `*`-referentie).

Na de vervangingen luiden de kernregels (ter controle):

```yaml
  manager-example-provider:
    image: *manager-image
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    command:
      - /usr/local/bin/manager
      - serve
    environment:
      <<: *manager-common-env
      SELF_ADDRESS: https://example-provider.fsc-test.local:443
      TX_LOG_API_ADDRESS: https://txlog.placeholder.invalid:7611
      ...
      STORAGE_POSTGRES_DSN: postgres://postgres:postgres@postgres:5432/fsc_example_provider?sslmode=disable
      TLS_GROUP_CERT: &ep-grp /pki/out/example-provider/manager/cert.pem
      TLS_GROUP_KEY: &ep-grp-key /pki/out/example-provider/manager/key.pem
      ...
    networks:
      default:
        aliases:
          - manager.example-provider.fsc-test.local
```

En de controller-/directory-ui-referenties:

```yaml
      MANAGER_ADDRESS_INTERNAL: https://manager.example-provider.fsc-test.local:9443
      POSTGRES_DATABASE: fsc_controller_example_provider
      STORAGE_POSTGRES_DSN: postgres://postgres:postgres@postgres:5432/fsc_controller_example_provider?sslmode=disable
      TLS_ROOT_CERT: /pki/internal/example-provider/ca/root.pem
      TLS_CERT: /pki/internal/example-provider/manager/cert.pem
      TLS_KEY: /pki/internal/example-provider/manager/key.pem
```

```yaml
      # directory-ui lezer-identiteit:
      TLS_GROUP_CERT: /pki/out/example-provider/manager/cert.pem
      TLS_GROUP_KEY: /pki/out/example-provider/manager/key.pem
```

Verifieer dat geen `magazijn` meer in het bestand staat:

```bash
grep -n 'magazijn' deploy/local/docker-compose.yaml
```

Expected: geen treffers.

- [ ] **Step 4: Herbedraad `haproxy.cfg`**

In `deploy/local/haproxy.cfg`:

- Regel 31: `use_backend maga if { req_ssl_sni -i magazijn-a.fsc-test.local }` → `use_backend ep if { req_ssl_sni -i example-provider.fsc-test.local }`
- Regel 35–36: `backend maga` / `server s1 manager-magazijn-a:8443` → `backend ep` / `server s1 manager-example-provider:8443`

Resultaat:

```text
    use_backend dir  if { req_ssl_sni -i directory.fsc-test.local }
    use_backend ep   if { req_ssl_sni -i example-provider.fsc-test.local }

backend dir
    server s1 manager-directory:8443
backend ep
    server s1 manager-example-provider:8443
```

- [ ] **Step 5: Herbedraad `postgres-init.sql`**

Vervang `deploy/local/postgres-init.sql` regels 4–5:

```sql
CREATE DATABASE fsc_example_provider;
CREATE DATABASE fsc_controller_example_provider;
```

(Regel 3 `CREATE DATABASE fsc_directory;` blijft ongewijzigd.)

- [ ] **Step 6: Breng de harness vers op en run de smoke (moet nu slagen)**

Run:

```bash
cd deploy/local && docker compose down -v && docker compose up -d --build && ./smoke-announce.sh; cd -
```

Expected: `OK: example-provider is aangemeld bij de directory (manager_address op :443).` en de tabel toont rijen voor `00000000000000000010` (directory) + `00000000000000000030` (example-provider). Exit 0.

- [ ] **Step 7: Ruim de harness op**

Run:

```bash
cd deploy/local && docker compose down -v; cd -
```

- [ ] **Step 8: Commit**

```bash
git add deploy/local/docker-compose.yaml deploy/local/haproxy.cfg deploy/local/postgres-init.sql deploy/local/smoke-announce.sh
git commit -m "$(cat <<'EOF'
refactor(local): herbedraad harness magazijn-a -> example-provider (#724)

Hernoemt de FBS-voorbeeldpeer in de lokale harness naar de neutrale
example-provider: compose-services, DB's (fsc_example_provider,
fsc_controller_example_provider), SNI-host + router-backend, en de
announce-smoke (pollt nu op OIN 00000000000000000030). Functioneel
identiek; announce-smoke groen.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Werk de harness-README bij naar `example-provider`

De handleiding `deploy/local/README.md` gebruikt `magazijn-a` in voorbeelden/verwachte output. Herschrijf naar `example-provider` zodat de README klopt met de harness.

**Files:**

- Modify: `deploy/local/README.md`
- Test: `markdownlint`

**Interfaces:**

- Consumes: namen/paden uit Task 1 + 2.

- [ ] **Step 1: Lees de README en vervang FBS-namen**

Run:

```bash
grep -n 'magazijn\|maga\|00000001003214345000' deploy/local/README.md
```

Vervang in `deploy/local/README.md` op elke getoonde regel:

- `magazijn-a` → `example-provider`
- cert-paden `out/magazijn-a/...` → `out/example-provider/...`, `internal/magazijn-a/...` → `internal/example-provider/...`
- OIN `00000001003214345000` → `00000000000000000030`
- losse backend-verwijzing `maga` → `ep`

Behoud de structuur en uitleg (cert-contract, troubleshooting); alleen de peer-specifieke waarden wijzigen.

- [ ] **Step 2: Verifieer dat geen FBS-namen resteren**

Run:

```bash
grep -n 'magazijn\|00000001003214345000' deploy/local/README.md
```

Expected: geen treffers.

- [ ] **Step 3: Lint de README**

Run:

```bash
npx --yes markdownlint-cli2 deploy/local/README.md
```

Expected: geen lint-fouten (of dezelfde baseline als vóór de wijziging; los nieuw geïntroduceerde fouten op).

- [ ] **Step 4: Commit**

```bash
git add deploy/local/README.md
git commit -m "$(cat <<'EOF'
docs(local): harness-README naar example-provider (#724)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec-dekking (Spec A → dit plan):** Dit plan dekt alleen de "Verwijderen (FBS-specifiek)" + harness-neutralisatie-delen van Spec A's "Wijzigingen in dit repo". Bewust uitgesteld naar vervolgplannen (Global Constraints → out of scope): ca-cfssl + ca-certportal, inway + stub-upstream, dienst-publicatie + smoke-uitbreiding, docs-herschrijven buiten de harness-README, ZAD-env-templates. Na dit plan: harness draait neutraal, announce groen — werkende, testbare software.

**Placeholder-scan:** Geen "TBD"/"later" in stappen; `TODO(#724)` in de values-template is een bewuste vooruitwijzing naar vervolgplannen (volgt Spec A), geen plan-gat. Alle code/commando's concreet.

**Type-/naam-consistentie:** OIN `00000000000000000030` identiek in csr.json (×2), values.example.yaml, smoke (`PROVIDER_OIN`), verwachte verify/smoke-output. Peer-naam `example-provider` en DB's `fsc_example_provider`/`fsc_controller_example_provider` consistent over Task 1–3. Anchors `ep-*` consistent hernoemd. Geen verwijzing naar niet-gedefinieerde namen.

**Open punt (genoteerd, niet hier opgelost):** `GROUP_ID=moza-fbs-test` bevat nog "fbs"; rename raakt directory-cert-CN's niet maar wel veel env-plekken → apart open punt in Spec A, buiten dit plan.
