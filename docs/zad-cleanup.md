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
- **Beschermde namen** (`test`, `main`, `master`, `production`, `prod`) weigeren tenzij de
  workflow-input `allow_protected` aanstaat. Dat is een `if`-guard-stap vóór de action in
  `zad-cleanup.yml` — de action kent zelf geen beschermde-namen-check. Het cluster is
  **odcn-production** — dit voorkomt dat een losse hand de gedeelde `test`-singleton sloopt.
  Previews (`pr-<PR-nummer>`) ruim je vrij op.

## Beveiliging & versievastlegging

- **SHA-pinned actions** (Scorecard Pinned-Dependencies): `zad-deploy-directory.yml` en
  `zad-cleanup.yml` gebruiken `RijksICTGilde/zad-actions/deploy` resp. `/cleanup`, beide
  SHA-gepind (`@13434cd4…` # v4.0.6), plus `actions/checkout` (al SHA-gepind).
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
  preview-provisioning duurt langer dan een update. `zad-actions/cleanup` kent zelf geen
  timeout-knop; falen daar is direct zichtbaar als rode run in de Actions-tab.
