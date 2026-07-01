# ZAD-projecten & deploymodel

Dit document legt vast hoe de FSC-testomgeving over ZAD-projecten verdeeld wordt,
wie wat deployt, en wat een "template" in deze repo concreet ís. Het reconcilieert
het FSC-model (group + directory + peers) met de werkelijkheid van ZAD.

> Status: ontwerp (#721). Uitwerking naar echte config volgt in #723 (directory +
> group), #724/#725 (peers) en #729 (CI/deploy). Hieronder gemarkeerde blockers
> moeten daarvóór belegd zijn.

## Kernbeslissing

- **Peer-templates leven hier** (`moza-fsc-testnet`) als *source-of-truth*.
- **Deployen gebeurt bij de applicatie:** elke peer draait in het ZAD-project van
  zijn eigen app; de directory/group draait in een eigen, centraal project dat
  vanuit deze repo wordt gedeployd.

Dit spiegelt OpenFSC's eigen layout (`helm/deploy/<org>/` per organisatie +
`helm/deploy/shared/` voor de gedeelde kern).

## Waarom per peer een eigen project

- **Networking.** De inway moet zijn upstream-app bereiken via intra-project DNS;
  de outway wordt door de app intern aangeroepen. ZAD-projecten zijn geïsoleerd —
  co-locatie van inway/outway mét de app vermijdt cross-project hops.
- **Trust/eigendom.** Elke peer = een eigen organisatie in de federatie, met een
  eigen cert en eigen secrets. Project-isolatie = dat trust-model getrouw.
- **Lifecycle.** Een app-team deployt zijn app én zijn peer samen.
- **8443-IP-schaarste (#720).** Publieke IP's voor de management-poort zijn schaars
  → houd het aantal managers klein (~1 per peer-project), deel IP's waar mogelijk.
  **Update (#723):** de manager-mesh loopt nu op **:443-SNI-passthrough** (zie
  "Open punten / blockers" onder), dus MetalLB:8443 is voor de mesh niet meer nodig.

## Projecten

| ZAD-project | Rol | Componenten (ZAD) | Beheerd vanuit |
|-------------|-----|-------------------|----------------|
| `fsc-directory` (group-anker) | directory + group | manager, directory(-ui), txlog-api, postgres | **moza-fsc-testnet** |
| peer: magazijn | provider | manager, inway, txlog-api, postgres | bij de app (`moza-poc-fbs-berichtenbox`) |
| peer: uitvraag | consumer | manager, outway, txlog-api, postgres | bij de app (`moza-poc-fbs-berichtenbox`) |
| peer: profiel (later, #730) | provider | manager, inway, txlog-api, postgres | bij de app (`moza-profiel-service`) |

Cross-project communicatie loopt — net als in de FBS-deploy — via de
https-ingress-URL's
(`<component>-<deployment>-<projectid>.rig.prd1.gn2.quattro.rijksapps.nl`).

## Hoe ZAD deployt (en wat dat betekent voor "templates")

**ZAD deployt geen Helm-charts.** De `RijksICTGilde/zad-actions/deploy`-action
krijgt een `project-id`, een `deployment-name` en een lijst **container-images**:

```json
[
  {"name": "manager", "image": "<registry>/open-fsc-manager:<tag>"},
  {"name": "inway",   "image": "<registry>/open-fsc-inway:<tag>"},
  {"name": "postgres","image": "postgres:17"}
]
```

Gevolgen:

1. **De OpenFSC Helm-charts zijn niet het deploy-artefact** maar de *bron* voor
   (a) welke images er per component zijn en (b) welke env-vars/mounts elke
   component nodig heeft. Zie de chart-`deployment.yaml` per component in
   [open-fsc](https://gitlab.com/rinis-oss/fsc/open-fsc) (`helm/charts/open-fsc-*`).
2. **Configuratie = env-vars + gemounte files**, niet CLI-args (ZAD staat geen
   component-args toe). De manager-, inway- en outway-images zijn volledig via
   env-vars te configureren.
3. **Env wordt éénmalig per component gezet in Operations Manager** — de
   deploy-action draagt geen env. Previews erven via `clone-from: test`.
   **Uitzondering (#723):** de directory- en manager-PostgreSQL zijn
   *system-of-record* (gepubliceerde diensten, contracten/grants) → **persistent +
   gebackupt, niet preview-cloned/ephemeral**. De `clone-from: test`-erfenis geldt
   dus niet voor die DB's; beleggen bij ZAD-beheer (zie `docs/ontwerpkeuzes.md`).
4. **Certs worden gemount via ZAD `attachments`** (encrypted, read-only); de
   `TLS_*`-env-vars wijzen naar die paden. Secrets staan nooit in deze repo.

### Wat een peer-template in deze repo dus is

Per peer leggen we vast (en onderhouden als source-of-truth):

- **Componentlijst + images** (gepind) → voor de `components:`-JSON van de
  deploy-action.
- **Env-var-template** per component (`.env.example`), met de échte OpenFSC-namen
  (zie onder) → in te voeren in Operations Manager.
- **Welke attachments** (cert-bestanden) gemount moeten worden en op welk pad.

### Relevante OpenFSC env-vars (manager — uittreksel)

| Env-var | Betekenis |
|---------|-----------|
| `GROUP_ID` | group-identifier van de federatie |
| `SELF_ADDRESS` | eigen (extern bereikbare) manager-adres |
| `DIRECTORY_PEER_ID` / `DIRECTORY_MANAGER_ADDRESS` | peer-ID + adres van de directory |
| `CONTROLLER_REGISTRATION_API_ADDRESS` | controller-registratie |
| `TX_LOG_API_ADDRESS` | transaction-log API (verplichte logging-extensie) |
| `LISTEN_ADDRESS_EXTERNAL` (8443) / `_INTERNAL` (9443) / `_INTERNAL_UNAUTHENTICATED` (9444) | luister-adressen |
| `TLS_CERT` / `TLS_KEY` / `TLS_ROOT_CERT` | peer-cert (group-trust) |
| `TLS_GROUP_*`, `TLS_INTERNAL_UNAUTHENTICATED_*` | inter-component mTLS |
| `POSTGRES_HOST/PORT/DATABASE/USER/PASSWORD`, `PGSSLMODE`, `STORAGE_POSTGRES_DSN` | database |
| `AUDITLOG_REST_ADDRESS` | auditlog |

Inway en outway hebben hun eigen, vergelijkbare env-sets (zie de betreffende
charts). Dit uittreksel vervangt de eerdere, verzonnen platte keys in de
`peers/*/values.example.yaml`; die worden in #723/#724/#725 omgezet naar deze
echte env-namen.

## Cross-repo consumptie (hoe een app-repo de peer-template gebruikt)

Omdat ZAD images + env deployt (geen charts), is dit een **GitHub-workflow**-vraag,
geen Helm-distributievraag.

**Besluit (#729): kopiëren/vendoren van de generieke scripts.** De deploy-/cleanup-tooling is
**volledig env-gedreven** (`deploy/zad/upsert-directory.sh`, `deploy/zad/cleanup.sh` — via
`ZAD_PROJECT` en `ZAD_API_KEY`). Een app-repo vendort die scripts + een dunne
`workflow_dispatch`-workflow met het
**eigen** project + de eigen key; source-of-truth (images, componentnamen, env-templates) blijft
hier. Een reusable `workflow_call` is bewust niet gekozen: dispatch (repo-secret) en call
(doorgegeven secret) in één workflow mengen botst met de GitHub-secrets-context (zie
`docs/zad-cleanup.md`). De env-var-templates (`.env.example`) voert het app-team éénmalig in.

## Open punten / blockers

- **ZAD `attachments` (cert-mount) → beschikbaar (2026-06-29).** Per-peer certs kunnen nu
  read-only gemount worden; de eerdere blocker voor #722/#723 is opgeheven. Mount group-trust +
  per-peer group/internal-certs op de gedocumenteerde paden (zie `peers/directory/manager.env.example`).
- **DB-migraties → opgelost (wrapper-image, #723).** ZAD staat geen args/init-containers
  toe, dus migreren zit nu in de image-entrypoint: `deploy/zad/manager-migrate/`
  (`migrate up && serve` in één dunne laag boven de stock-manager — geen broncode-fork).
  De directory-job in `deploy.yml` gebruikt deze `manager-migrate`-image.
- **Env is een handmatige stap.** Operations Manager-config is niet via de
  deploy-action te zetten; documenteer per component welke env nodig is. Templates:
  `peers/directory/manager.env.example`.
- **8443-IP's → 443-mesh (#723).** De manager-mesh loopt op **:443 via SNI-passthrough**
  (OpenShift `passthrough`-Route, gedeeld router-IP), niet 8443/MetalLB — bewezen in
  `docs/spikes/manager-443-sni.md`. 8443/MetalLB is niet meer nodig voor de mesh.
- **Directory = manager-in-directory-mode.** Geen apart image; een OpenFSC-manager met
  `DIRECTORY_PEER_ID` = eigen OIN en lege `TX_LOG_API_ADDRESS`.

## Referenties

- [`docs/topologie.md`](topologie.md) · [`docs/ontwerpkeuzes.md`](ontwerpkeuzes.md)
- OpenFSC deploy-voorbeelden: `helm/deploy/<org>/` (per org) + `helm/deploy/shared/`
- ZAD-deploypatroon: zie `deploy.yml` in `moza-poc-fbs-berichtenbox` (geïsoleerde
  projecten, `zad-actions/deploy` met `components`-JSON, `clone-from: test`).
