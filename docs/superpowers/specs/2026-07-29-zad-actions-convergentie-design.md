# Ontwerp: deploy via `zad-actions`, eigen ZAD-scripts weg

> Volgorde/status: infra-follow-up binnen epic
> [#737](https://github.com/MinBZK/MijnOverheidZakelijk/issues/737). Vervangt het deploy-mechanisme
> uit `docs/superpowers/specs/2026-07-02-directory-pr-preview-design.md`; het preview-*model*
> (`pr-<PR-nummer>`, cleanup-on-close) blijft ongewijzigd.

## Doel

Het deploy-pad van dit repo gelijk maken aan dat van
[`moza-poc-fbs-berichtenbox`](https://github.com/MinBZK/moza-poc-fbs-berichtenbox): alle
ZAD-mutaties via `RijksICTGilde/zad-actions`, geen eigen curl-scripts meer. Eén manier van werken
over de MOZa-repo's heen, en de ZAD-API-eigenaardigheden zijn dan het probleem van de action in
plaats van het onze.

## Achtergrond & vastgestelde feiten

Alles hieronder is deze sessie geverifieerd tegen de live-API, de runlogs en de action-bron —
geen aannames.

- **`cloneFrom` kloont configuratie, geen data.** `zad-actions/deploy` documenteert de input als
  *"Clone configuration from existing deployment"* en logt `Cloning config from: test`. Data klonen
  zijn aparte endpoints: `POST /deployments/{d}/:clone-database` en `:clone-bucket`. Het besluit
  "previews klonen niet, want de SoR-DB mag niet gekloond worden"
  (`2026-07-02-directory-pr-preview-design.md`, Besl. D) rustte dus op een verkeerde premisse.
- **Componenten zijn project-breed.** `dirmgr`/`dirui` bestaan één keer per project, mét hun
  `env_vars`/`aliases`/`services`; een deployment *verwijst* ernaar. Een nieuw `pr-<n>` erft de
  config daarom sowieso — ook zonder `clone-from`. Componentnamen zijn project-uniek: een tweede
  `POST /components` faalt met `Component 'dirmgr' already exists in project 'mft-tp9'` (de bug die
  PR #35 repareert).
- **Env is via de API niet te herconfigureren.** `AddComponentRequest` (create) heeft `env_vars` +
  `aliases`; `UpdateComponentRequest` (PATCH) heeft ze **niet**. Losse component-delete bestaat
  niet. Env wijzigen kan dus alleen in de UI — een feature request hiervoor loopt bij ZAD-beheer.
- **Bijlagen en "Publicatie op het web" komen in de v2-API niet voor.** Waren al UI-werk en blijven
  dat.
- **De ZAD-werkwijze is projectconfig + deploy-variabelen.** Env wordt op projectniveau zo gezet
  dat 'ie voor élke deployment klopt, via `$DEPLOYMENT_NAME` en `$DATABASE_*`. Onze `aliases` doen
  dat al (`SELF_ADDRESS`, `DIRECTORY_MANAGER_ADDRESS`, `STORAGE_POSTGRES_DSN`), dus er is geen
  waardemigratie nodig.

## Besluiten

### A. `upsert-directory.sh` en `cleanup.sh` verdwijnen

`deploy/zad/` houdt alleen `manager-migrate/` over — de wrapper-image (`migrate up && serve`) blijft
van ons, want die lost een ZAD-beperking op (geen args/init-containers) en is een build-artefact,
geen deploy-mechanisme.

Consequentie: de env in `upsert-directory.sh` is niet langer de bron. Dat is de bewuste prijs van
deze keuze — `peers/directory/manager.env.example` blijft in git als **referentie** van wat er in de
UI hoort te staan, zonder afdwinging. De ZAD-feature-request voor env-via-API is wat die
afdwinging later kan terugbrengen.

### B. Deploy via `zad-actions/deploy`

`zad-deploy-directory.yml` behoudt zijn jobstructuur (`meta` → `changes` → `build` → `deploy`); de
`deploy`-job wordt één action-stap:

```yaml
uses: RijksICTGilde/zad-actions/deploy@13434cd415db0cd195a2c5f12bf67645acfcb635 # v4.0.6
with:
  api-key: ${{ secrets.ZAD_API_KEY_DIRECTORY }}
  project-id: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
  deployment-name: pr-<PR-nummer>     # push naar main: `test`
  clone-from: test                    # alleen previews; leeg op `test` zelf
  skip-bot-prs: 'false'
  wait-for-ready: 'false'
  task-timeout: '600'
  comment-on-pr: 'true'
  components: |
    [{"name": "dirmgr", "image": "ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:<tag>"},
     {"name": "dirui",  "image": "docker.io/federatedserviceconnectivity/directory-ui:v1.43.7"}]
```

Onderbouwing per input:

- **`skip-bot-prs: 'false'`** — de action skipt bot-PR's standaard (`Skipping: PR author
  'dependabot[bot]' is a bot`, groene job zonder deploy). Wij willen previews op élke PR, ook op
  een actions-versiebump; daarvoor staat de key al in de Dependabot-secretstore.
- **`wait-for-ready: 'false'`** — de action curlt vanaf de runner één health-endpoint per
  component. `dirmgr` is mTLS-only en geeft daar nooit 2xx op; de wachtlus zou altijd time-outen.
  Zelfde reden als in de sibling.
- **`task-timeout: '600'`** — verse preview-provisioning duurt structureel langer dan een update;
  300s bleek daar reproduceerbaar te krap.
- **`clone-from: test`** — pariteit met de sibling. Bij ons feitelijk overbodig (componenten zijn
  al project-breed), maar onschadelijk en het houdt beide repo's leesbaar als één patroon.

De eigen comment-upsert-stap vervalt: `comment-on-pr` doet dit. Géén GitHub-`environment` en dus
`delete-github-env: 'false'` — een environment vergt een `GH_ADMIN_TOKEN` (PAT) om bij PR-close
opgeruimd te worden, en die dependency vermijden we bewust (ongewijzigd besluit uit Besl. E van het
preview-ontwerp).

### C. Cleanup via `zad-actions/cleanup`, met de vangrail in de workflow

`cleanup-preview` (PR-close) en `zad-cleanup.yml` (workflow_dispatch) roepen beide
`zad-actions/cleanup@<sha>` aan, met `containers:` voor de ghcr-tag `v1.43.7-pr-<n>` — dat vervangt
onze eigen ghcr-delete-stap.

De action kent **geen** beschermde-namen-check, die `cleanup.sh` wel had. Het cluster is
odcn-**production** en `test` is een gedeelde singleton, dus die vangrail komt terug als
`if`-conditie in `zad-cleanup.yml`: een `deployment`-input die `test`/`main`/`master`/`production`/
`prod` matcht faalt luid, tenzij de bestaande `allow_protected`-input aanstaat. In het PR-pad kan
het niet misgaan — de naam is daar altijd `pr-<nummer>`.

### D. Documentatie volgt de verschuiving

`docs/zad-directory-deploy.md` en `docs/zad-cleanup.md` beschrijven nu het script als bron van
env + deploy. Beide worden herschreven naar: **CI deployt images via `zad-actions`; project-config
(env, services, bijlagen, web-publicatie) staat in de Operations Manager UI.** De env-tabel blijft
staan als referentie, met de expliciete kanttekening dat git hier documenteert en niet afdwingt.

`docs/zad-cleanup.md` beschrijft nu ook dat peer-repo's `cleanup.sh` vendoren; dat wordt "peer-repo's
gebruiken dezelfde action". Daarmee vervalt de reden om het script te bewaren.

## Wat er níét verandert

- Preview-model: `pr-<PR-nummer>`, deploy op open/sync, cleanup on close, docs-only-skip en
  fork-skip in de `changes`-job.
- De `build`-job en de `manager-migrate`-wrapper (inclusief de `v1.43.7-pr-<n>`-tag voor previews).
- Het besluit géén GitHub-environment te gebruiken.
- Env-waarden zelf: die staan al deployment-agnostisch in het project.

## Risico's

| Risico | Weging |
|---|---|
| De action koppelt met alleen `{name, image}` een bestaande project-component niet correct aan een vers `pr-<n>` | Onwaarschijnlijk — `:upsert-deployment` deed dit in de run van PR #35 aantoonbaar zelf, en de sibling draait er al maanden op. Blijkt direct uit de eerste preview. |
| Bijlagen (certs) of Publicatie-op-het-web komen niet mee naar een nieuw deployment | Laag — die zijn project/component-niveau en werden op `pr-723` al zonder tussenkomst geërfd; het huidige preview-model draait al op die aanname. |
| Env-drift tussen UI en `manager.env.example` | Reëel en geaccepteerd. Mitigatie is de ZAD-feature-request; tot dan is de `.example` documentatie. |
| Verlies van de beschermde-namen-check | Afgedekt door de `if`-guard in `zad-cleanup.yml` (Besl. C). |

## Verificatie

De PR-pipeline van de implementatie-PR is de test — die deployt zichzelf als `pr-<n>`:

1. `deploy`-job groen, met een preview-comment van de action.
2. `dirui`-URL geeft HTTP 200 en toont de catalogus (bewijst dat `dirui` de manager op :443
   verifieert, dus dat de certs gemount zijn).
3. In de manager-log: `migrate up` slaagt tegen een verse managed Postgres en self-announce
   (`EVENT_TYPE_CREATE_PEER`, OIN `00000000000000000010`) is SUCCEEDED.
4. Bij het sluiten van die PR: deployment weg (`validate` toont 'm niet meer) en de ghcr-tag
   `v1.43.7-pr-<n>` is opgeruimd.

Faalt stap 2 of 3, dan is de oorzaak vrijwel zeker een niet-geërfde bijlage of web-publicatie —
zichtbaar in de UI, en dan is dit ontwerp weerlegd op het punt uit de risicotabel.

## Volgorde

1. PR #35 mergen (repareert `main` → `test` en de component-koppeling; klein en losstaand).
2. Deze wijziging als aparte PR: workflows om, scripts weg, docs bij.
