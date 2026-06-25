# Centrale directory + federatiegroep (#723) — Implementatieplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lever de directory+group als (A) productieklare ZAD-deploy-artefacten en (B) een runnable lokale docker-compose harness die aantoont dat een peer zich bij de directory aanmeldt (announce) — beide losgekoppeld van de ZAD `attachments`-blocker.

**Architecture:** "directory" = een OpenFSC-manager in directory-mode (`DIRECTORY_PEER_ID` = eigen OIN, lege `TX_LOG_API_ADDRESS`). Managers meshen op **:443 via een SNI-passthrough-router** (HAProxy `mode tcp` lokaal ≙ OpenShift-`passthrough`-Route op ZAD) — geen 8443/MetalLB. De harness bouwt voort op de bewezen spike `docs/spikes/manager-443-sni/`. ZAD-migratie (geen args/init-containers toegestaan) wordt omzeild met een dunne wrapper-image (`migrate up && serve`).

**Tech Stack:** Docker Compose v2, HAProxy 2.9 (`mode tcp`), PostgreSQL 17, OpenFSC-images (`docker.io/federatedserviceconnectivity/{manager,directory-ui,controller}`, `registry.gitlab.com/rinis-oss/fsc/images/keycloak`), cfssl test-CA (#722), GitHub Actions + `RijksICTGilde/zad-actions/deploy`, Bash + `psql` voor de smoke-assert.

## Global Constraints

- **Taal:** docs/comments in het Nederlands; FSC-idiomen niet vertalen (inway, outway, manager, directory, peer, grant, announce).
- **Secrets nooit committen.** Keys/certs/`.env` blijven gitignored; alleen scripts + `.example`-templates in git.
- **Image-tag gepind:** `IMAGE_TAG=v1.43.7` (de tag waarmee de spike runtime-groen draaide). Eén plek (`.env.example`), overal via variabele.
- **Geen CLI-args op ZAD:** ZAD-componenten configureren via env-vars + gemounte files; nooit via component-args. (Lokaal in compose mág `command:`.)
- **Group-id:** `moza-fbs-test`. **OINs (#722):** directory `00000000000000000010`, magazijn-a `00000001003214345000`.
- **Env-var-namen letterlijk uit OpenFSC** (`open-fsc/helm/charts/open-fsc-manager/templates/deployment.yaml`), niet verzinnen.
- **Git:** feature-branch `feature/directory-group-723`, geen directe push naar `main`. Commit-trailer `Co-Authored-By` voor AI-bijdragen.
- **PREREQUISITE (#722):** de harness draait pas groen nadat #722 (PR #5) de extra manager-certs levert — minimaal een **internal CA + internal manager-cert per peer** (token/contract mogen de group-identity-cert hergebruiken, zoals de spike doet). Zie de cert-contract-tabel in Taak 5. Tot die tijd zijn alle artefacten te bouwen + te linten; alleen de end-to-end `compose up`+smoke is gated.

## Bestandsstructuur

```text
deploy/local/docker-compose.yaml      harness: postgres + router + directory + magazijn-a (+ UIs in fase C)
deploy/local/haproxy.cfg              SNI-passthrough router op :443
deploy/local/postgres-init.sql        maakt per-peer databases
deploy/local/.env.example             IMAGE_TAG + PKI_DIR
deploy/local/smoke-announce.sh        compose up -> poll directory-DB -> assert announce -> exit 0
deploy/local/README.md                run-instructies + prerequisite #722
deploy/zad/manager-migrate/Dockerfile wrapper-image (migrate up && serve)
deploy/zad/manager-migrate/entrypoint.sh
peers/directory/values.example.yaml   directory-mode manager-config (echte env-namen)
peers/directory/manager.env.example   per-component env-template
group/group-config.example.yaml       finalize (group-id + trust-anchor + TLS-min)
.github/workflows/deploy.yml          + directory-job (zad-actions/deploy)
docs/zad-projecten.md                 migratie + 443-mesh open-punten sluiten
docs/ontwerpkeuzes.md                 wrapper-image-rationale + 443-mesh
CLAUDE.md                             kernbeslissing 8443->443 + wrapper-image
```

Drie fasen, elk een onafhankelijk testbare deliverable:

- **Fase A (ZAD-prep):** Taken 1–4. Volledig te bouwen + linten zónder Docker of #722.
- **Fase B (announce-harness, criterium 3):** Taken 5–8. End-to-end groen gated op #722.
- **Fase C (volledige directory-stack):** Taken 9–11. directory-ui + keycloak + controller.

---

### Taak 1: Group-config finaliseren

**Files:**
- Modify: `group/group-config.example.yaml`

**Interfaces:**
- Produces: het group-id `moza-fbs-test` + trust-anchor-paden die fase B als `GROUP_ID`-env en cert-mounts consumeert.

- [ ] **Stap 1: Schrijf de group-config**

```yaml
# Group-configuratie (#723). Vul in en bewaar de echte versie buiten git.
# group_id wordt op elke manager gezet als GROUP_ID-env (zie deploy/local + peers/directory).
group:
  id: moza-fbs-test            # group_id; identificeert de federatie. == GROUP_ID-env op alle managers.
  trust_anchor:
    # test-CA root (via ZAD attachments gemount, lokaal bind-mount). GEEN PKIoverheid (#720).
    ca_cert: /etc/fsc/ca/root.pem            # -> TLS_GROUP_ROOT_CERT
    crl: /etc/fsc/ca/intermediate.crl        # CRL, intermediate als issuer
  rules:
    tls_min_version: "1.2"     # NCSC TLS 2.1 / OpenFSC-default
```

- [ ] **Stap 2: Lint**

Run: `yamllint group/group-config.example.yaml`
Expected: geen errors (exit 0).

- [ ] **Stap 3: Commit**

```bash
git add group/group-config.example.yaml
git commit -m "feat(group): group-config finaliseren (id + trust-anchor + TLS-min) (#723)"
```

---

### Taak 2: Wrapper-image voor ZAD-migratie

**Files:**
- Create: `deploy/zad/manager-migrate/Dockerfile`
- Create: `deploy/zad/manager-migrate/entrypoint.sh`

**Interfaces:**
- Produces: image `manager-migrate` met entrypoint dat `manager migrate up` draait en daarna `manager serve` exec't — ZAD-compatibel zonder args/init-container. Fase A Taak 4 (deploy.yml) verwijst ernaar als manager-image.

**Context:** ZAD staat geen component-args/init-containers toe; de OpenFSC-manager migreert alleen via het `migrate up`-subcommando. Deze dunne laag bakt "migreren-dan-serven" in de image. Het is een *deploy-image* boven de stock-image, geen broncode-fork.

- [ ] **Stap 1: Schrijf het entrypoint-script**

```bash
#!/bin/sh
# Wrapper-entrypoint: migreer de DB, start dan de manager. ZAD verbiedt args/
# init-containers, dus dit gebeurt in de image i.p.v. een init-container.
# STORAGE_POSTGRES_DSN (of POSTGRES_DSN) komt uit de env (gezet in Operations Manager).
set -eu

DSN="${STORAGE_POSTGRES_DSN:-${POSTGRES_DSN:-}}"
if [ -z "$DSN" ]; then
  echo "FATAL: STORAGE_POSTGRES_DSN (of POSTGRES_DSN) niet gezet" >&2
  exit 1
fi

echo "manager-migrate: migraties draaien..."
/usr/local/bin/manager migrate up --postgres-dsn "$DSN"

echo "manager-migrate: serve starten..."
exec /usr/local/bin/manager serve
```

- [ ] **Stap 2: Schrijf de Dockerfile**

```dockerfile
# Dunne wrapper boven de stock OpenFSC-manager: migreer-dan-serve in één image,
# zodat ZAD (geen args/init-containers) toch kan migreren. Geen broncode-fork.
ARG IMAGE_TAG=v1.43.7
FROM docker.io/federatedserviceconnectivity/manager:${IMAGE_TAG}
COPY entrypoint.sh /usr/local/bin/migrate-and-serve.sh
# Stock-image draait als non-root; entrypoint moet leesbaar+executable zijn.
USER root
RUN chmod 0555 /usr/local/bin/migrate-and-serve.sh
USER 1000
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
```

- [ ] **Stap 3: Validatie (build-syntax, geen push)**

Run: `hadolint deploy/zad/manager-migrate/Dockerfile || dockerfilelint deploy/zad/manager-migrate/Dockerfile || echo "linter niet beschikbaar — handmatig review"`
Expected: geen blocking errors. (Een echte `docker build` vereist een Docker-host + pull-toegang tot de stock-image; bouwen/pushen hoort bij #729-CI.)

Run: `shellcheck deploy/zad/manager-migrate/entrypoint.sh`
Expected: exit 0.

- [ ] **Stap 4: Commit**

```bash
git add deploy/zad/manager-migrate/
git commit -m "feat(zad): wrapper-image manager-migrate (migrate up && serve) (#723)"
```

---

### Taak 3: Env-template directory-manager (ZAD)

**Files:**
- Modify: `peers/directory/values.example.yaml`
- Create: `peers/directory/manager.env.example`

**Interfaces:**
- Consumes: env-namen uit `open-fsc/helm/charts/open-fsc-manager/templates/deployment.yaml`.
- Produces: de directory-mode env-set die in Operations Manager wordt ingevoerd en die de harness (Taak 6) spiegelt.

- [ ] **Stap 1: Herschrijf `peers/directory/values.example.yaml`**

```yaml
# Directory-peer = OpenFSC-manager in DIRECTORY-MODE (geen apart image).
# Directory-mode = DIRECTORY_PEER_ID == eigen OIN + lege TX_LOG_API_ADDRESS.
# Echte env-namen: open-fsc/helm/charts/open-fsc-manager/templates/deployment.yaml.
peer:
  oin: "00000000000000000010"        # synthetische infra-OIN -> Peer ID (directory)
  name: "directory"                  # -> subject.organization in het cert
manager:
  # Mesh-endpoint op :443 (SNI-passthrough-Route), NIET 8443/MetalLB (#723-spike).
  selfAddress: "https://directory.fsc-test.local:443"   # -> SELF_ADDRESS
  directoryMode: true                # DIRECTORY_PEER_ID == peer.oin; TX_LOG_API_ADDRESS leeg
  image: "manager-migrate"           # wrapper-image (Taak 2), niet de stock-image
# Echte env in peers/directory/manager.env.example. Secrets/certs via ZAD attachments.
```

- [ ] **Stap 2: Schrijf `peers/directory/manager.env.example`**

```bash
# Env-template directory-manager (DIRECTORY-MODE). Invoeren in ZAD Operations Manager.
# Namen letterlijk uit open-fsc/helm/charts/open-fsc-manager/templates/deployment.yaml.
# Waarden hier = ZAD; de lokale harness (deploy/local) gebruikt dezelfde NAMEN, andere adressen.
LOG_TYPE=live
LOG_LEVEL=info
GROUP_ID=moza-fbs-test
# Directory-mode: eigen OIN als directory-peer, geen txlog.
DIRECTORY_PEER_ID=00000000000000000010
DIRECTORY_MANAGER_ADDRESS=https://directory.fsc-test.local:443
TX_LOG_API_ADDRESS=
SELF_ADDRESS=https://directory.fsc-test.local:443
AUTO_SIGN_GRANTS=servicePublication,delegatedServicePublication
AUDITLOG_TYPE=stdout
# Listen-poorten (intern in de pod; mesh-endpoint extern via Route op :443).
LISTEN_ADDRESS_EXTERNAL=0.0.0.0:8443
LISTEN_ADDRESS_INTERNAL=0.0.0.0:9443
LISTEN_ADDRESS_INTERNAL_UNAUTHENTICATED=0.0.0.0:9444
MONITORING_ADDRESS=0.0.0.0:8080
# Database (wrapper-image migreert bij boot).
STORAGE_POSTGRES_DSN=postgres://fsc:CHANGEME@directory-postgres:5432/fsc_directory?sslmode=require
# Certs (gemount via ZAD attachments; paden == lokale harness).
TLS_GROUP_ROOT_CERT=/etc/fsc/ca/root.pem
TLS_GROUP_CERT=/etc/fsc/certs/directory/group/cert.pem
TLS_GROUP_KEY=/etc/fsc/certs/directory/group/key.pem
TLS_GROUP_TOKEN_CERT=/etc/fsc/certs/directory/group/cert.pem
TLS_GROUP_TOKEN_KEY=/etc/fsc/certs/directory/group/key.pem
TLS_GROUP_CONTRACT_CERT=/etc/fsc/certs/directory/group/cert.pem
TLS_GROUP_CONTRACT_KEY=/etc/fsc/certs/directory/group/key.pem
TLS_ROOT_CERT=/etc/fsc/ca/internal-root.pem
TLS_CERT=/etc/fsc/certs/directory/internal/cert.pem
TLS_KEY=/etc/fsc/certs/directory/internal/key.pem
TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT=/etc/fsc/ca/internal-root.pem
TLS_INTERNAL_UNAUTHENTICATED_CERT=/etc/fsc/certs/directory/internal/cert.pem
TLS_INTERNAL_UNAUTHENTICATED_KEY=/etc/fsc/certs/directory/internal/key.pem
```

- [ ] **Stap 3: Lint**

Run: `yamllint peers/directory/values.example.yaml`
Expected: exit 0.

- [ ] **Stap 4: Commit**

```bash
git add peers/directory/
git commit -m "feat(directory): env-template directory-mode manager (echte OpenFSC-namen) (#723)"
```

---

### Taak 4: Deploy-workflow directory-job

**Files:**
- Modify: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: secret `ZAD_API_KEY_DIRECTORY`, var `ZAD_PROJECT_ID_DIRECTORY`, wrapper-image (Taak 2).
- Produces: een `workflow_dispatch`-job die `zad-actions/deploy` aanroept met de directory-componentlijst.

**DB-duurzaamheid (#723-comment 2026-06-24):** `directory-postgres` is system-of-record →
op ZAD **persistent + gebackupt, niet `clone-from: test`-cloned**. Niet via deze workflow
afdwingbaar (ZAD-Operations-Manager-instelling) → beleggen bij ZAD-beheer; gedocumenteerd
in `docs/zad-projecten.md` + `docs/ontwerpkeuzes.md`.

- [ ] **Stap 1: Vervang de placeholder-job door de directory-job**

```yaml
# ZAD deploy (#723/#729). workflow_dispatch zodat het niet auto-draait.
name: deploy-fsc-testnet
on:
  workflow_dispatch:

permissions: {}

jobs:
  directory:
    runs-on: ubuntu-latest
    # NB: deze deploy slaagt pas zodra ZAD `attachments` (cert-mount) beschikbaar
    # is; tot die tijd is dit het bron-artefact, niet een groene run (#723).
    steps:
      - name: Deploy directory (group-anker) naar ZAD
        # SHA-pin conform repo-conventie; vervang door de gepinde SHA bij merge.
        uses: RijksICTGilde/zad-actions/deploy@v1
        with:
          api-key: ${{ secrets.ZAD_API_KEY_DIRECTORY }}
          project-id: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
          deployment-name: directory
          components: >-
            [
              {"name":"directory-postgres","image":"postgres:17"},
              {"name":"directory-manager","image":"ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:v1.43.7"},
              {"name":"directory-ui","image":"docker.io/federatedserviceconnectivity/directory-ui:v1.43.7"}
            ]
```

- [ ] **Stap 2: Lint de workflow**

Run: `actionlint .github/workflows/deploy.yml`
Expected: exit 0 (geen syntax/permission-fouten).

- [ ] **Stap 3: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(ci): directory-job in deploy.yml (zad-actions/deploy) (#723)"
```

---

### Taak 5: Cert-contract + harness-prerequisites documenteren

**Files:**
- Modify: `deploy/local/README.md` (aanmaken in deze taak)

**Interfaces:**
- Produces: de exacte cert-paden + hostnames die #722 moet leveren, zodat Taak 6–8 daar tegenaan kunnen bouwen.

- [ ] **Stap 1: Schrijf `deploy/local/README.md`**

````markdown
# Lokale harness (#723) — directory + announce-proof

Runnable shift-left van de ZAD-deploy: directory + magazijn-a-peer + SNI-router op
:443. Bewijst dat een peer zich aanmeldt (announce) bij de directory. Bouwt voort op
`docs/spikes/manager-443-sni/`.

## Prerequisite (#722) — cert-contract

De harness mount onze test-CA read-only. #722 (PR #5) moet deze leveren onder `pki/`:

| Pad | Doel | Env |
|-----|------|-----|
| `pki/ca/root.pem` | group-CA root (bestaat) | `TLS_GROUP_ROOT_CERT` |
| `pki/ca/internal-root.pem` | internal-CA root (#722 toe te voegen) | `TLS_ROOT_CERT`, `TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT` |
| `pki/out/<peer>/group/{cert,key}.pem` | group-identity (hergebruikt voor token+contract) | `TLS_GROUP_CERT/KEY`, `TLS_GROUP_TOKEN_*`, `TLS_GROUP_CONTRACT_*` |
| `pki/out/<peer>/internal/{cert,key}.pem` | internal mTLS (#722 toe te voegen) | `TLS_CERT/KEY`, `TLS_INTERNAL_UNAUTHENTICATED_*` |

`<peer>` ∈ {`directory`, `magazijn-a`}. Hostnames in de certs: `directory.fsc-test.local`,
`magazijn-a.fsc-test.local`. De mesh verifieert de hostname niet (auth op OIN), maar
houd ze consistent met `SELF_ADDRESS`/SNI.

> Token+contract hergebruiken de group-identity-cert (zoals de spike). Wil #722 ze
> als losse certs uitgeven, splits dan de env-paden navenant.

## Draaien

```bash
cp deploy/local/.env.example deploy/local/.env   # IMAGE_TAG staat al goed
# zorg dat #722 de certs onder pki/ heeft gegenereerd (./pki/issue.sh -f)
docker compose -f deploy/local/docker-compose.yaml up -d
./deploy/local/smoke-announce.sh                 # exit 0 = announce bewezen
```

## Opruimen

```bash
docker compose -f deploy/local/docker-compose.yaml down -v
```
````

- [ ] **Stap 2: Lint**

Run: `markdownlint deploy/local/README.md`
Expected: exit 0.

- [ ] **Stap 3: Commit**

```bash
git add deploy/local/README.md
git commit -m "docs(local): cert-contract + run-instructies harness (#723)"
```

---

### Taak 6: Harness — router, postgres, migraties, directory-manager

**Files:**
- Create: `deploy/local/.env.example`
- Create: `deploy/local/postgres-init.sql`
- Create: `deploy/local/haproxy.cfg`
- Create: `deploy/local/docker-compose.yaml`

**Interfaces:**
- Consumes: certs onder `pki/` (Taak 5-contract), group-config (Taak 1).
- Produces: een compose-stack waarin de directory-manager op :443 luistert via de router. Taak 7 voegt de peer toe; Taak 8 de smoke-assert.

- [ ] **Stap 1: Schrijf `deploy/local/.env.example`**

```bash
# Kopieer naar deploy/local/.env (gitignored).
IMAGE_TAG=v1.43.7
# Pad naar onze test-CA-output (#722). Read-only gemount op /pki in de containers.
PKI_DIR=../../pki
```

- [ ] **Stap 2: Schrijf `deploy/local/postgres-init.sql`**

```sql
-- Eén postgres, één database per peer (spiegelt OpenFSC's per-peer-DB-isolatie).
CREATE DATABASE fsc_directory;
CREATE DATABASE fsc_magazijn_a;
```

- [ ] **Stap 3: Schrijf `deploy/local/haproxy.cfg`**

```haproxy
# SNI-passthrough router op :443 (mode tcp = geen TLS-terminatie), ≙ OpenShift-
# passthrough-Route. Routeert op SNI-hostnaam naar de juiste manager-external-poort.
global
    log stdout format raw local0
defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend https_sni
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    use_backend dir  if { req_ssl_sni -i directory.fsc-test.local }
    use_backend maga if { req_ssl_sni -i magazijn-a.fsc-test.local }

backend dir
    server s1 manager-directory:8443
backend maga
    server s1 manager-magazijn-a:8443
```

- [ ] **Stap 4: Schrijf `deploy/local/docker-compose.yaml` (directory + infra)**

```yaml
# Lokale harness (#723). Zie deploy/local/README.md voor het cert-contract (#722).
x-manager-image: &manager-image docker.io/federatedserviceconnectivity/manager:${IMAGE_TAG:-v1.43.7}
x-manager-common-env: &manager-common-env
  LOG_TYPE: local
  LOG_LEVEL: debug
  GROUP_ID: moza-fbs-test
  DIRECTORY_PEER_ID: "00000000000000000010"
  DIRECTORY_MANAGER_ADDRESS: https://directory.fsc-test.local:443
  AUDITLOG_TYPE: stdout
  DISABLE_CRL_CHECKS: "true"            # lokaal geen CRL-distributiepunt (zie README)
  TLS_GROUP_ROOT_CERT: /pki/ca/root.pem

services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    volumes:
      - ./postgres-init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 3s
      timeout: 3s
      retries: 20

  router:
    image: haproxy:2.9
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      default:
        aliases:
          - directory.fsc-test.local
          - magazijn-a.fsc-test.local
    depends_on:
      manager-directory: { condition: service_started }

  migrate-directory:
    image: *manager-image
    command: ["/usr/local/bin/manager","migrate","up","--postgres-dsn","postgres://postgres:postgres@postgres:5432/fsc_directory?sslmode=disable"]
    depends_on: { postgres: { condition: service_healthy } }
    restart: on-failure

  manager-directory:
    image: *manager-image
    command: ["/usr/local/bin/manager","serve"]
    environment:
      <<: *manager-common-env
      SELF_ADDRESS: https://directory.fsc-test.local:443
      TX_LOG_API_ADDRESS: ""                 # directory-mode: geen txlog
      AUTO_SIGN_GRANTS: servicePublication,delegatedServicePublication
      LISTEN_ADDRESS_EXTERNAL: 0.0.0.0:8443
      LISTEN_ADDRESS_INTERNAL: 0.0.0.0:9443
      LISTEN_ADDRESS_INTERNAL_UNAUTHENTICATED: 0.0.0.0:9444
      MONITORING_ADDRESS: 0.0.0.0:8080
      STORAGE_POSTGRES_DSN: postgres://postgres:postgres@postgres:5432/fsc_directory?sslmode=disable
      TLS_GROUP_CERT: &dir-grp /pki/out/directory/group/cert.pem
      TLS_GROUP_KEY: &dir-grp-key /pki/out/directory/group/key.pem
      TLS_GROUP_TOKEN_CERT: *dir-grp
      TLS_GROUP_TOKEN_KEY: *dir-grp-key
      TLS_GROUP_CONTRACT_CERT: *dir-grp
      TLS_GROUP_CONTRACT_KEY: *dir-grp-key
      TLS_ROOT_CERT: /pki/ca/internal-root.pem
      TLS_CERT: &dir-int /pki/out/directory/internal/cert.pem
      TLS_KEY: &dir-int-key /pki/out/directory/internal/key.pem
      TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT: /pki/ca/internal-root.pem
      TLS_INTERNAL_UNAUTHENTICATED_CERT: *dir-int
      TLS_INTERNAL_UNAUTHENTICATED_KEY: *dir-int-key
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    depends_on:
      migrate-directory: { condition: service_completed_successfully }

networks:
  default:
    driver: bridge
```

- [ ] **Stap 5: Valideer compose-syntax**

Run: `cd deploy/local && cp .env.example .env && docker compose config >/dev/null && echo OK`
Expected: `OK` (compose parseert; vereist de compose-CLI, geen draaiende stack).
Run: `cd deploy/local && haproxy -c -f haproxy.cfg 2>/dev/null || echo "haproxy-CLI niet lokaal — config visueel reviewen"`

- [ ] **Stap 6: Commit**

```bash
git add deploy/local/.env.example deploy/local/postgres-init.sql deploy/local/haproxy.cfg deploy/local/docker-compose.yaml
git commit -m "feat(local): harness-basis — router + postgres + directory-manager op :443 (#723)"
```

---

### Taak 7: Harness — magazijn-a-peer (de announcer)

**Files:**
- Modify: `deploy/local/docker-compose.yaml`

**Interfaces:**
- Consumes: de directory-service (Taak 6).
- Produces: een peer-manager die bij startup announce't naar de directory; Taak 8 assert't dat.

**Context:** Niet-directory managers eisen een aanwezige `TX_LOG_API_ADDRESS` (presence-check `serve.go:236`), maar txlog wordt pas gedialed bij een echte data-transactie — niet bij announce. Daarom een **placeholder-adres**: voldoende voor de announce-proof (bewezen in de spike).

- [ ] **Stap 1: Voeg de migratie- en manager-service voor magazijn-a toe**

Voeg onder `services:` toe (vóór `networks:`):

```yaml
  migrate-magazijn-a:
    image: *manager-image
    command: ["/usr/local/bin/manager","migrate","up","--postgres-dsn","postgres://postgres:postgres@postgres:5432/fsc_magazijn_a?sslmode=disable"]
    depends_on: { postgres: { condition: service_healthy } }
    restart: on-failure

  manager-magazijn-a:
    image: *manager-image
    command: ["/usr/local/bin/manager","serve"]
    environment:
      <<: *manager-common-env
      SELF_ADDRESS: https://magazijn-a.fsc-test.local:443
      TX_LOG_API_ADDRESS: https://txlog.placeholder.invalid:7611  # presence-check; niet gedialed bij announce
      LISTEN_ADDRESS_EXTERNAL: 0.0.0.0:8443
      LISTEN_ADDRESS_INTERNAL: 0.0.0.0:9443
      LISTEN_ADDRESS_INTERNAL_UNAUTHENTICATED: 0.0.0.0:9444
      MONITORING_ADDRESS: 0.0.0.0:8080
      STORAGE_POSTGRES_DSN: postgres://postgres:postgres@postgres:5432/fsc_magazijn_a?sslmode=disable
      TLS_GROUP_CERT: &maga-grp /pki/out/magazijn-a/group/cert.pem
      TLS_GROUP_KEY: &maga-grp-key /pki/out/magazijn-a/group/key.pem
      TLS_GROUP_TOKEN_CERT: *maga-grp
      TLS_GROUP_TOKEN_KEY: *maga-grp-key
      TLS_GROUP_CONTRACT_CERT: *maga-grp
      TLS_GROUP_CONTRACT_KEY: *maga-grp-key
      TLS_ROOT_CERT: /pki/ca/internal-root.pem
      TLS_CERT: &maga-int /pki/out/magazijn-a/internal/cert.pem
      TLS_KEY: &maga-int-key /pki/out/magazijn-a/internal/key.pem
      TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT: /pki/ca/internal-root.pem
      TLS_INTERNAL_UNAUTHENTICATED_CERT: *maga-int
      TLS_INTERNAL_UNAUTHENTICATED_KEY: *maga-int-key
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    depends_on:
      migrate-magazijn-a: { condition: service_completed_successfully }
      manager-directory: { condition: service_started }
```

- [ ] **Stap 2: Voeg magazijn-a aan de router-aliases toe** (al gedekt in `haproxy.cfg` backend `maga`; bevestig de alias staat in `router.networks.default.aliases`).

- [ ] **Stap 3: Valideer compose-syntax**

Run: `cd deploy/local && docker compose config >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Stap 4: Commit**

```bash
git add deploy/local/docker-compose.yaml
git commit -m "feat(local): magazijn-a-peer als announcer (txlog-placeholder) (#723)"
```

---

### Taak 8: Smoke-test — announce aantoonbaar (criterium 3)

**Files:**
- Create: `deploy/local/smoke-announce.sh`

**Interfaces:**
- Consumes: de draaiende harness (Taak 6–7).
- Produces: exit 0 ⇔ magazijn-a-OIN staat als aangemeld in de directory-DB.

**Context:** De directory persisteert announce in `peers.peers` (spike-bewijs). De smoke pollt die tabel — cert-vrij, robuust. (Alternatief: `GET /v1/peers` op :9443, maar dat vergt een internal client-cert.)

- [ ] **Stap 1: Schrijf de failing test (script dat assert't, faalt zonder announce)**

```bash
#!/usr/bin/env bash
# Smoke: bewijst dat magazijn-a zich aanmeldt (announce) bij de directory.
# Pollt de directory-DB (peers.peers) tot de magazijn-a-OIN verschijnt.
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
MAGA_OIN="00000001003214345000"
DIR_OIN="00000000000000000010"
TIMEOUT=120
INTERVAL=5

echo "smoke: wachten tot magazijn-a ($MAGA_OIN) announce't bij de directory..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  rows=$("${COMPOSE[@]}" exec -T postgres \
    psql -U postgres -d fsc_directory -tA \
    -c "SELECT peer_id FROM peers.peers;" 2>/dev/null || true)
  if printf '%s\n' "$rows" | grep -qx "$MAGA_OIN"; then
    echo "OK: magazijn-a is aangemeld bij de directory."
    echo "Aangemelde peers:"
    "${COMPOSE[@]}" exec -T postgres \
      psql -U postgres -d fsc_directory \
      -c "SELECT peer_id, name, manager_address FROM peers.peers;"
    exit 0
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet aangemeld (${elapsed}s)"
done

echo "FAIL: magazijn-a ($MAGA_OIN) niet aangemeld binnen ${TIMEOUT}s." >&2
echo "Debug: directory-logs:" >&2
"${COMPOSE[@]}" logs --tail=50 manager-directory manager-magazijn-a >&2 || true
exit 1
```

- [ ] **Stap 2: Maak executable + shellcheck**

Run: `chmod +x deploy/local/smoke-announce.sh && shellcheck deploy/local/smoke-announce.sh`
Expected: exit 0.

- [ ] **Stap 3: Verifieer dat de assert faalt zónder draaiende stack**

Run: `(cd deploy/local && docker compose down -v 2>/dev/null; ./smoke-announce.sh; echo "exit=$?")`
Expected: eindigt met `FAIL` + `exit=1` (geen stack → geen announce). Dit bewijst dat de test echt iets meet.

- [ ] **Stap 4: Acceptatie (gated op #722-certs + Docker-host)**

Run:
```bash
cd deploy/local && cp -n .env.example .env
docker compose up -d
./smoke-announce.sh
```
Expected: `OK: magazijn-a is aangemeld` + de peers-tabel met manager_address op `:443`, exit 0.
> Slaagt alleen nadat #722 de certs onder `pki/` heeft geleverd (Taak 5-contract) en op een host met Docker. Tot dan: Stap 3 (faal-pad) is het bewijs dat de test werkt; noteer de gate in de PR-omschrijving.

- [ ] **Stap 5: Commit**

```bash
git add deploy/local/smoke-announce.sh
git commit -m "test(local): smoke-announce — peer-registratie in directory-DB (#723)"
```

---

### Taak 9: Fase C — directory-ui (visuele catalogus, geen keycloak)

**Files:**
- Modify: `deploy/local/docker-compose.yaml`

**Interfaces:**
- Consumes: de directory-manager external endpoint (:443 via router) + group-certs.
- Produces: een web-UI op `http://localhost:8080` die de aangemelde peers/diensten toont. **Geen keycloak nodig** (directory-ui heeft geen OIDC-env; `open-fsc/helm/charts/open-fsc-directory-ui/templates/deployment.yaml`).

- [ ] **Stap 1: Voeg de directory-ui-service toe**

```yaml
  directory-ui:
    image: docker.io/federatedserviceconnectivity/directory-ui:${IMAGE_TAG:-v1.43.7}
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      LOG_TYPE: local
      LOG_LEVEL: info
      LISTEN_ADDRESS: 0.0.0.0:8080
      MONITORING_ADDRESS: 0.0.0.0:8081
      # Externe directory-manager via de SNI-router op :443.
      DIRECTORY_MANAGER_ADDRESS: https://directory.fsc-test.local:443
      BASE_URL_PATH: /
      TLS_GROUP_ROOT_CERT: /pki/ca/root.pem
      TLS_GROUP_CERT: /pki/out/magazijn-a/group/cert.pem   # lezer-peer-identiteit
      TLS_GROUP_KEY: /pki/out/magazijn-a/group/key.pem
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    depends_on:
      manager-directory: { condition: service_started }
      router: { condition: service_started }
```

- [ ] **Stap 2: Valideer**

Run: `cd deploy/local && docker compose config >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Stap 3: Acceptatie (gated)** — na `compose up`: open `http://localhost:8080`, de aangemelde magazijn-a-peer is zichtbaar in de catalogus. (Gate: #722-certs + Docker.)

- [ ] **Stap 4: Commit**

```bash
git add deploy/local/docker-compose.yaml
git commit -m "feat(local): directory-ui (visuele catalogus, group-certs) (#723)"
```

---

### Taak 10: Fase C — keycloak + controller (beheer-UI met OIDC)

**Files:**
- Modify: `deploy/local/docker-compose.yaml`

**Interfaces:**
- Consumes: directory-manager internal endpoint (:9443, internal certs), keycloak-realm `open-fsc`.
- Produces: keycloak (baked realm `open-fsc`, client `open_fsc-controller`) + de controller-UI op `http://localhost:8090` met OIDC-login.

**Context:** De controller praat met de **interne** manager-API (:9443) met internal-certs én doet OIDC tegen keycloak. Het realm `open-fsc` + client `open_fsc-controller` zit in de custom keycloak-image gebakken (geen JSON-import). Lukt de OIDC-redirect lokaal niet (baked hostnames), zet dan `AUTHN_TYPE=none` (fallback; controller draait dan zonder login — zie `gemeente-stijns/values.yaml`).

- [ ] **Stap 1: Voeg keycloak toe**

```yaml
  keycloak:
    image: registry.gitlab.com/rinis-oss/fsc/images/keycloak:bfca938d
    command: start --optimized
    ports:
      - "127.0.0.1:8081:8080"
    environment:
      KC_BOOTSTRAP_ADMIN_USERNAME: keycloak-admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: keycloak
      KC_HOSTNAME: http://localhost:8081
      KC_HOSTNAME_ADMIN: http://localhost:8081
    restart: on-failure
```

- [ ] **Stap 2: Voeg de controller toe**

```yaml
  controller:
    image: docker.io/federatedserviceconnectivity/controller:${IMAGE_TAG:-v1.43.7}
    ports:
      - "127.0.0.1:8090:8080"
    environment:
      LOG_TYPE: local
      LOG_LEVEL: info
      LISTEN_ADDRESS_UI: 0.0.0.0:8080
      LISTEN_ADDRESS_REGISTRATION_API: 0.0.0.0:9443
      LISTEN_ADDRESS_ADMINISTRATION_API: 0.0.0.0:9444
      MONITORING_ADDRESS: 0.0.0.0:8081
      MANAGER_ADDRESS_INTERNAL: https://manager-magazijn-a:9443
      GROUP_ID: moza-fbs-test
      DIRECTORY_PEER_ID: "00000000000000000010"
      POSTGRES_HOST: postgres
      POSTGRES_PORT: "5432"
      POSTGRES_DATABASE: fsc_magazijn_a
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      PGSSLMODE: disable
      STORAGE_POSTGRES_DSN: postgres://postgres:postgres@postgres:5432/fsc_magazijn_a?sslmode=disable
      AUTHN_TYPE: oidc
      AUTHN_OIDC_CLIENT_ID: open_fsc-controller
      AUTHN_OIDC_CLIENT_SECRET: 99DbIk7FqlUYqbyD3qSX4Wmf
      AUTHN_OIDC_DISCOVERY_URL: http://keycloak:8080/realms/open-fsc/.well-known/openid-configuration
      AUTHN_OIDC_REDIRECT_URL: http://localhost:8090/authentication/callback
      AUTHN_OIDC_SESSION_COOKIE_SECURE: "false"
      AUTHN_OIDC_PKCE_ENABLED: "false"
      AUTHN_OIDC_INSECURE_SKIP_VERIFY_TLS: "true"
      AUTHN_OIDC_ROLES_SCOPE: groups
      AUTHN_OIDC_ROLES_CLAIM: groups
      AUTHZ_TYPE: rbac
      CSRF_PROTECTION_ENABLED: "false"
      AUDITLOG_TYPE: stdout
      TLS_ROOT_CERT: /pki/ca/internal-root.pem
      TLS_CERT: /pki/out/magazijn-a/internal/cert.pem
      TLS_KEY: /pki/out/magazijn-a/internal/key.pem
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    depends_on:
      keycloak: { condition: service_started }
      manager-magazijn-a: { condition: service_started }
```

- [ ] **Stap 3: Valideer**

Run: `cd deploy/local && docker compose config >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Stap 4: Acceptatie (gated)** — na `compose up`: `http://localhost:8090` toont de controller-login via keycloak. Faalt de redirect, zet `AUTHN_TYPE=none` en herstart (gedocumenteerd in README).

- [ ] **Stap 5: Documenteer de fallback + default-creds-waarschuwing in `deploy/local/README.md`** (keycloak-admin `keycloak-admin/keycloak`, controller `AUTHN_TYPE=none`-fallback).

- [ ] **Stap 6: Commit**

```bash
git add deploy/local/docker-compose.yaml deploy/local/README.md
git commit -m "feat(local): keycloak + controller (OIDC, AUTHN=none fallback) (#723)"
```

---

### Taak 11: Docs — open-punten sluiten + kernbeslissingen bijwerken

**Files:**
- Modify: `docs/zad-projecten.md`
- Modify: `docs/ontwerpkeuzes.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: de definitieve vastlegging van migratie-oplossing (wrapper-image), 443-mesh (8443/MetalLB vervalt) en Keycloak.

- [ ] **Stap 1: `docs/zad-projecten.md` — sluit de open-punten**

In de sectie "Open punten / blockers": vervang het DB-migratie-punt door de wrapper-image-oplossing (`deploy/zad/manager-migrate/`), en het 8443-IP-punt door de 443-mesh-conclusie (verwijs naar `docs/spikes/manager-443-sni.md`). Voeg toe dat directory = manager-in-directory-mode.

- [ ] **Stap 2: `docs/ontwerpkeuzes.md` — wrapper-image-rationale + 443-mesh + Keycloak**

Voeg een sectie toe: "Migratie op ZAD = wrapper-image" (waarom: geen args/init-containers; het is een deploy-image, geen fork). Werk de ZAD-sectie bij: manager-mesh op :443 via passthrough (8443/MetalLB vervalt). Noteer Keycloak als OIDC-provider (OpenFSC-default), niet Dex.

- [ ] **Stap 3: `CLAUDE.md` — kernbeslissingen**

In "ZAD / OpenShift": wijzig poort-8443-mesh naar 443-SNI-passthrough (8443/MetalLB niet meer nodig voor de mesh). In "Blocker #723": vervang "alternatief nodig" door "opgelost via wrapper-image `deploy/zad/manager-migrate/`".

- [ ] **Stap 4: Lint**

Run: `markdownlint docs/zad-projecten.md docs/ontwerpkeuzes.md CLAUDE.md`
Expected: exit 0.

- [ ] **Stap 5: Commit**

```bash
git add docs/zad-projecten.md docs/ontwerpkeuzes.md CLAUDE.md
git commit -m "docs(directory): migratie+443-mesh+keycloak vastleggen (#723)"
```

---

## Self-Review (uitgevoerd)

**Spec-dekking:** §4 componenten → Taken 3,6,7,9,10. §5 migratie → Taak 2. §6 PKI-dependency → Taak 5 (contract) + prerequisite. §7 harness → Taken 5–8. §8 ZAD-prep → Taken 3,4. §9 group-config → Taak 1. §10 testing → Taak 8. §2 correcties (Keycloak/443) → Taken 10,11. Alle secties gedekt.

**Placeholder-scan:** Geen TBD/TODO in stappen; elk config-bestand staat volledig uitgeschreven. De `txlog.placeholder.invalid` is een bewuste, gegronde waarde (spike), geen plan-placeholder.

**Type-consistentie:** OINs (`00000000000000000010` directory, `00000001003214345000` magazijn-a), hostnames (`directory.fsc-test.local`, `magazijn-a.fsc-test.local`), cert-paden (`/pki/out/<peer>/{group,internal}/…`, `/pki/ca/{root,internal-root}.pem`) en `GROUP_ID=moza-fbs-test` zijn over alle taken identiek. Env-namen consistent met de manager-chart.

**Bekende gate:** Fase B/C end-to-end-acceptatie hangt op #722-certs + een Docker-host; elke gated stap is als zodanig gemarkeerd, met het faal-pad (Taak 8 stap 3) als bewijs-nu dat de test meet.
