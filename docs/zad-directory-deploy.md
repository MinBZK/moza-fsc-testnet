# Runbook: directory live op ZAD (#723)

> Doel: de centrale **directory** (group-anker) draaiend krijgen op ZAD-project `mft-tp9`, zodat
> peers kunnen announcen. Gegrond op `docs/spikes/zad-attachments.md` (cert-mount-ontwerp A) en de
> ZAD Operations Manager API (`https://zad.rijksapp.nl/openapi.json`, v2).
>
> **Status (2026-06-30): directory LIVE op ZAD**, deployment `test` — de deployment waar `main`
> naartoe rolt en waar previews (`pr-<PR-nummer>`) van klonen. `migrate up` ok tegen de
> managed Postgres, manager serveert, **self-announce geslaagd** (`EVENT_TYPE_CREATE_PEER`, OIN
> `00000000000000000010`, SUCCEEDED). Cert-mount (ontwerp A) + managed DB bewezen op ODCN-prod.
>
> **Managed PostgreSQL (toegepast):** we draaien GEEN eigen `postgres:17`-component; we gebruiken
> ZAD's managed Postgres (`postgresql-database`-service) voor betere resource-pooling. De manager
> krijgt de service + bouwt `STORAGE_POSTGRES_DSN` uit de connection-substitutievars
> (`$DATABASE_SERVER_USER`/`$DATABASE_PASSWORD`/`$DATABASE_SERVER_HOST`/`$DATABASE_DB`, poort 5432),
> via een `aliases`-regel — zie de Operations Manager UI (project `mft-tp9`) en
> `peers/directory/manager.env.example`.

## Taakverdeling: CI vs UI

- **Via CI (`zad-deploy-directory.yml` → `RijksICTGilde/zad-actions/deploy`):** het deployment en
  per component het draaiende **image**. Meer niet.
- **In de Operations Manager UI, op projectniveau:** `env_vars`, `aliases`, `services`
  (managed Postgres), **bijlagen** (cert-mount, ontwerp A) en **"Publicatie op het web"**
  (passthrough-TLS, modus 2). Die config geldt voor **alle** deployments doordat ze
  deploy-variabelen gebruikt (`$DEPLOYMENT_NAME`, `$DATABASE_*`) — een nieuw `pr-<n>` erft 'm dus
  zonder handwerk.

> Git dwingt de env **niet** af: `peers/directory/manager.env.example` (dirmgr) en
> `peers/directory/dirui.env.example` (dirui) zijn de referentie van wat er in de UI hoort te
> staan. De v2-API kan env alleen bij het *aanmaken* van een component zetten
> (`AddComponentRequest`), niet bijwerken (`UpdateComponentRequest` heeft geen `env_vars`/`aliases`).
> Er loopt een feature request bij ZAD-beheer om dat te openen.

## Componenten (project `mft-tp9`)

Namen: kleine letters + cijfers, geen streepjes, max 12 tekens. Aangemaakt in de Operations
Manager UI (project `mft-tp9`).

| Component | Image | Service / Web / Bijlagen | Rol |
|-----------|-------|--------------------------|-----|
| `dirmgr` | `ghcr.io/minbzk/moza-fsc-testnet-manager-migrate:<tag>` | **`postgresql-database`** + **Web modus 2** + **6 bijlagen** | manager (directory-mode, migrate→serve) + managed Postgres |
| `dirui` | `docker.io/federatedserviceconnectivity/directory-ui:v1.43.7` | Web (edge) + 3 bijlagen | dienstencatalogus-UI |

**Geen eigen postgres-component** — `dirmgr` gebruikt ZAD's managed Postgres via de
`postgresql-database`-service. De DSN komt uit substitutievars
(`$DATABASE_SERVER_USER`/`$DATABASE_PASSWORD`/`$DATABASE_SERVER_HOST`/`$DATABASE_DB`, poort 5432),
via een `aliases`-regel in `STORAGE_POSTGRES_DSN` (conventie uit het berichtenbox-project).

## Hostnaam

`domain_format = component-deployment-project` (ZAD-API `UpsertDeploymentRequest`) → per component
een voorspelbare hostnaam `<component>-<deployment>-<project>.<base_domain>`.

- `base_domain` = `rig.prd1.gn2.quattro.rijksapps.nl` (bevestigd via API, 2026-06-29).
- Cluster = `odcn-production` (prod). Voorbeeld bestaande URL: `directory-test-mft-tp9.<base_domain>`.
- De manager-hostnaam is de **SNI-hostnaam** voor `SELF_ADDRESS` / `DIRECTORY_MANAGER_ADDRESS` (zie env).

> **Deploymodel:** een PR krijgt een eigen deployment, benoemd naar het **PR-nummer**
> (`pr-<PR-nummer>`, bv. `pr-42`) — niet naar het issuenummer; wat naar `main` gaat landt in
> deployment **`test`**. De directory = 2 componenten (`dirmgr` + `dirui`) op ZAD's managed
> Postgres; een upsert van `test` vervangt de bestaande placeholder-component `directory` (image
> leeg). Manager-hostnaam dan: `dirmgr-test-mft-tp9.<base_domain>` (= `SELF_ADDRESS`). Een PR rolt
> een preview `pr-<PR-nummer>` uit zodra de gewijzigde bestanden in de deploy-paden vallen (bepaald
> in de `changes`-job) — niet elke `pull_request`-trigger deployt. Dependabot-PR's worden altijd
> overgeslagen (`skip-bot-prs: 'true'`), ook als hun diff wél in die paden valt. Bij het sluiten van
> de PR wordt een gedeployde preview weer opgeruimd. `pr-<PR-nummer>` = het PR-nummer, niet het
> issuenummer.

## Stappen

### 1. Image bouwen + pushen

Draai `build-manager-migrate.yml` (Actions → workflow_dispatch, `image_tag=v1.43.7`), of merge een
wrapper-wijziging naar `main`. Resultaat: `ghcr.io/minbzk/moza-fsc-testnet-manager-migrate:v1.43.7`
(en/of `…:v1.43.7-pr-<n>` voor previews — de `image_suffix`-input van de reusable
`workflow_call` hangt het PR-nummer achter de tag, geen branch-slug). Controleer dat het package
zichtbaar is voor het ZAD-pull-mechanisme (ghcr-package → repo-linked via de
`org.opencontainers.image.source`-label).

### 2. Certs + upload-set genereren (jouw host)

```bash
./pki/init-ca.sh        # eenmalig — de group-CA (trust-anchor); bewaar de key veilig
./pki/issue.sh -f       # group- + internal-certs
./pki/verify.sh         # groen?
./pki/zad-bundle.sh directory   # -> pki/zad-upload/directory/ + MANIFEST.md
```

### 3. Bijlagen koppelen (UI) — cert-mount, ontwerp A

Vink **"bijlagen"** aan op `dirmgr` en voeg elke file uit `MANIFEST.md` toe als
**bestand** op exact zijn pod-pad:

| Bijlage-bestand | Pad in de pod |
|-----------------|----------------|
| `ca/root.pem` | `/etc/fsc/ca/root.pem` |
| `out/directory/directory/cert.pem` | `/etc/fsc/out/directory/directory/cert.pem` |
| `out/directory/directory/key.pem` | `/etc/fsc/out/directory/directory/key.pem` |
| `internal/directory/ca/root.pem` | `/etc/fsc/internal/directory/ca/root.pem` |
| `internal/directory/directory/cert.pem` | `/etc/fsc/internal/directory/directory/cert.pem` |
| `internal/directory/directory/key.pem` | `/etc/fsc/internal/directory/directory/key.pem` |

`dirui` krijgt zijn subset (group-root + een lezer-cert/key) op dezelfde manier.
**Geen `combined.pem` nodig** (modus 2 = pod serveert losse cert/key). Bijlagen zijn read-only +
binary-safe (spike vraag 4).

### 4. Env zetten (UI, projectconfig; hieronder ter referentie)

De env staat op `dirmgr`/`dirui` in de Operations Manager UI (project `mft-tp9`), niet in git.
Waarden ter referentie:

- `dirmgr`: de waarden uit `peers/directory/manager.env.example`, met:
  - `SELF_ADDRESS=https://dirmgr-test-mft-tp9.<base_domain>` (of de PR-deployment)
  - `DIRECTORY_MANAGER_ADDRESS=` idem (directory wijst naar zichzelf)
  - `STORAGE_POSTGRES_DSN` uit de managed-Postgres-substitutievars (`$DATABASE_*`) — geen eigen
    postgres-component.
  - `DISABLE_CRL_CHECKS=true` als **interim** (lege CRL, geen distributiepunt). `TODO(#722)`:
    CRL-pad mounten + `DISABLE_CRL_CHECKS` weghalen vóór go-live (zie `manager.env.example`).
- `dirui`: de waarden uit `peers/directory/dirui.env.example`, met dezelfde
  `DIRECTORY_MANAGER_ADDRESS`-alias (naar dirmgr op dezelfde deployment) als hierboven.

### 5. "Publicatie op het web" → modus 2 (UI)

Op `dirmgr`: **"Eigen certificaat op de pod (passthrough)"**. De ingress SNI-routet
:443 → de pod (`LISTEN_ADDRESS_EXTERNAL=0.0.0.0:8443`), termineert niet. **Niet** modus 1/3
(edge-/ingress-terminatie breekt de certificate-binding, #720). `dirui` mag wél een
gewone (edge) publicatie krijgen — die doet geen mTLS-mesh.

### 6. Deployen

Deployen doet CI. Handmatig kan via **Actions → zad-deploy-directory → Run workflow**
(`deployment`, `image_tag`, `manager_tag`). Er is geen lokaal deploy-script meer; wil je zien wat
er staat, kijk dan in de Operations Manager UI of doe een read-only API-call:

```bash
read -rs ZAD_API_KEY; export ZAD_API_KEY     # plak de key niet inline
curl -sS -H "X-API-Key: $ZAD_API_KEY" \
  https://zad.rijksapp.nl/api/v2/projects/mft-tp9/deployments | jq -r '.deployments[].name'
```

**Blijft handwerk in de UI (stappen 3 + 5):** bijlagen (certs) + Publicatie op het web modus 2 op
`dirmgr` — eenmalig per project, niet per deployment.

### Auto-deploy naar `test` op main

`zad-deploy-directory.yml` triggert náást `workflow_dispatch` (previews/handmatig) ook op **push
naar main** — een merge (CI groen) rolt de directory automatisch uit naar deployment `test`
(besluit in `docs/ontwerpkeuzes.md`, ontwerp in `docs/superpowers/specs/`). Push-pad zet vast:
`deployment=test`, `image_tag=v1.43.7`, `manager_tag=""` (canonieke tag).

Sinds de PR-preview-uitbreiding rolt een `pull_request` (open/sync) een `pr-<PR-nummer>`-preview
uit zodra de `changes`-job de deploy-paden geraakt ziet — net als bij de push-naar-main hierboven,
géén automatisme voor élke PR. Dependabot-PR's worden altijd overgeslagen (`skip-bot-prs: 'true'`).
`workflow_dispatch` blijft voor handmatige overrides.

Path-filter (alleen deze paden triggeren de auto-deploy, en een docs-only wijziging — `^docs/` of
`*.md` — telt nooit mee, ook niet binnen zo'n pad): `deploy/zad/manager-migrate/**`, `group/**`, de
workflow zelf. Docs- en peer-merges blijven dus stil. Voor `push` staat dat pad-filter ook in de
trigger-`paths:` van de workflow zelf; de docs-uitzondering zit daar niet bij (de docs-only-conjunctie
loopt alleen via de `changes`-job — zie hieronder). Voor `pull_request` zit de hele filter (paden +
docs-uitzondering) in de `changes`-job, op basis van de bestandenlijst uit de GitHub PR-API (niet
`git diff` — dat gebruikt alleen de `push`-tak) — zo blijft bijvoorbeeld het `closed`-event van een PR
altijd bereikbaar voor de `cleanup-preview`-job, ongeacht welke bestanden die PR wijzigde.

Een `pull_request`-preview ruimt een `cleanup-preview`-job op bij het sluiten van de PR.

Drie jobs voorkomen de build-deploy-race:

| Job | Wanneer | Doet |
|-----|---------|------|
| `changes` | elke push mét pad-match, én elke PR (open/sync/reopened/closed) | push: `git diff`; PR: de bestandenlijst uit de GitHub-API → outputs `run` + `manager_migrate_changed` |
| `build` | alleen als `manager-migrate/**` non-docs wijzigde | roept `build-manager-migrate` aan (reusable `workflow_call`); bouwt+pusht `v1.43.7` op main, `v1.43.7-pr-<n>` op een PR |
| `deploy` | ná build-succes, óf meteen als build geskipt | roept `RijksICTGilde/zad-actions/deploy` aan met `deployment=test` op main, `deployment=pr-<n>` op een PR |

Image-change → build eerst → deploy (image bestaat gegarandeerd vóór de deploy-stap). Config/group-change
→ build skip → deploy herbruikt de bestaande tag. De manager-migrate-image bouwt via de reusable
`workflow_call` in `zad-deploy-directory.yml` (build → deploy in één run, ordering-veilig).
`build-manager-migrate.yml` heeft géén eigen `push`-trigger meer; een preview krijgt zijn image
(`v1.43.7-pr-<n>`) uit die call, main de canonieke `v1.43.7`.

Faalt de deploy, dan is dat een **kale rode run** in de Actions-tab (bewust, geen auto-issue).
Handmatige/preview-deploys blijven via `workflow_dispatch` (zie stap 6).

### 7. Verifiëren

- **Announce-self:** de directory zet zichzelf in `peers.peers`. Check (psql op de managed Postgres):
  `SELECT id, name, manager_address FROM peers.peers;` → rij `00000000000000000010` /
  `directory` met `manager_address` op de ZAD-hostnaam (:443).
- **directory-ui** bereikbaar op zijn hostnaam.
- **mesh-TLS:** een tweede peer (of een lokale outway met de juiste trust) kan de
  directory-manager op :443 bereiken (SNI-routing + cert-binding intact).

## Openstaande TODO's

- CRL-configuratie op ZAD i.p.v. `DISABLE_CRL_CHECKS=true` (#722) — **gate vóór go-live**.
- **Health-probe** doet een standaard TCP-poort-check op `:8443` (mTLS) → manager logt
  `TLS handshake error … EOF` (cosmetisch; pod healthy). Protocol-aware probe **aangevraagd bij ZAD**.
- **Key-permissies**: bijlagen worden read-only gemount (niet 0600) → `invalid PKI key permissions`
  (non-fataal). 0600-mount **aangevraagd als feature-request bij ZAD**.
- `dirui` afmaken (3 bijlagen + edge-publicatie).
