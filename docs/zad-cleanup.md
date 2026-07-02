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
| directory | `zad-deploy-directory.yml` → `deploy/zad/upsert-directory.sh` | `zad-cleanup.yml` → `deploy/zad/cleanup.sh` | **dit repo** |
| peer (magazijn/uitvraag/…) | app-repo's `deploy.yml` (peer náást de app) | app-repo kopieert `deploy/zad/cleanup.sh` | bij de app |

Beide scripts zijn **volledig env-gedreven** (`ZAD_PROJECT`, `ZAD_API_KEY`, `ZAD_BASE`), dus een
app-repo hergebruikt exact dezelfde `cleanup.sh` met zijn eigen project + key — geen fork nodig.
Dit is de "kopiëren + pinnen"-variant uit `zad-projecten.md`; het houdt de source-of-truth
(scripts + component-definities) hier, en de secrets bij de app.

## Deploy (directory)

Zie `docs/zad-directory-deploy.md`. Kort: `zad-deploy-directory.yml` (workflow_dispatch,
`validate|plan|apply`) roept `upsert-directory.sh` aan — `:upsert-deployment` + `POST /components`
(met env). Bijlagen (certs) + Publicatie-op-het-web blijven UI-werk (niet in de deploy-API).

## Cleanup (directory)

`zad-cleanup.yml` (workflow_dispatch) roept `deploy/zad/cleanup.sh` aan:

```bash
export ZAD_API_KEY=...                          # niet inline
./deploy/zad/cleanup.sh validate                # read-only: auth-check + lijst deployments
./deploy/zad/cleanup.sh plan   pr-123           # toont wat verwijderd wordt, muteert NIET
./deploy/zad/cleanup.sh apply  pr-123           # DELETE /api/v2/projects/{p}/pr-123 + pollt de task
```

- **Eenheid van cleanup = een héle deployment.** De v2-API kent geen losse component-delete;
  `DELETE …/{deployment}` ruimt de deployment (en zijn componenten) op. Async → task-polling.
- **Idempotent**: een niet-bestaande deployment = no-op (geen fout), zodat een cleanup-run
  veilig herhaalbaar is (bv. na een gefaalde PR-preview).
- **Beschermde namen** (`test`, `main`, `production`, …) weigeren tenzij `ALLOW_PROTECTED=1` /
  de workflow-input `allow_protected`. Het cluster is **odcn-production** — dit voorkomt dat een
  losse hand de gedeelde `test`-singleton sloopt. Previews (`pr-<PR-nummer>`) ruim je vrij op.

## Beveiliging & versievastlegging

- **SHA-pinned actions** (Scorecard Pinned-Dependencies): de curl-gebaseerde v2-API-workflows
  gebruiken alléén `actions/checkout` (al SHA-gepind). De legacy `deploy.yml` (marketplace-action
  `zad-actions/deploy`) is in #729 **SHA-gepind** (`@56ae5cc…` # v1); de actieve deploy loopt via
  de v2-API.
- **Geen secrets in de workflow-`run`**: inputs gaan via `env:` (`MODE`/`DEPLOYMENT`) en worden
  gequote; `cleanup.sh` valideert de deployment-naam (`[a-z0-9-]`) tegen injectie.
- **`X-API-Key`** komt uit `secrets.ZAD_API_KEY_DIRECTORY` (write-only); nooit gelogd.

## Openstaand

- **Full peer-deploy-scripts** (per-peer `upsert-<peer>.sh` met de manager/inway/outway/txlog/
  controller-componenten) leven bij de app-repo's; de component-definities + env-templates hier
  (`peers/*/values.example.yaml`, de lokale `deploy/local/docker-compose.yaml`) zijn de bron.
- Een gedeelde **reusable `workflow_call`-cleanup** is bewust niet gedaan: dispatch (repo-secret)
  en call (doorgegeven secret) mengen in één workflow botst met de secrets-context. Het kopiëren van
  `cleanup.sh` + een dunne dispatch-workflow bij de app is simpeler en even reproduceerbaar.
- **Follow-up**: `cleanup.sh`'s `poll_task` checkt de HTTP-code + faalt hard op een onbekende/
  timeout-status (geen valse "opgeruimd"). De deploy-tegenhanger `upsert-directory.sh` heeft nog de
  oudere `poll_task` (timeout → `return 0`, geen HTTP-code-check) en maskeert een gefaalde task met
  `… || { … }`; die verdient dezelfde hardening (aparte PR, raakt de #723-deploy).
