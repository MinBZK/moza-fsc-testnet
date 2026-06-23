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
geen Helm-distributievraag. Opties — te besluiten in #729:

1. **Reusable workflow (aanbevolen).** Deze repo levert een `workflow_call`-workflow
   die `zad-actions/deploy` aanroept met de peer-componentlijst. Het app-repo roept
   die aan in zijn eigen `deploy.yml` (deployt de peer náást de app, in hetzelfde
   project). Source-of-truth (images, componentnamen) blijft hier; versionering via
   de git-ref van de aanroep.
2. **Composite action** hier, gebruikt door het app-repo (vergelijkbaar, fijnmaziger).
3. **Kopiëren + pinnen** in het app-repo (simpelst, maar drift-risico).

De env-var-templates (`.env.example`) worden in alle gevallen door het app-team
éénmalig in Operations Manager ingevoerd.

## Open punten / blockers

- **ZAD `attachments` (cert-mount).** Nog niet beschikbaar; blocker voor #722/#723.
  Zonder cert-mount kunnen peers geen group-trust opzetten. Beleggen bij ZAD-beheer.
- **DB-migraties.** De OpenFSC-charts draaien migraties via een init-container met
  args (`manager migrate up`). ZAD staat geen args/init-containers toe → er is een
  alternatief nodig (one-shot migratie-component, of een image-entrypoint dat
  migreert). Uit te zoeken in #723.
- **Env is een handmatige stap.** Operations Manager-config is niet via de
  deploy-action te zetten; documenteer per component welke env nodig is.
- **8443-IP's.** Minimaliseer managers; deel IP's. 443 schaalt via SNI + gedeeld
  router-IP.

## Referenties

- [`docs/topologie.md`](topologie.md) · [`docs/ontwerpkeuzes.md`](ontwerpkeuzes.md)
- OpenFSC deploy-voorbeelden: `helm/deploy/<org>/` (per org) + `helm/deploy/shared/`
- ZAD-deploypatroon: zie `deploy.yml` in `moza-poc-fbs-berichtenbox` (geïsoleerde
  projecten, `zad-actions/deploy` met `components`-JSON, `clone-from: test`).
