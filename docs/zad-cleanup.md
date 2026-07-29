# Runbook: ZAD deploy & cleanup automatiseren (#729)

> Doel: de FSC-testomgeving **geautomatiseerd uitrollen én opruimen** per onderdeel
> (directory + peers), reproduceerbaar en conform de bestaande beveiligings-/versievastlegging
> (SHA-pinned). Bouwt voort op de v2 Operations Manager API (zie `docs/zad-directory-deploy.md`
> en [[zad-deploy-api-model]]).

## Model: per onderdeel, deploy bij de app

`docs/zad-projecten.md` legt vast: **de directory draait centraal** (vanuit dit repo), **peers
draaien bij hun app** (co-located in het app-project). Deploy/cleanup volgen die scheiding:

| Onderdeel | Deploy | Cleanup | Beheerd vanuit |
|-----------|--------|---------|----------------|
| directory | `zad-deploy-directory.yml` → `zad-actions/deploy` | `zad-cleanup.yml` → `zad-actions/cleanup` | **dit repo** |
| peer (magazijn/uitvraag/…) | app-repo's `deploy.yml` → `zad-actions/deploy` | app-repo → `zad-actions/cleanup` | bij de app |

Een app-repo hoeft niets uit dit repo te vendoren: dezelfde SHA-gepinde action met het eigen
project-id + de eigen key volstaat. Dat is de "kopiëren + pinnen"-variant uit `zad-projecten.md`,
nu met de action als gedeeld artefact in plaats van een gekopieerd script.

## Deploy (directory)

Zie `docs/zad-directory-deploy.md`. Kort: `zad-deploy-directory.yml` (push naar main, PR-preview
op open/sync, of handmatig via `workflow_dispatch`) roept `RijksICTGilde/zad-actions/deploy` aan —
die zet het deployment + per component het image. Projectconfig (env, bijlagen,
Publicatie-op-het-web) blijft UI-werk (niet in de action).

## Cleanup (directory)

Bij het **sluiten van een PR** ruimt `zad-deploy-directory.yml` (job `cleanup-preview`) de
`pr-<PR-nummer>`-deployment automatisch op via dezelfde `zad-actions/cleanup`-action. Handmatig
blijft mogelijk voor overige gevallen via **Actions → zad-cleanup → Run workflow**, met inputs
`deployment` (verplicht) en `allow_protected` (default `false`).

- **Eenheid van cleanup = een héle deployment.** De v2-API kent geen losse component-delete; de
  action ruimt de deployment (en zijn componenten) op. Async — de action pollt de task.
- **Idempotent**: een niet-bestaande deployment = no-op (geen fout), zodat een cleanup-run veilig
  herhaalbaar is (bv. na een gefaalde PR-preview). Dat zit in de action zelf, niet meer in eigen
  scriptlogica.
- **Container-delete via de action is best-effort én kan verdergaan dan de gevraagde tag**: weigert
  GitHub een losse tag te verwijderen omdat het de laatste getagde versie van het package is, dan
  verwijdert de action het **hele package** in plaats van alleen die tag (zie `cleanup/action.yml`,
  stap "Delete Container Image"). Precies daarom zet de workflow `delete-container: 'false'` en
  verwijdert 'm zelf de package-versie: als de tag een versie deelt met een andere tag, slaat die
  eigen stap het verwijderen over (anders verdwijnt de gedeelde versie mee).
- **Een mislukte delete is geen rode run**: de action degradeert een gefaalde container-delete tot
  een `::warning::` en sluit af met exit 0 — een groene job bewijst dus niet dat het deployment weg
  is. Daarom controleert de workflow ná de action de live deployment-lijst en faalt hard als het
  deployment er nog staat.
- **Beschermde namen** (`test`, `main`, `master`, `production`, `prod`) weigeren tenzij de
  workflow-input `allow_protected` aanstaat. Dat is een `if`-guard-stap vóór de action in
  `zad-cleanup.yml` — de action kent zelf geen beschermde-namen-check. Het cluster is
  **odcn-production** — dit voorkomt dat een losse hand de gedeelde `test`-singleton sloopt.
  Previews (`pr-<PR-nummer>`) ruim je vrij op.

## Beveiliging & versievastlegging

- **SHA-pinning dekt `zad-actions` zelf, niet alles eronder** (Scorecard Pinned-Dependencies):
  `zad-deploy-directory.yml` en `zad-cleanup.yml` gebruiken `RijksICTGilde/zad-actions/deploy` resp.
  `/cleanup`, beide SHA-gepind (`@13434cd4…` # v4.0.6). `zad-deploy-directory.yml` checkt daarnaast
  de repo uit met `actions/checkout` (al SHA-gepind, nodig voor `git diff` in de `changes`-job);
  `zad-cleanup.yml` heeft geen checkout-stap — die praat alleen met de ZAD-API. Binnen `zad-actions`
  zelf zijn twee stappen **niet** SHA-gepind: `astral-sh/setup-uv@v6` (mutable major-tag) en
  `zad-cli`, geïnstalleerd via `uv tool install git+https://github.com/RijksICTGilde/zad-cli.git@v0.8.0`
  (een mutable git-tag). Het is uiteindelijk `zad-cli` dat de ZAD-API-call uitvoert en dus de
  `api-key` te zien krijgt — die niet-SHA-gepinde keten valt buiten de Scorecard-dekking.
- **Geen secrets in de workflow-`run`**: de API-key gaat als action-input (`api-key:
  ${{ secrets.ZAD_API_KEY_DIRECTORY }}`), niet als losse env-var in een `run:`-stap; de
  `if`-guard in `zad-cleanup.yml` valideert de deployment-naam (`[a-z0-9-]`) tegen injectie vóór
  de action draait.
- **`api-key`** komt uit `secrets.ZAD_API_KEY_DIRECTORY` (write-only); nooit gelogd.

## Openstaand

- **Peer-deploys** (manager/inway/outway/txlog/controller) draaien in het app-repo op dezelfde
  manier: een eigen `deploy.yml` met `zad-actions/deploy` en een eigen `components:`-lijst. De
  component-definities + env-templates hier (`peers/*/values.example.yaml`, de lokale
  `deploy/local/docker-compose.yaml`) blijven de bron voor image- en env-namen.
- Een gedeelde **reusable `workflow_call`-cleanup** is bewust niet gedaan: dispatch (repo-secret)
  en call (doorgegeven secret) mengen in één workflow botst met de secrets-context. Elke app-repo
  roept `zad-actions/cleanup` rechtstreeks aan in een eigen dunne dispatch-workflow — simpeler en
  even reproduceerbaar, en er is niets meer te vendoren.
- **Task-timeout**: de deploy-actie gebruikt `task-timeout: '600'` (zie `zad-deploy-directory.yml`)
  — dezelfde ruimte als `PREVIEW_TASK_TIMEOUT` in `moza-poc-fbs-berichtenbox`, want verse
  preview-provisioning duurt langer dan een update. De cleanup-aanroepen in dit repo zetten
  `task-timeout` niet en draaien dus op de default van `zad-actions/cleanup` zelf (`300`); een
  cleanup heeft geen verse provisioning nodig, dus dat is bewust ongewijzigd gelaten.
