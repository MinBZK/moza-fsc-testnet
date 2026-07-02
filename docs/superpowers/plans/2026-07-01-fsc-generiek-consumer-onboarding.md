# example-consumer onboarding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Een neutrale `example-consumer`-peer (manager + outway + controller + DB) die lokaal boot, zich bij de directory aanmeldt (announce) en de gepubliceerde `example-service` terugvindt (discovery).

**Architecture:** Spiegel van `example-provider` (#724). De consumer draait als tweede peer in dezelfde `deploy/local`-compose naast de provider en deelt de centrale kern (directory-manager, directory-ui, postgres, router). Nieuwe per-endpoint CSR's worden automatisch opgepikt door `pki/issue.sh`; een nieuw `smoke-discover.sh` bewijst announce + discovery via directory-DB-queries.

**Tech Stack:** OpenFSC container-images (`federatedserviceconnectivity/{manager,outway,controller,directory-ui}`), docker-compose, HAProxy (SNI-passthrough), CFSSL (test-PKI), Postgres 17, bash smoke-scripts.

## Global Constraints

- Peer-ID = OIN uit cert `subject.serialNumber`; peer-naam uit `subject.organization`. OIN in **lockstep** tussen `pki/peers/example-consumer/*/csr.json` en `peers/example-consumer/values.example.yaml`.
- `example-consumer` OIN = `00000000000000000020`, `O=example-consumer`, `C=NL`.
- Secrets/keys/certs **nooit** committen — alleen scripts + `.example`-templates (`.gitignore`).
- Group-ID = `moza-fbs-test`; directory-peer-ID = `00000000000000000010` (bestaand).
- Manager-mesh + data op `:443` via HAProxy SNI (passthrough); edge/reencrypt verboden.
- Lint moet groen: yamllint + markdownlint + actionlint. Lokaal beschikbaar: `cfssl`, `cfssljson`, `yamllint`, `jq`, `bash -n`. **Niet** lokaal: `docker` → de volledige `docker compose up`-smoke draait host-side (checkout is volume-mounted op de docker-host).
- Commit-trailer voor AI-bijdragen: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: PKI-CSR's voor example-consumer

**Files:**

- Create: `pki/peers/example-consumer/manager/csr.json`
- Create: `pki/peers/example-consumer/outway/csr.json`
- Create: `pki/peers/example-consumer/controller/csr.json`

**Interfaces:**

- Produces: group-certs `pki/out/example-consumer/{manager,outway,controller}/{cert,key}.pem` en internal-certs `pki/internal/example-consumer/{ca,manager,outway,controller}/...`, geconsumeerd door de compose-services in Task 4/5. Cert-hostnamen (SAN): `manager.example-consumer.fsc-test.local` (+ `example-consumer.fsc-test.local`), `outway.example-consumer.fsc-test.local`, `controller.example-consumer.fsc-test.local`.

- [ ] **Step 1: Schrijf de drie CSR-bestanden**

`pki/peers/example-consumer/manager/csr.json` (spiegelt provider-manager; manager heeft de peer-hostnaam ook als SAN voor de mesh):

```json
{
  "CN": "manager.example-consumer.fsc-test.local",
  "key": { "algo": "rsa", "size": 4096 },
  "hosts": ["manager.example-consumer.fsc-test.local", "example-consumer.fsc-test.local"],
  "serialnumber": "00000000000000000020",
  "names": [{ "O": "example-consumer", "C": "NL" }]
}
```

`pki/peers/example-consumer/outway/csr.json`:

```json
{
  "CN": "outway.example-consumer.fsc-test.local",
  "key": { "algo": "rsa", "size": 4096 },
  "hosts": ["outway.example-consumer.fsc-test.local"],
  "serialnumber": "00000000000000000020",
  "names": [{ "O": "example-consumer", "C": "NL" }]
}
```

`pki/peers/example-consumer/controller/csr.json`:

```json
{
  "CN": "controller.example-consumer.fsc-test.local",
  "key": { "algo": "rsa", "size": 4096 },
  "hosts": ["controller.example-consumer.fsc-test.local"],
  "serialnumber": "00000000000000000020",
  "names": [{ "O": "example-consumer", "C": "NL" }]
}
```

- [ ] **Step 2: Valideer JSON-syntax**

Run: `for f in pki/peers/example-consumer/*/csr.json; do jq -e . "$f" >/dev/null && echo "OK $f"; done`
Expected: drie `OK`-regels, geen jq-fout.

- [ ] **Step 3: Genereer de certs (idempotent)**

Run: `bash pki/issue.sh`
Expected: regels `internal-CA voor example-consumer...`, `group-cert voor example-consumer/{manager,outway,controller}...`, `internal-cert voor ...`, afsluitend `OK: group-certs in .../out, internal-certs in .../internal`. (Bestaande peers tonen `skip ... (geen -f)`.)

- [ ] **Step 4: Verifieer keten + OIN**

Run: `bash pki/verify.sh | grep -i example-consumer`
Expected: `OK keten:` en `OK ...` (serialNumber) regels voor elke example-consumer-endpoint; geen `FAIL`. Draai daarna `bash pki/verify.sh >/dev/null; echo "exit=$?"` → `exit=0`.

- [ ] **Step 5: Commit** (alleen de CSR-templates; `out/` en `internal/` zijn gitignored)

```bash
git add pki/peers/example-consumer/
git commit -m "feat(pki): example-consumer CSRs (manager/outway/controller, OIN ...0020) (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Peer-template `values.example.yaml`

**Files:**

- Create: `peers/example-consumer/values.example.yaml`

**Interfaces:**

- Consumes: OIN `00000000000000000020` (lockstep met Task 1).
- Produces: documentatie-template (niet gedeployd door de lokale harness; source-of-truth voor ZAD #729). Geen downstream code-afhankelijkheid.

- [ ] **Step 1: Schrijf de values (spiegel van `peers/example-provider/values.example.yaml`, outway i.p.v. inway, geen upstream)**

```yaml
# Helm-values voor de neutrale voorbeeld-consumer-peer (#725).
# Consumeert de OpenFSC Helm-charts (https://gitlab.com/rinis-oss/fsc/open-fsc, helm/charts).
#
# example-consumer = neutraal voorbeeld dat de generieke consumer-onboarding bewijst.
# GEEN echte organisatie. Houd de OIN 1:1 in lockstep met
# pki/peers/example-consumer/<endpoint>/csr.json -> veld `serialnumber`.
peer:
  oin: "00000000000000000020"                     # synthetische voorbeeld-OIN -> wordt Peer ID
  name: "example-consumer"                          # -> subject.organization in het cert
manager:
  managementAddress: "example-consumer-manager:8443"
  postgresDsn: "postgres://fsc:fsc@example-consumer-postgres:5432/fsc?sslmode=disable"
outway:
  name: "example-consumer-outway"
  selfAddress: "example-consumer-outway:443"       # eigen SNI-hostnaam (passthrough-Route)
  managerAddress: "example-consumer-manager:9444"  # interne-unauthenticated manager-poort

# TODO(#725): dit skelet toont alleen de hoofd-adressen. Een werkende OpenFSC-deploy
# vereist daarnaast (zie open-fsc helm/charts), uitgewerkt in vervolgplannen:
#   - certificaten: certificates.group.* + certificates.internal.* +
#     certificates.internalUnauthenticated.* (inter-component mTLS, manager<->outway);
#   - interne manager-poorten 9443 (authenticated) en 9444 (unauthenticated);
#   - transaction-log: txlog-api-adres voor manager én outway (verplichte logging-extensie).
# De outway routeert pas met een contract (#727) en data-pad (#728).
# Echte secrets/certs worden via ZAD `attachments` gemount, nooit hier ingevuld.
```

- [ ] **Step 2: Lint**

Run: `yamllint peers/example-consumer/values.example.yaml`
Expected: geen output (exit 0). Als yamllint een config in de repo heeft, gebruikt hij die automatisch.

- [ ] **Step 3: Commit**

```bash
git add peers/example-consumer/values.example.yaml
git commit -m "feat(peers): example-consumer values-template (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Consumer-DB's in `postgres-init.sql`

**Files:**

- Modify: `deploy/local/postgres-init.sql`

**Interfaces:**

- Produces: databases `fsc_example_consumer` (peer-manager) en `fsc_controller_example_consumer` (consumer-controller), geconsumeerd door Task 5.

- [ ] **Step 1: Lees het bestand om het bestaande patroon te matchen**

Run: `cat deploy/local/postgres-init.sql`
Expected: `CREATE DATABASE fsc_directory;`, `fsc_example_provider`, `fsc_controller_example_provider` (of vergelijkbaar). Neem exact dezelfde stijl over.

- [ ] **Step 2: Voeg de twee consumer-databases toe** (onder de provider-regels)

```sql
CREATE DATABASE fsc_example_consumer;
CREATE DATABASE fsc_controller_example_consumer;
```

- [ ] **Step 3: Commit**

```bash
git add deploy/local/postgres-init.sql
git commit -m "feat(local): consumer-DBs in postgres-init (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Provider-controller hernoemen voor symmetrie

**Files:**

- Modify: `deploy/local/docker-compose.yaml`

**Interfaces:**

- Produces: compose-service-keys `controller-example-provider` + `migrate-controller-example-provider` (was `controller` / `migrate-controller`). De network-alias blijft `controller.example-provider.fsc-test.local`; smoke-scripts reiken de controller via `toolbox`-curl op die hostnaam, dus geen scriptwijziging.

- [ ] **Step 1: Hernoem de twee service-keys en hun onderlinge `depends_on`**

In `deploy/local/docker-compose.yaml`:

- service-key `migrate-controller:` → `migrate-controller-example-provider:`
- service-key `controller:` → `controller-example-provider:`
- in `controller-example-provider.depends_on`: `migrate-controller` → `migrate-controller-example-provider`
- in elke andere `depends_on` die naar `controller` verwijst (o.a. `inway-example-provider`, `toolbox`): `controller:` → `controller-example-provider:`

Laat de `networks.default.aliases: [controller.example-provider.fsc-test.local]` ongewijzigd.

- [ ] **Step 2: Controleer dat er geen kale `controller`-service-referentie meer is**

Run: `grep -nE '^\s+(controller|migrate-controller):|(depends_on|condition).*\bcontroller\b' deploy/local/docker-compose.yaml`
Expected: geen treffer die naar de kale `controller`/`migrate-controller` service-key wijst (alleen `controller-example-provider` en hostnamen `controller.*.fsc-test.local` mogen voorkomen).

- [ ] **Step 3: Lint**

Run: `yamllint deploy/local/docker-compose.yaml`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add deploy/local/docker-compose.yaml
git commit -m "refactor(local): controller -> controller-example-provider voor peer-symmetrie (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Consumer-services in docker-compose

**Files:**

- Modify: `deploy/local/docker-compose.yaml`

**Interfaces:**

- Consumes: certs uit Task 1 (`/pki/out/example-consumer/...`, `/pki/internal/example-consumer/...`), DB's uit Task 3, controller-rename uit Task 4.
- Produces: services `migrate-example-consumer`, `manager-example-consumer`, `migrate-controller-example-consumer`, `controller-example-consumer`, `outway-example-consumer`; router-alias `example-consumer.fsc-test.local`. Manager-hostnaam-SAN `manager.example-consumer.fsc-test.local` geconsumeerd door de controller/outway; peer-mesh-hostnaam `example-consumer.fsc-test.local` door HAProxy (Task 6).

- [ ] **Step 1: Voeg de router-alias toe**

In `services.router.networks.default.aliases` (naast `directory.fsc-test.local`, `example-provider.fsc-test.local`):

```yaml
          - example-consumer.fsc-test.local
```

- [ ] **Step 2: Voeg `migrate-example-consumer` toe** (spiegel `migrate-example-provider`)

```yaml
  migrate-example-consumer:
    image: *manager-image
    command:
      - /usr/local/bin/manager
      - migrate
      - up
      - --postgres-dsn
      - postgres://postgres:postgres@postgres:5432/fsc_example_consumer?sslmode=disable
    depends_on:
      postgres:
        condition: service_healthy
    restart: on-failure
```

- [ ] **Step 3: Voeg `manager-example-consumer` toe** (spiegel `manager-example-provider`; consumer heeft géén `AUTO_SIGN_GRANTS`)

```yaml
  manager-example-consumer:
    image: *manager-image
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    command:
      - /usr/local/bin/manager
      - serve
    environment:
      <<: *manager-common-env
      SELF_ADDRESS: https://example-consumer.fsc-test.local:443
      TX_LOG_API_ADDRESS: https://txlog.placeholder.invalid:7611
      LISTEN_ADDRESS_EXTERNAL: 0.0.0.0:8443
      LISTEN_ADDRESS_INTERNAL: 0.0.0.0:9443
      LISTEN_ADDRESS_INTERNAL_UNAUTHENTICATED: 0.0.0.0:9444
      MONITORING_ADDRESS: 0.0.0.0:8080
      STORAGE_POSTGRES_DSN: postgres://postgres:postgres@postgres:5432/fsc_example_consumer?sslmode=disable
      TLS_GROUP_CERT: &ec-grp /pki/out/example-consumer/manager/cert.pem
      TLS_GROUP_KEY: &ec-grp-key /pki/out/example-consumer/manager/key.pem
      TLS_GROUP_TOKEN_CERT: *ec-grp
      TLS_GROUP_TOKEN_KEY: *ec-grp-key
      TLS_GROUP_CONTRACT_CERT: *ec-grp
      TLS_GROUP_CONTRACT_KEY: *ec-grp-key
      TLS_ROOT_CERT: &ec-introot /pki/internal/example-consumer/ca/root.pem
      TLS_CERT: &ec-int /pki/internal/example-consumer/manager/cert.pem
      TLS_KEY: &ec-int-key /pki/internal/example-consumer/manager/key.pem
      TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT: *ec-introot
      TLS_INTERNAL_UNAUTHENTICATED_CERT: *ec-int
      TLS_INTERNAL_UNAUTHENTICATED_KEY: *ec-int-key
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    networks:
      default:
        aliases:
          - manager.example-consumer.fsc-test.local
    depends_on:
      migrate-example-consumer:
        condition: service_completed_successfully
      manager-directory:
        condition: service_started
```

- [ ] **Step 4: Voeg `migrate-controller-example-consumer` toe** (spiegel provider-migrate-controller)

```yaml
  migrate-controller-example-consumer:
    image: docker.io/federatedserviceconnectivity/controller:${IMAGE_TAG:-v1.43.7}
    command:
      - /usr/local/bin/controller
      - migrate
      - up
      - --postgres-dsn
      - postgres://postgres:postgres@postgres:5432/fsc_controller_example_consumer?sslmode=disable
    depends_on:
      postgres:
        condition: service_healthy
    restart: on-failure
```

- [ ] **Step 5: Voeg `controller-example-consumer` toe** (spiegel `controller-example-provider`; eigen DB, host-poort 8091, eigen manager/certs; `AUTHN_TYPE=none`)

```yaml
  controller-example-consumer:
    image: docker.io/federatedserviceconnectivity/controller:${IMAGE_TAG:-v1.43.7}
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    restart: on-failure
    ports:
      - "127.0.0.1:8091:8080"
    environment:
      LOG_TYPE: local
      LOG_LEVEL: info
      LISTEN_ADDRESS_UI: 0.0.0.0:8080
      LISTEN_ADDRESS_REGISTRATION_API: 0.0.0.0:9443
      LISTEN_ADDRESS_ADMINISTRATION_API: 0.0.0.0:9444
      MONITORING_ADDRESS: 0.0.0.0:8081
      MANAGER_ADDRESS_INTERNAL: https://manager.example-consumer.fsc-test.local:9443
      GROUP_ID: moza-fbs-test
      DIRECTORY_PEER_ID: "00000000000000000010"
      POSTGRES_HOST: postgres
      POSTGRES_PORT: "5432"
      POSTGRES_DATABASE: fsc_controller_example_consumer
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      PGSSLMODE: disable
      STORAGE_POSTGRES_DSN: postgres://postgres:postgres@postgres:5432/fsc_controller_example_consumer?sslmode=disable
      AUTHN_TYPE: none
      AUTHZ_TYPE: rbac
      CSRF_PROTECTION_ENABLED: "false"
      AUDITLOG_TYPE: stdout
      TLS_ROOT_CERT: /pki/internal/example-consumer/ca/root.pem
      TLS_CERT: /pki/internal/example-consumer/controller/cert.pem
      TLS_KEY: /pki/internal/example-consumer/controller/key.pem
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    networks:
      default:
        aliases:
          - controller.example-consumer.fsc-test.local
    depends_on:
      migrate-controller-example-consumer:
        condition: service_completed_successfully
      manager-example-consumer:
        condition: service_started
```

- [ ] **Step 6: Voeg `outway-example-consumer` toe** (spiegelt de inway-env: group- + internal-certs; géén controller-registratie — de outway leest config van de eigen manager. In #725 boot-t hij enkel.)

```yaml
  outway-example-consumer:
    image: docker.io/federatedserviceconnectivity/outway:${IMAGE_TAG:-v1.43.7}
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    restart: on-failure                            # boot-race met de eigen manager
    command:
      - /usr/local/bin/outway
      - serve
    environment:
      LOG_TYPE: local
      LOG_LEVEL: debug
      GROUP_ID: moza-fbs-test
      NAME: example-consumer-outway
      SELF_ADDRESS: https://outway.example-consumer.fsc-test.local:443
      LISTEN_ADDRESS: 0.0.0.0:8443
      MONITORING_ADDRESS: 0.0.0.0:8081
      DISABLE_CRL_CHECKS: "true"
      # Leest zijn contract-/service-config van de eigen manager (internal-unauthenticated):
      MANAGER_INTERNAL_UNAUTHENTICATED_ADDRESS: https://manager.example-consumer.fsc-test.local:9444
      # Presence-check (placeholder); outway mag crashen als de waarde bij egress gedialed wordt (dan txlog-api toevoegen, #728):
      TX_LOG_API_ADDRESS: https://txlog.placeholder.invalid:7611
      TLS_ROOT_CERT: /pki/internal/example-consumer/ca/root.pem
      TLS_CERT: /pki/internal/example-consumer/outway/cert.pem
      TLS_KEY: /pki/internal/example-consumer/outway/key.pem
      TLS_GROUP_ROOT_CERT: /pki/ca/root.pem
      TLS_GROUP_CERT: /pki/out/example-consumer/outway/cert.pem
      TLS_GROUP_KEY: /pki/out/example-consumer/outway/key.pem
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    networks:
      default:
        aliases:
          - outway.example-consumer.fsc-test.local
    depends_on:
      manager-example-consumer:
        condition: service_started
```

> **Verifieer bij eerste host-run:** de exacte OpenFSC-outway-env-namen (`LISTEN_ADDRESS`, `MANAGER_INTERNAL_UNAUTHENTICATED_ADDRESS`, `NAME`) tegen de `federatedserviceconnectivity/outway`-image (`outway serve --help` of de OpenFSC `helm/charts`-outway-values). Pas de env-namen aan als de image andere sleutels verwacht; de cert-paden en hostnamen blijven gelijk.

- [ ] **Step 7: Lint + config-consistentie**

Run: `yamllint deploy/local/docker-compose.yaml`
Expected: exit 0.
Run: `grep -c 'example-consumer' deploy/local/docker-compose.yaml`
Expected: ≥ 20 (alle nieuwe services + aliases + cert-paden).

- [ ] **Step 8: Commit**

```bash
git add deploy/local/docker-compose.yaml
git commit -m "feat(local): example-consumer services (manager+outway+controller+DB) (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: HAProxy SNI-backend voor de consumer-mesh

**Files:**

- Modify: `deploy/local/haproxy.cfg`

**Interfaces:**

- Consumes: manager-service `manager-example-consumer:8443` (Task 5), SAN `example-consumer.fsc-test.local` (Task 1).
- Produces: SNI-route `example-consumer.fsc-test.local` → consumer-manager op `:443` (passthrough). De outway is client → geen inbound-route nodig.

- [ ] **Step 1: Lees de bestaande config om het SNI-patroon exact te matchen**

Run: `cat deploy/local/haproxy.cfg`
Expected: een `frontend` met `tcp-request ... ssl_fc_sni` mappings en `use_backend`-regels + `backend`-blokken per peer (o.a. `directory`, `example-provider`). Neem exact dezelfde stijl over.

- [ ] **Step 2: Voeg de SNI-match + backend toe** (spiegel het `example-provider`-blok; pas hostnaam en upstream aan)

Voeg in het frontend een `use_backend`-regel toe naar analogie van de provider:

```haproxy
    use_backend be_example_consumer if { req.ssl_sni -i example-consumer.fsc-test.local }
```

En het backend-blok (naar analogie van `be_example_provider`, maar naar de consumer-manager):

```haproxy
backend be_example_consumer
    mode tcp
    server s1 manager-example-consumer:8443
```

> Match de exacte directive-namen/ACL-stijl van het bestaande provider-blok (bv. `req.ssl_sni` vs `ssl_fc_sni`, backend-naamconventie). Kopieer het provider-blok en vervang `provider`→`consumer` + upstream.

- [ ] **Step 3: Sanity-check de config-structuur**

Run: `grep -n 'example-consumer\|be_example_consumer' deploy/local/haproxy.cfg`
Expected: minstens de nieuwe `use_backend`-ACL + het `backend`-blok.

- [ ] **Step 4: Commit**

```bash
git add deploy/local/haproxy.cfg
git commit -m "feat(local): HAProxy SNI-route voor example-consumer-mesh (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Smoke-script `smoke-discover.sh`

**Files:**

- Create: `deploy/local/smoke-discover.sh`

**Interfaces:**

- Consumes: draaiende compose (kern + provider gepubliceerd + consumer), directory-DB `fsc_directory`, consumer-OIN `00000000000000000020`, service-naam `example-service`.
- Produces: exit 0 = announce + discovery groen; exit 1 met stderr op FAIL.

- [ ] **Step 1: Lees `smoke-announce.sh` en `smoke-publish.sh` voor het exacte poll-/psql-patroon**

Run: `cat deploy/local/smoke-announce.sh deploy/local/smoke-publish.sh`
Expected: `COMPOSE=(docker compose -f ...)`, poll-loop met timeout, `"${COMPOSE[@]}" exec -T postgres psql -U postgres -d fsc_directory -tA -c "..."`, FAIL-pad met stderr. Hergebruik exact deze vorm.

- [ ] **Step 2: Schrijf het script**

```bash
#!/usr/bin/env bash
# Copyright © MOZa FSC Testnet — Licensed under the EUPL
# Smoke (#725): bewijst dat example-consumer (a) zich heeft aangemeld bij de directory
# (announce -> peers.peers) en (b) de gepubliceerde example-service kan vinden (discovery).
# Vereist dat de provider eerst publiceerde (publish-service.sh). Spiegelt smoke-announce/publish.sh.
set -uo pipefail

HERE="$(dirname "$0")"
COMPOSE=(docker compose -f "${HERE}/docker-compose.yaml")
CONSUMER_OIN="00000000000000000020"
SERVICE_NAME="example-service"
TIMEOUT="${TIMEOUT:-60}"

q() { "${COMPOSE[@]}" exec -T postgres psql -U postgres -d fsc_directory -tA -c "$1" 2>/tmp/smoke-discover.err; }

# Positief-controle: is de directory-DB überhaupt bereikbaar en gevuld?
if ! q "SELECT 1 FROM peers LIMIT 1;" >/dev/null; then
  echo "FAIL: directory-DB niet bevraagbaar: $(tail -n1 /tmp/smoke-discover.err)" >&2
  exit 1
fi

# 1. Announce: consumer-OIN staat in peers.peers.
echo "smoke-discover: wacht op announce van ${CONSUMER_OIN}..."
deadline=$((SECONDS + TIMEOUT))
until [ "$(q "SELECT count(*) FROM peers WHERE id = '${CONSUMER_OIN}';")" = "1" ]; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "FAIL: example-consumer (${CONSUMER_OIN}) niet aangemeld binnen ${TIMEOUT}s." >&2
    echo "  laatste psql-fout: $(tail -n1 /tmp/smoke-discover.err)" >&2
    exit 1
  fi
  sleep 2
done
echo "OK: announce (${CONSUMER_OIN} in peers.peers)."

# 2. Discovery: example-service staat in de directory-catalogus.
echo "smoke-discover: wacht op discovery van ${SERVICE_NAME}..."
deadline=$((SECONDS + TIMEOUT))
until [ "$(q "SELECT count(*) FROM services WHERE name = '${SERVICE_NAME}';")" -ge "1" ] 2>/dev/null; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "FAIL: ${SERVICE_NAME} niet vindbaar in de directory binnen ${TIMEOUT}s (provider gepubliceerd?)." >&2
    echo "  laatste psql-fout: $(tail -n1 /tmp/smoke-discover.err)" >&2
    exit 1
  fi
  sleep 2
done
echo "OK: discovery (${SERVICE_NAME} vindbaar in de directory)."
echo "SMOKE-DISCOVER GROEN."
```

> **Verifieer bij eerste host-run:** de exacte tabel-/kolomnamen (`peers.id`, `services.name`) tegen het directory-DB-schema. `smoke-announce.sh`/`smoke-publish.sh` gebruiken al de juiste namen — neem die exact over als ze afwijken.

- [ ] **Step 3: Maak uitvoerbaar + syntax-check**

Run: `chmod +x deploy/local/smoke-discover.sh && bash -n deploy/local/smoke-discover.sh && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add deploy/local/smoke-discover.sh
git commit -m "feat(local): smoke-discover — consumer announce + service-discovery (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Documentatie

**Files:**

- Modify: `deploy/local/README.md`
- Modify: `docs/topologie.md` (alleen als de consumer-kant nog FBS-namen bevat)

**Interfaces:**

- Consumes: alle voorgaande tasks (namen, poorten, smoke-volgorde).
- Produces: bijgewerkte lokale-harness-uitleg.

- [ ] **Step 1: Lees de relevante README-secties**

Run: `sed -n '1,120p' deploy/local/README.md`
Expected: secties over compose-up, smoke-announce/publish, controller-UI-poort (`8090`).

- [ ] **Step 2: Werk de README bij**
- Noem `example-consumer` (manager+outway+controller+DB) naast de provider.
- Consumer-controller-UI op `http://localhost:8091` (naast provider `8090`).
- Smoke-volgorde documenteren: `docker compose up -d` → `bash publish-service.sh` (provider) → `bash smoke-discover.sh` (consumer).
- Benoem de service-rename `controller` → `controller-example-provider`.

- [ ] **Step 3: Check `docs/topologie.md` op FBS-restanten aan de consumer-kant**

Run: `grep -niE 'uitvraag-org|berichtenuitvraag|magazijn' docs/topologie.md`
Expected: als er treffers zijn die de consumer-kant hardcoden, vervang door `example-consumer`/generiek. Geen treffer = geen wijziging.

- [ ] **Step 4: Lint**

Run: `yamllint deploy/local/*.yaml >/dev/null && echo "yaml OK"` (markdownlint niet lokaal — CI dekt markdown)
Expected: `yaml OK`.

- [ ] **Step 5: Commit**

```bash
git add deploy/local/README.md docs/topologie.md
git commit -m "docs(local): example-consumer + smoke-discover in README (#725)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Host-side acceptatie-smoke (handmatig, docker-host)

**Files:** geen (verificatie-only).

Deze task draait op de docker-host (lokaal geen `docker`). Levert het end-to-end-bewijs voor de #725-acceptatiecriteria.

- [ ] **Step 1: Regenereer certs host-side** (checkout is volume-mounted; keys blijven host-side)

Run: `bash pki/issue.sh && bash pki/verify.sh`
Expected: `exit 0`, example-consumer-certs groen.

- [ ] **Step 2: Breng de stack op**

Run: `cd deploy/local && docker compose up -d`
Expected: alle services healthy; `manager-example-consumer`, `outway-example-consumer`, `controller-example-consumer` `Up`.

- [ ] **Step 2b: Anti-waste-guard — geen crash-loop (R3 digital-waste)**

De outway boot in #725 zonder contract; als hij daarop crasht, herstart-loopt hij eindeloos
(`restart: on-failure`) → verspilde CPU + log-spam. Assert dat niets in een restart-loop zit:

Run (wacht ~30s na `up`): `docker compose ps --format '{{.Name}} {{.State}} {{.Status}}' | grep -iE 'restart|exited' && echo "LOOP GEVONDEN" || echo "geen restart-loop — OK"`
Expected: `geen restart-loop — OK`. Zo niet: `docker compose logs outway-example-consumer` en de
outway-env corrigeren (zie Task 5 verify-noot) i.p.v. de crash-loop te laten draaien.

- [ ] **Step 3: Publiceer de provider-dienst**

Run: `bash deploy/local/publish-service.sh`
Expected: `example-service` aangemaakt + gepubliceerd (bestaande #724-flow).

- [ ] **Step 4: Draai de consumer-smoke**

Run: `bash deploy/local/smoke-discover.sh`
Expected: `OK: announce ...`, `OK: discovery ...`, `SMOKE-DISCOVER GROEN.`, exit 0.

- [ ] **Step 5: Regressie — provider-smokes nog groen**

Run: `bash deploy/local/smoke-announce.sh && bash deploy/local/smoke-publish.sh`
Expected: beide groen (controller-rename brak niets).

---

## Self-Review (uitgevoerd)

**Spec-dekking:** boot → Task 5; announce → Task 5 + smoke Task 7; discovery → Task 7; PKI → Task 1; peer-template → Task 2; DB's → Task 3; compose+rename → Task 4/5; HAProxy → Task 6; docs → Task 8; host-acceptatie → Task 9. Alle spec-secties gedekt.

**Placeholder-scan:** twee bewust-geflagde "verifieer bij host-run"-punten (outway-env-namen, directory-DB-schema) met concrete werkhypothese + exact fallback-commando — geen kale TODO's.

**Type-consistentie:** service-keys, cert-paden, hostnamen en OIN `00000000000000000020` consistent tussen Task 1/5/6/7. Anchor-namen (`*ec-grp`, `*ec-int`) uniek t.o.v. de provider (`*ep-*`).
