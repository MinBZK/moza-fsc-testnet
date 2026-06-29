# Runbook: directory live op ZAD (#723)

> Doel: de centrale **directory** (group-anker) draaiend krijgen op ZAD-project `mft-tp9`, zodat
> peers kunnen announcen. Gegrond op `docs/spikes/zad-attachments.md` (cert-mount-ontwerp A) en de
> ZAD Operations Manager API (`https://zad.rijksapp.nl/openapi.json`, v2).
>
> **Status (2026-06-29):** eerste bring-up gestart op deployment `pr-723`; componenten
> `dirmgr`/`dirui` aangemaakt via de API. **Geblokkeerd:** na het toevoegen + opslaan van de
> bijlagen op `dirmgr` verdwenen de componenten uit het project (ZAD-bug → bij beheer belegd).
>
> **Wijziging — managed PostgreSQL:** we draaien GEEN eigen `postgres:17` meer; we gebruiken ZAD's
> managed Postgres (`postgresql-database`-service) voor betere resource-pooling. `dirdb` vervalt;
> de manager krijgt de service + bouwt `STORAGE_POSTGRES_DSN` uit de connection-substitutievars
> (`$HOST`/`$PORT`/`$DB_NAME` + credentials — exacte vars TODO bij beheer). Script + onderstaande
> stappen worden hierop aangepast zodra die conventie bekend is.

## Taakverdeling: API/CI vs UI

- **Via `deploy/zad/upsert-directory.sh` (ZAD-API, secret `ZAD_API_KEY_DIRECTORY`):** deployment +
  componenten + images **+ env_vars**. `:upsert-deployment` maakt het deployment; `POST /components`
  maakt elke component mét env + poort. Het script bevat de poorten + env (uit de lokale harness).
- **Alleen in de Operations Manager UI** (niet in de deploy-API): **bijlagen** (cert-mount, ontwerp A)
  en **"Publicatie op het web"** (passthrough-TLS, modus 2).

## Componenten (deployment `directory`, project `mft-tp9`)

| Component | Image | Rol |
|-----------|-------|-----|
| `directory-postgres` | `postgres:17` | system-of-record (persistent, gebackupt — niet preview-cloned) |
| `directory-manager` | `ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:v1.43.7` | manager in directory-mode (migrate→serve) |
| `directory-ui` | `docker.io/federatedserviceconnectivity/directory-ui:v1.43.7` | dienstencatalogus-UI |

Dit is exact de `components`-lijst in `.github/workflows/deploy.yml`.

## Hostnaam

`domain_format = component-deployment-project` (ZAD-API `UpsertDeploymentRequest`) → per component
een voorspelbare hostnaam `<component>-<deployment>-<project>.<base_domain>`.

- `base_domain` = `rig.prd1.gn2.quattro.rijksapps.nl` (bevestigd via API, 2026-06-29).
- Cluster = `odcn-production` (prod). Voorbeeld bestaande URL: `directory-test-mft-tp9.<base_domain>`.
- De manager-hostnaam is de **SNI-hostnaam** voor `SELF_ADDRESS` / `DIRECTORY_MANAGER_ADDRESS` (zie env).

> **Deploymodel:** een PR krijgt een eigen deployment; wat naar `main` gaat landt in deployment
> **`test`**. De directory = 3 componenten (`directory-postgres/-manager/-ui`); een upsert van
> `test` vervangt de bestaande placeholder-component `directory` (image leeg). Manager-hostnaam
> dan: `directory-manager-test-mft-tp9.<base_domain>` (= `SELF_ADDRESS`). Een PR-preview gebruikt
> zijn eigen deployment-naam i.p.v. `test`.

## Stappen

### 1. Image bouwen + pushen

Draai `build-manager-migrate.yml` (Actions → workflow_dispatch, `image_tag=v1.43.7`), of merge een
wrapper-wijziging naar `main`. Resultaat: `ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:v1.43.7`
(en/of `…:v1.43.7-<branch>` voor previews). Controleer dat het package zichtbaar is voor het
ZAD-pull-mechanisme (ghcr-package → repo-linked via de `org.opencontainers.image.source`-label).

### 2. Certs + upload-set genereren (jouw host)

```bash
./pki/init-ca.sh        # eenmalig — de group-CA (trust-anchor); bewaar de key veilig
./pki/issue.sh -f       # group- + internal-certs
./pki/verify.sh         # groen?
./pki/zad-bundle.sh directory   # -> pki/zad-upload/directory/ + MANIFEST.md
```

### 3. Bijlagen koppelen (UI) — cert-mount, ontwerp A

Vink **"bijlagen"** aan op `directory-manager` en voeg elke file uit `MANIFEST.md` toe als
**bestand** op exact zijn pod-pad:

| Bijlage-bestand | Pad in de pod |
|-----------------|----------------|
| `ca/root.pem` | `/etc/fsc/ca/root.pem` |
| `out/directory/directory/cert.pem` | `/etc/fsc/out/directory/directory/cert.pem` |
| `out/directory/directory/key.pem` | `/etc/fsc/out/directory/directory/key.pem` |
| `internal/directory/ca/root.pem` | `/etc/fsc/internal/directory/ca/root.pem` |
| `internal/directory/directory/cert.pem` | `/etc/fsc/internal/directory/directory/cert.pem` |
| `internal/directory/directory/key.pem` | `/etc/fsc/internal/directory/directory/key.pem` |

`directory-ui` krijgt zijn subset (group-root + een lezer-cert/key) op dezelfde manier.
**Geen `combined.pem` nodig** (modus 2 = pod serveert losse cert/key). Bijlagen zijn read-only +
binary-safe (spike vraag 4).

### 4. Env zetten (Operations Manager, of `env_vars` via API)

- `directory-manager`: de waarden uit `peers/directory/manager.env.example`, met:
  - `SELF_ADDRESS=https://directory-manager-test-mft-tp9.<base_domain>:443` (of de PR-deployment)
  - `DIRECTORY_MANAGER_ADDRESS=` idem (directory wijst naar zichzelf)
  - `DISABLE_CRL_CHECKS` **niet** op `true` zetten op ZAD — `TODO(#722)`: óf een CRL-pad
    configureren, óf bewust uitzetten (zie `peers/directory/manager.env.example`).
- `directory-postgres`: `peers/directory/postgres.env.example` (`POSTGRES_DB=fsc_directory`,
  `POSTGRES_USER=fsc`, `POSTGRES_PASSWORD` via secret — moet matchen met `STORAGE_POSTGRES_DSN`).
- `directory-ui`: zie de `directory-ui`-env in `deploy/local/docker-compose.yaml` (adres-namen
  naar de ZAD-hostnaam).

### 5. "Publicatie op het web" → modus 2 (UI)

Op `directory-manager`: **"Eigen certificaat op de pod (passthrough)"**. De ingress SNI-routet
:443 → de pod (`LISTEN_ADDRESS_EXTERNAL=0.0.0.0:8443`), termineert niet. **Niet** modus 1/3
(edge-/ingress-terminatie breekt de certificate-binding, #720). `directory-ui` mag wél een
gewone (edge) publicatie krijgen — die doet geen mTLS-mesh.

### 6. Deployen

Eén bron — `deploy/zad/upsert-directory.sh` (3 modi) — voor zowel CLI als CI:

```bash
read -rs ZAD_API_KEY; export ZAD_API_KEY              # plak de key niet inline
./deploy/zad/upsert-directory.sh validate             # read-only auth/connectie-check
./deploy/zad/upsert-directory.sh plan  test v1.43.7   # toont alle JSON-bodies, muteert NIET (review)
./deploy/zad/upsert-directory.sh apply test v1.43.7   # upsert deployment + maakt componenten (env), pollt tasks
# preview die de componenten van test erft (alleen images):
./deploy/zad/upsert-directory.sh apply pr-123 v1.43.7 test
```

Het script maakt het deployment (`:upsert-deployment`, `domain_format=component-deployment-project`)
en de 3 componenten met poorten + env (`POST /components`), en pollt elke task. `plan` toont eerst
de exacte bodies. **Daarna nog handmatig (UI, stappen 3 + 5):** bijlagen (certs) + Publicatie op het
web modus 2 op `directory-manager`. Via CI: `zad-deploy-directory.yml` (zelfde script; beschikbaar
zodra 'ie op `main` staat). Env (stap 4) zit nu in het script — UI-env niet meer nodig.

### 7. Verifiëren

- **Announce-self:** de directory zet zichzelf in `peers.peers`. Check (psql op directory-postgres):
  `SELECT id, name, manager_address FROM peers.peers;` → rij `00000000000000000010` /
  `directory` met `manager_address` op de ZAD-hostnaam (:443).
- **directory-ui** bereikbaar op zijn hostnaam.
- **mesh-TLS:** een tweede peer (of een lokale outway met de juiste trust) kan de
  directory-manager op :443 bereiken (SNI-routing + cert-binding intact).

## Openstaande TODO's

- `base_domain` exact (stap "Hostnaam").
- `deploy.yml` component-creatie + `domain_format`-plaatsing (stap 6).
- CRL-configuratie op ZAD i.p.v. `DISABLE_CRL_CHECKS` (#722).
- Per-peer secrets (postgres-wachtwoord) via ZAD-secret, niet in env-template.
