# Design: auto-deploy directory naar `test` op main

> Status: ontwerp goedgekeurd (2026-07-02). Implementatie op branch
> `feature/auto-deploy-test-directory`.

## Doel

Een merge naar `main` (CI groen) rolt de centrale **directory** automatisch uit naar
ZAD-deployment `test`. Dit spiegelt het `moza-poc-fbs-berichtenbox`-model: geautomatiseerde
tests + eventueel functioneel op de preview-branch → main → automatische update van `test`.

Vandaag is `zad-deploy-directory.yml` **alleen** `workflow_dispatch` (handmatig). Alleen
`build-manager-migrate` draait automatisch bij een push (het bouwt de image, maar rolt niks uit).

## Scope

- **Alleen de centrale directory** (`zad-deploy-directory.yml` → deployment `test`).
- **Peers zijn buiten scope** — `example-consumer`/`-provider` deployen bij de app (eigen
  ZAD-projecten) en beslissen zélf of/hoe ze auto-deployen. Geen generiek peer-mechanisme hier.

## Keuzes (vastgelegd tijdens brainstorm)

| Keuze | Besluit | Waarom |
|-------|---------|--------|
| Workflow-vorm | **Bestaande `zad-deploy-directory.yml` uitbreiden** (niet nieuwe file) | DRY — `upsert-directory.sh` is al de gedeelde bron; push-pad zet enkel `apply`/`test`. |
| Build/deploy-ordering | **Eén workflow, 3 jobs** (`changes` → `build` → `deploy`) | Voorkomt de race waarbij deploy een oude image pullt vóór de build klaar is. |
| Build hergebruiken | **`build-manager-migrate` als reusable (`workflow_call`)** | Eén bron voor build-logica; behoudt eigen `push`-trigger voor PR-previews. |
| Wijziging detecteren | **`git diff` in een run-step** (geen marketplace-action) | Geen extra action-SHA te pinnen → OpenSSF Scorecard blijft groen. |
| Trigger-paths | `deploy/zad/upsert-directory.sh`, `deploy/zad/manager-migrate/**`, `group/**`, de workflow zelf | Precies wat de directory-deploy raakt; docs/peers-merges blijven stil. `group/**` erbij voor zichtbaarheid (meestal no-op via de API). |
| Failure-zichtbaarheid | **Kaal — rode workflow-run** in de Actions-tab | Test-omgeving; als dit ooit te vaak gemist wordt gaan we naar externe notificatie (Slack/mail), niet naar een half-oplossing (auto-issue). |
| Secret/gate | Bestaande `ZAD_API_KEY_DIRECTORY`, **géén** environment-approval | Bewust fully-auto, conform het FBS-model. |

## Workflow-vorm

`zad-deploy-directory.yml` krijgt náást `workflow_dispatch` een `push`-trigger:

```yaml
on:
  push:
    branches: [main]
    paths:
      - "deploy/zad/upsert-directory.sh"
      - "deploy/zad/manager-migrate/**"
      - "group/**"
      - ".github/workflows/zad-deploy-directory.yml"
  workflow_dispatch:
    inputs: { … ongewijzigd … }
```

Push-pad zet vast: `mode=apply`, `deployment=test`, `image_tag=v1.43.7`, `manager_tag=""`
(→ canonieke tag). `workflow_dispatch` blijft volledig ongewijzigd voor PR-previews
(validate/plan/apply, elke deployment).

## Jobs & ordering

Drie jobs, sequentieel:

```text
push→main ─┬─ job: changes   git diff HEAD^ HEAD → output manager_migrate_changed (true/false)
           │
           ├─ job: build      needs: changes; if manager_migrate_changed == 'true'
           │                   → workflow_call naar build-manager-migrate (canonieke v1.43.7)
           │
           └─ job: deploy     needs: [changes, build]
                              if: always() && build.result in {success, skipped}
                              → upsert-directory.sh apply test
```

- **`changes`** — `git diff --name-only HEAD^ HEAD` in een run-step (geen action-SHA). Zet output
  `manager_migrate_changed` op basis van of `deploy/zad/manager-migrate/**` in de merge zat.
- **`build`** — draait alleen bij een image-wijziging. Roept `build-manager-migrate` aan via een
  nieuwe `workflow_call`-trigger (single source; z'n eigen `push`-trigger blijft voor previews).
- **`deploy`** — `needs: [changes, build]` met `if: always() && (build.result == 'success' ||
  build.result == 'skipped')`. Draait ná build-succes, of meteen als de build ge-skipt is
  (config/group-only). Image bestaat dus gegarandeerd vóór `apply`.

**Ordering-garantie:** image-change → build eerst → deploy. Config/group-change → build skip →
deploy herbruikt de bestaande `v1.43.7`.

## Dispatch-samenloop, concurrency, secrets

- **`workflow_dispatch` ongewijzigd:** validate/plan/apply op elke deployment (PR-previews). Push-
  en dispatch-pad delen de deploy-job; inputs vs push-defaults via `${{ inputs.x || 'default' }}`.
- **Build bij dispatch:** de `changes`-job heeft geen merge-context (`HEAD^`) bij dispatch →
  `manager_migrate_changed=false`. Dispatch bouwt dus niet automatisch; wie een branch-image wil
  geeft `manager_tag` mee, zoals nu.
- **Concurrency:** group aanpassen naar `zad-deploy-directory-${{ inputs.deployment || 'test' }}`
  (bij push is er geen input). `cancel-in-progress: false` blijft — deploys niet halverwege killen.
- **Secret:** `ZAD_API_KEY_DIRECTORY` (bestaat al). Geen GitHub-environment/approval — fully-auto.

## Failure-zichtbaarheid

Rode workflow-run in de Actions-tab. Geen auto-issue of externe notificatie. Wordt dit ooit te
vaak gemist → externe notificatie (Slack/mail); niet nu.

## Documentatie

- `docs/ontwerpkeuzes.md` — besluit-blok "auto-deploy `test` op main" (waarom, scope, keuzes).
- `docs/zad-directory-deploy.md` — mechaniek (push-trigger, 3 jobs, path-filter, dispatch blijft
  voor previews).
- Deze spec.

## Niet in scope / toekomstig

- Peer-auto-deploy (peers beslissen zelf, eigen repo's/projecten).
- Externe deploy-notificatie (Slack/mail) — `TODO` zodra kale rode runs onvoldoende blijken.
- GitHub-environment met approval-gate — bewust niet, fully-auto.
