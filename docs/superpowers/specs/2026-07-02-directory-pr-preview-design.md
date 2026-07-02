# Ontwerp: automatische directory-PR-preview + cleanup-on-close

> Volgorde/status: infra-follow-up binnen epic
> [#737](https://github.com/MinBZK/MijnOverheidZakelijk/issues/737). Bouwt voort op de auto-deploy
> naar `test` (`docs/ontwerpkeuzes.md` §"Auto-deploy directory naar `test` op main") en spiegelt het
> preview-lifecycle-model van `moza-poc-fbs-berichtenbox` (`.github/workflows/deploy.yml`).

## Doel

Een PR die de centrale **directory** raakt krijgt automatisch een eigen, geïsoleerde
ZAD-deployment `pr-<PR-nummer>` op project `mft-tp9`; bij het sluiten van de PR wordt die
deployment (en de preview-image) weer opgeruimd. Zo kan een reviewer een directory-wijziging
functioneel beproeven vóór merge, zonder de gedeelde `test`-singleton te raken.

Vervangt het **handmatige** `workflow_dispatch`-pad als de gangbare manier om een preview te maken
(dat pad blijft bestaan voor ad-hoc/handmatige deploys en overrides).

## Achtergrond & vastgestelde feiten

- **Naamgeving:** preview-deployments heten `pr-<PR-nummer>` (= `github.event.pull_request.number`),
  níet naar het issuenummer. Het PR-nummer is de 1:1-vindbare bron van de deployment.
- **Bijlagen (cert-mount) + "Publicatie op het web" (passthrough-TLS modus 2) zijn
  project/component-niveau-config** op `mft-tp9`: **elk** deployment — ook een nieuwe `pr-<n>` —
  erft ze automatisch. Geen per-preview UI-stap. Bevestigd door de operator; bewezen door `pr-723`
  (self-announce SUCCEEDED op een `pr-<n>`-deployment).
- **DB = system-of-record, uitgezonderd van `clone-from: test`** (`docs/zad-projecten.md`). Een
  preview krijgt daarom zijn **eigen verse managed Postgres** (eigen deployment ⇒ eigen DB), doet
  `migrate up` en self-announce in zijn **eigen** lege peer-registry. Klonen/legen van de
  `test`-DB is verboden en niet nodig.
- **`SELF_ADDRESS` is al deployment-agnostisch** (`upsert-directory.sh`: `dirmgr-$DEPLOYMENT_NAME-…`,
  door ZAD per deployment ingevuld). De vaste bijlage-certs werken over deployment-namen heen
  (bewezen door `pr-723`), dus geen cert/hostnaam-mismatch.
- **Preview-image via de reusable `build`-call:** de bestaande `changes → build → deploy`-structuur
  in `zad-deploy-directory.yml` bouwt de `manager-migrate`-wrapper vóór de deploy in één run
  (ordering-veilig). Previews gebruiken hetzelfde pad.

## Scope

**In scope:** alleen de **centrale directory** (dit repo, project `mft-tp9`). Peers
(`example-provider`/`-consumer`) deployen bij hun app in eigen ZAD-projecten en beslissen daar zelf
over auto-preview — geen generiek peer-mechanisme hier.

**Verhouding tot de lopende PR (`fix/pr-deployment-naming`, #18):** die PR legde de conventie
`pr-<PR-nummer>` vast voor een handmatig getypte waarde. Met auto-naming wordt die waarde
**automatisch** gezet. De doc-edits blijven inhoudelijk correct (naam = PR-nummer) maar worden
**herschreven van "handmatige conventie" naar "automatisch via `pull_request`-trigger"**. Dit werk
gaat verder op dezelfde branch en de PR wordt van `fix(docs)` naar `feat` her-getiteld.

**Out of scope:** de `test`- en `main`-deploypaden (ongewijzigd); GitHub-`environment`-tracking
(zie Beslissing E); een required-check-gate vóór deploy (zie Beslissing F).

## Beslissingen

### A. Implementatie via de curl-scripts, niet de marketplace-action
De preview- en cleanup-stappen gebruiken de bestaande `deploy/zad/upsert-directory.sh` en
`deploy/zad/cleanup.sh` (al de gedeelde bron voor CLI + CI), **niet** `RijksICTGilde/zad-actions`.
Reden: `docs/ontwerpkeuzes.md` legt de keuze "geen marketplace-action → geen extra action-SHA te
pinnen → OpenSSF Scorecard Pinned-Dependencies groen" vast. "Net als berichtenbox" betreft het
*gedrag* (pr-preview + cleanup-on-close), niet de implementatie.

### B. Triggers en job-condities
`zad-deploy-directory.yml` krijgt naast de bestaande triggers een `pull_request`-trigger:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
  push:
    branches: [main]        # bestaand → test
  workflow_dispatch: …      # bestaand → handmatige override
```

| Event | Deployment | Mode | Job(s) |
|-------|-----------|------|--------|
| PR `opened`/`synchronize`/`reopened` | `pr-<n>` | `apply` | `changes → build → deploy-preview → comment` |
| PR `closed` | `pr-<n>` | — | `cleanup-preview` |
| push `main` | `test` | `apply` | bestaand `changes → build → deploy` |
| `workflow_dispatch` | input | input | bestaand |

- **`DEPLOYMENT`** = `pr-${{ github.event.pull_request.number }}` op een PR-event; anders het
  bestaande `inputs.deployment || 'test'`.
- **`concurrency.group`** neemt het PR-nummer op: `zad-deploy-directory-pr-<n>` (nu al
  `|| 'test'`); `cancel-in-progress: false` (een halve ZAD-deploy niet afbreken).
- **Fork-guard:** preview- en build-jobs skippen als
  `github.event.pull_request.head.repo.full_name != github.repository` — fork-PR's krijgen geen
  secrets, dus een deploy zou hoe dan ook falen. Intern MinBZK-repo, dus zeldzaam; luid loggen.

### C. Docs-only-skip
De bestaande `changes`-job (of een gelijkwaardige `git diff`/`gh api …/files`-stap) bepaalt of de
PR iets deploybaars raakt. Een docs-only PR (alleen `docs/**` of `*.md`) skipt de preview —
`skipped` telt als succes voor required checks, dus merge blijft mogelijk. Fail-safe: kan de
bestandenlijst niet opgehaald worden, dan **wel** deployen (niet stil overslaan).

### D. Volledig-functionele preview (geen handwerk)
Dankzij de project-niveau-bijlagen + web-publicatie (Achtergrond) is de preview volledig via de
API/CI op te zetten:
`upsert-directory.sh apply pr-<n> <manager-tag>` → eigen deployment + componenten (`dirmgr` +
`dirui`) + env + eigen managed DB; ZAD hangt bijlagen + :443-SNI-route (`dirmgr-pr-<n>-mft-tp9.…`)
automatisch aan. `migrate up && serve` komt op, self-announce slaagt. **Geen `clone-from`** (script
is zelf-voorzienend en de SoR-DB mag niet gekloond worden).

- **Manager-image:** raakt de PR de wrapper (`deploy/zad/manager-migrate/**`) → de `build`-job
  bouwt `manager-migrate:v1.43.7-<slug>` en de preview deployt die tag; anders de canonieke
  `v1.43.7`. Dit hergebruikt de bestaande `changes → build`-logica.

### E. PR-feedback via comment, geen GitHub-environment
Na een geslaagde preview-deploy plaatst/werkt de workflow een **PR-comment** bij met de preview-URL
(`gh pr comment`/`--edit-last` of een marker-gebaseerde upsert), met alleen `GITHUB_TOKEN`
(`pull-requests: write`). **Geen** GitHub-`environment`: dat vergt een `GH_ADMIN_TOKEN` (PAT) om de
environment bij PR-close op te ruimen (GITHUB_TOKEN mag dat niet). Comment-only vermijdt die
PAT-dependency; de ZAD-cleanup zelf heeft alleen `ZAD_API_KEY_DIRECTORY` nodig.

### F. Geen required-check-gate vóór deploy
De sibling pollt zijn functionele checks (`test`, `detekt`, …) vóór de preview. Dit repo heeft geen
functionele testsuite voor de directory; de required checks (`lint`, `Analyze (actions)`) zijn
statisch, en `migrate up`+`serve`+self-announce **ís** de functionele check (faalt zichtbaar in de
deploy). YAGNI: geen gate nu; later toe te voegen als er een directory-testsuite komt.

### G. Cleanup-on-close
Bij `pull_request: closed` draait een cleanup-job:
`cleanup.sh apply pr-<n>` — bestaat al, valideert de naam (`[a-z0-9-]`), is idempotent (niet-bestaand
= no-op) en weigert beschermde namen (`test`/`main`/`production`). Optioneel (parallel met de
sibling): de preview-image-tag `manager-migrate:v1.43.7-<slug>` uit ghcr verwijderen
(`packages: write`).

### H. Redundante branch-push-build opruimen
`build-manager-migrate.yml` heeft nu een `push: branches-ignore:[main]`-trigger die bestond "zodat
previews een branch-image hebben". Nu previews de image via de reusable `build`-call krijgen
(ordering-veilig, geen aparte race), is die standalone branch-push-build **redundant** en zou hij
dubbel bouwen. **Verwijder de `push`-trigger** uit `build-manager-migrate.yml`; `workflow_call`
(main + preview) en `workflow_dispatch` blijven.

## Componenten & data-flow

```text
pull_request (opened/synchronize/reopened)
  └─ changes  ─(wrapper gewijzigd?)→ build (reusable build-manager-migrate) ─→ deploy-preview
                                                                                  │
                                     upsert-directory.sh apply pr-<n> <tag>       │
                                     → ZAD: deployment pr-<n>, eigen DB,          │
                                       bijlagen+web-pub geërfd, migrate+serve     │
                                                                                  ▼
                                                                          comment (preview-URL)

pull_request (closed)
  └─ cleanup-preview → cleanup.sh apply pr-<n> → DELETE deployment (+ ghcr-tag)
```

Elke unit heeft één taak en een gedefinieerde interface:
- **`changes`** — bepaalt `run` (deploybaar?) + `manager_migrate_changed`. In: event/diff. Uit: bools.
- **`build`** (reusable) — bouwt+pusht de wrapper-image voor een tag. In: `image_tag`. Uit: image in ghcr.
- **`deploy-preview`** — roept `upsert-directory.sh apply pr-<n>` aan. In: secrets/env + tag. Uit: live deployment + URL.
- **`comment`** — upsert PR-comment. In: URL + PR-nummer. Uit: comment.
- **`cleanup-preview`** — roept `cleanup.sh apply pr-<n>` aan. In: secrets/env. Uit: opgeruimde deployment.

## Foutafhandeling

- **Deploy faalt** (migrate/serve/announce): de job faalt zichtbaar; geen comment met een dode URL.
  `upsert-directory.sh`'s `poll_task` heeft nog de oudere timeout→`return 0`-zwakte (bekend, aparte
  hardening in `docs/zad-cleanup.md` §Openstaand) — buiten scope hier, maar noemen in het plan.
- **Cleanup idempotent**: niet-bestaande `pr-<n>` = no-op, dus een herhaalde/late close faalt niet.
- **Fork-PR**: geskipt (geen secrets), luid gelogd.
- **Bestandenlijst niet op te halen** (docs-only-detectie): fail-safe deployen.

## Beveiliging

- Alle variabele inputs via `env:` + gequote (geen inline `${{ }}` in `run:`); `pull_request.number`
  is een integer (geen injectie). Conform de bestaande workflow-stijl + Scorecard.
- Least-privilege `permissions` per job: `deploy-preview` → `contents: read` +
  `pull-requests: write` (comment); `build`/`cleanup` → `packages: write` waar nodig.
- **Geen** `pull_request_target` (zou met secrets op untrusted fork-code draaien). Fork-PR's
  worden bewust geskipt i.p.v. via `_target` mogelijk gemaakt.
- `ZAD_API_KEY_DIRECTORY` blijft write-only secret; nooit gelogd. `cleanup.sh` valideert de
  deployment-naam tegen injectie.

## Testen / verificatie

Geen unit-tests (workflow + shell). Verificatie:
- **Lint**: `actionlint` + `yamllint` op de workflow; `shellcheck` op ongewijzigde scripts.
- **Dry-run**: `upsert-directory.sh plan pr-<n>` toont de bodies zonder te muteren.
- **End-to-end** (handmatig, één keer): open een test-PR die de directory raakt → controleer dat
  `pr-<n>` live komt (self-announce in de eigen DB, directory-ui bereikbaar op de `pr-<n>`-URL) →
  sluit de PR → controleer dat de deployment weg is.

## Openstaande punten (naar het plan)

- Precieze `if:`-condities per job (PR-event vs push vs dispatch) zonder de bestaande paden te breken.
- Comment-upsert-mechanisme (marker vs `--edit-last`).
- Wel/niet de ghcr-preview-tag opruimen bij close (Beslissing G, optioneel).
- Doc-updates: `ontwerpkeuzes.md` (preview nu automatisch), `zad-directory-deploy.md` +
  `zad-cleanup.md` (conventie herschreven), en de #18-edits herzien.
