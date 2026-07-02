# Directory PR-preview + cleanup-on-close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Een PR die de directory raakt krijgt automatisch een ZAD-deployment `pr-<PR-nummer>`; bij PR-close wordt die opgeruimd.

**Architecture:** Breidt `zad-deploy-directory.yml` uit met een `pull_request`-trigger. Een `meta`-job leidt de deployment-naam + image-tag af; de bestaande `changes → build → deploy`-jobs krijgen PR-condities; een nieuwe `cleanup-preview`-job draait bij close. Alles via de bestaande curl-scripts (`upsert-directory.sh`/`cleanup.sh`), geen marketplace-action. `build-manager-migrate.yml` wordt vereenvoudigd (redundante branch-push-build eruit, expliciete `image_suffix`-input erin).

**Tech Stack:** GitHub Actions (YAML), bash, `gh` CLI, ZAD v2 Operations Manager API (via de repo-scripts).

## Global Constraints

- **Naamgeving:** preview-deployment = `pr-<PR-nummer>` (= `github.event.pull_request.number`), nooit issuenummer.
- **Geen marketplace-action** in deploy/cleanup — alleen `actions/checkout` (SHA-gepind) + run-steps. OpenSSF Scorecard Pinned-Dependencies moet groen blijven.
- **Geen secrets in `run:`** — variabele inputs via `env:` en gequote. `pull_request.number` is een integer.
- **Geen `pull_request_target`.** Fork-PR's worden geskipt (geen secrets), niet via `_target` mogelijk gemaakt.
- **SoR-DB niet klonen/legen:** previews gebruiken **geen** `clone-from` (eigen verse managed DB).
- **`main`/`test`/`push`-pad ongewijzigd van gedrag:** push→`test`, `apply`.
- **Least-privilege `permissions`** per job.
- **Actions SHA-gepind** zoals in de bestaande files (checkout `@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` # v7.0.0).
- Verificatie van workflows = `actionlint` + `yamllint` + `shellcheck` (er is geen workflow-unittest); functioneel = handmatige e2e (Task 9).

---

### Task 1: `build-manager-migrate.yml` — redundante push-build weg, expliciete `image_suffix`

**Files:**
- Modify: `.github/workflows/build-manager-migrate.yml`

**Interfaces:**
- Produces: reusable workflow met inputs `image_tag` (OpenFSC-basis + build-arg, default `v1.43.7`) en `image_suffix` (default `''`). Pusht `ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:<image_tag>[-<image_suffix>]`; bij lege suffix de canonieke `<image_tag>`.

- [ ] **Step 1: Verwijder de `push`-trigger en vervang de tag-logica**

Vervang het `on:`-blok (regels 12-33) zodat alleen `workflow_dispatch` + `workflow_call` overblijven, beide met een extra `image_suffix`-input:

```yaml
on:
  # Aangeroepen door zad-deploy-directory (build-job) vóór een deploy: main -> canonieke tag,
  # PR -> pr-<n>-suffix. De losse branch-push-build is vervallen: previews bouwen nu via deze
  # workflow_call (ordering-veilig in één run), dus een aparte push-build zou dubbel bouwen.
  workflow_dispatch:
    inputs:
      image_tag:
        description: "OpenFSC manager-basisversie (build-arg IMAGE_TAG + image-tag)"
        required: false
        default: "v1.43.7"
      image_suffix:
        description: "optioneel: tag-suffix (bv. pr-42); leeg = canonieke tag"
        required: false
        default: ""
  workflow_call:
    inputs:
      image_tag:
        description: "OpenFSC manager-basisversie (build-arg IMAGE_TAG + image-tag)"
        required: false
        type: string
        default: "v1.43.7"
      image_suffix:
        description: "optioneel: tag-suffix (bv. pr-42); leeg = canonieke tag"
        required: false
        type: string
        default: ""
```

- [ ] **Step 2: Vervang de build-run-step-logica**

Vervang in de `Build en push`-step het `env:`-blok + `run:`-script (regels 56-82) door suffix-gebaseerde tagging:

```yaml
        env:
          IMAGE: ghcr.io/minbzk/moza-fsc-testnet/manager-migrate
          IMAGE_TAG: ${{ inputs.image_tag || 'v1.43.7' }}
          IMAGE_SUFFIX: ${{ inputs.image_suffix }}
          REPO: ${{ github.repository }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GH_ACTOR: ${{ github.actor }}
        run: |
          set -euo pipefail
          if [ -n "$IMAGE_SUFFIX" ]; then
            tag="${IMAGE_TAG}-${IMAGE_SUFFIX}"
          else
            tag="${IMAGE_TAG}"
          fi
          echo "$GH_TOKEN" | docker login ghcr.io -u "$GH_ACTOR" --password-stdin
          docker buildx build \
            --build-arg "IMAGE_TAG=${IMAGE_TAG}" \
            --tag "${IMAGE}:${tag}" \
            --label "org.opencontainers.image.source=https://github.com/${REPO}" \
            --push \
            deploy/zad/manager-migrate
          echo "Gepusht: ${IMAGE}:${tag}"
```

- [ ] **Step 3: Verifieer lint**

Run: `actionlint .github/workflows/build-manager-migrate.yml && yamllint .github/workflows/build-manager-migrate.yml`
Expected: geen output (exit 0).

- [ ] **Step 4: Verifieer dat `push` weg is en de inputs kloppen**

Run: `grep -c 'branches-ignore' .github/workflows/build-manager-migrate.yml; grep -c 'image_suffix' .github/workflows/build-manager-migrate.yml`
Expected: eerste regel `0`, tweede regel `4` (2× dispatch/call input-definitie + 2× env/gebruik... minimaal `>=3`).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-manager-migrate.yml
git commit -m "refactor(ci): manager-migrate build via image_suffix; losse branch-push-build weg

De preview-image bouwt nu via de reusable workflow_call in zad-deploy-directory
(ordering-veilig), waardoor de aparte push-branch-build redundant was en dubbel
zou bouwen. Tag-suffix wordt expliciet meegegeven (main=canoniek, PR=pr-<n>).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `zad-deploy-directory.yml` — `pull_request`-trigger, `meta`-job, concurrency

**Files:**
- Modify: `.github/workflows/zad-deploy-directory.yml`

**Interfaces:**
- Produces: `meta`-job met outputs `deployment` (`test` | `pr-<n>` | dispatch-input), `image_base` (`v1.43.7` of dispatch-input), `manager_suffix` (`''` | `pr-<n>`).

- [ ] **Step 1: Voeg de `pull_request`-trigger toe**

Voeg in `on:` (na het `push`-blok, vóór `workflow_dispatch`) toe:

```yaml
  pull_request:
    types: [opened, synchronize, reopened, closed]
```

- [ ] **Step 2: Werk de kop-comment bij**

Vervang regel 3 (`# apply upsert het deployment. Model: PR = eigen deployment ...`) door:

```yaml
# `apply` upsert het deployment. Model: push main -> `test`; PR -> preview `pr-<PR-nummer>`
# (open/sync = deploy, close = cleanup); workflow_dispatch = handmatige override.
```

- [ ] **Step 3: Update de `concurrency.group` voor PR's**

Vervang het `concurrency`-blok (regels 47-50) door:

```yaml
concurrency:
  # Eén run per deployment tegelijk: PR -> pr-<n>, push/dispatch -> test/input. Deploys niet
  # halverwege killen (een halve ZAD-deploy laat een inconsistente staat achter).
  group: zad-deploy-directory-${{ github.event.pull_request.number && format('pr-{0}', github.event.pull_request.number) || inputs.deployment || 'test' }}
  cancel-in-progress: false
```

- [ ] **Step 4: Voeg de `meta`-job toe** (als eerste job, vóór `changes`)

```yaml
jobs:
  # Afgeleide waarden op één plek: deployment-naam, OpenFSC-basistag, manager-image-suffix.
  meta:
    runs-on: ubuntu-latest
    outputs:
      deployment: ${{ steps.m.outputs.deployment }}
      image_base: ${{ steps.m.outputs.image_base }}
      manager_suffix: ${{ steps.m.outputs.manager_suffix }}
    steps:
      - id: m
        env:
          EVENT: ${{ github.event_name }}
          PR: ${{ github.event.pull_request.number }}
          INPUT_DEPLOYMENT: ${{ inputs.deployment }}
          INPUT_IMAGE_TAG: ${{ inputs.image_tag }}
        run: |
          set -euo pipefail
          image_base="${INPUT_IMAGE_TAG:-v1.43.7}"
          if [ "$EVENT" = "pull_request" ]; then
            deployment="pr-${PR}"
            manager_suffix="pr-${PR}"
          else
            deployment="${INPUT_DEPLOYMENT:-test}"
            manager_suffix=""
          fi
          {
            echo "deployment=${deployment}"
            echo "image_base=${image_base}"
            echo "manager_suffix=${manager_suffix}"
          } >> "$GITHUB_OUTPUT"
```

- [ ] **Step 5: Verifieer lint**

Run: `actionlint .github/workflows/zad-deploy-directory.yml && yamllint .github/workflows/zad-deploy-directory.yml`
Expected: geen output (exit 0). (De `changes`/`build`/`deploy`-jobs staan er nog ongewijzigd; lint moet groen zijn.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/zad-deploy-directory.yml
git commit -m "feat(ci): pull_request-trigger + meta-job voor directory-preview

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `zad-deploy-directory.yml` — `changes`-job herzien (run + changed voor alle events)

**Files:**
- Modify: `.github/workflows/zad-deploy-directory.yml` (`changes`-job)

**Interfaces:**
- Consumes: —
- Produces: `changes`-job outputs `run` (`true`/`false` — moet er gedeployd worden?) en `manager_migrate_changed` (`true`/`false` — wrapper gewijzigd → build nodig?).

- [ ] **Step 1: Vervang de `changes`-job**

Vervang de hele `changes`-job (het bestaande blok met `Detecteer manager-migrate-wijziging`) door één classificatie-step die beide outputs voor alle events zet:

```yaml
  # Bepaalt of er gedeployd moet worden (run) + of de manager-migrate-wrapper wijzigde
  # (build nodig). PR: via de bestandenlijst (docs-only skip, fork skip, close skip).
  # push: git diff. dispatch: run=true, changed=false (geef desnoods manager_tag mee).
  changes:
    runs-on: ubuntu-latest
    outputs:
      run: ${{ steps.c.outputs.run }}
      manager_migrate_changed: ${{ steps.c.outputs.changed }}
    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false
          fetch-depth: 0
      - name: Classificeer de run
        id: c
        env:
          EVENT: ${{ github.event_name }}
          ACTION: ${{ github.event.action }}
          IS_FORK: ${{ github.event.pull_request.head.repo.full_name != github.repository }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO: ${{ github.repository }}
          PR: ${{ github.event.pull_request.number }}
          BEFORE: ${{ github.event.before }}
          SHA: ${{ github.sha }}
        run: |
          set -euo pipefail
          emit() { { echo "run=$1"; echo "changed=$2"; } >> "$GITHUB_OUTPUT"; }

          case "$EVENT" in
            workflow_dispatch)
              # Handmatig: deploy wat de operator vraagt; bouw niet automatisch.
              emit true false; exit 0 ;;
            pull_request)
              # Close = teardown (geen deploy; cleanup-job handelt dit af).
              [ "$ACTION" = "closed" ] && { emit false false; exit 0; }
              # Fork-PR heeft geen secrets -> deploy zou falen; skip luid.
              if [ "$IS_FORK" = "true" ]; then
                echo "::warning::Fork-PR — preview overgeslagen (geen secrets)."
                emit false false; exit 0
              fi
              # Bestandenlijst; fail-safe: niet op te halen -> tóch deployen + bouwen.
              if ! files=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[].filename'); then
                echo "::warning::Kon gewijzigde bestanden niet ophalen — fail-safe deploy."
                emit true true; exit 0
              fi
              # run: iets anders dan docs/*.md gewijzigd?
              if printf '%s\n' "$files" | grep -qvE '(^docs/|\.md$)'; then run=true; else run=false; fi
              # changed: raakt de wrapper?
              if printf '%s\n' "$files" | grep -q '^deploy/zad/manager-migrate/'; then changed=true; else changed=false; fi
              emit "$run" "$changed"; exit 0 ;;
            push)
              # main: altijd deployen. Wrapper gewijzigd sinds vorige push?
              if [ -z "$BEFORE" ] || [ "$BEFORE" = "0000000000000000000000000000000000000000" ]; then
                emit true true; exit 0
              fi
              if git diff --name-only "$BEFORE" "$SHA" | grep -q '^deploy/zad/manager-migrate/'; then
                emit true true
              else
                emit true false
              fi
              exit 0 ;;
            *)
              emit true false; exit 0 ;;
          esac
```

- [ ] **Step 2: Verifieer lint (incl. shellcheck van het run-script)**

Run: `actionlint .github/workflows/zad-deploy-directory.yml && yamllint .github/workflows/zad-deploy-directory.yml`
Expected: geen output. (`actionlint` draait `shellcheck` op de run-steps; SC-fouten falen hier.)

- [ ] **Step 3: Verifieer de docs-only-logica lokaal**

Run:
```bash
printf 'docs/x.md\nREADME.md\n' | grep -qvE '(^docs/|\.md$)'; echo "docs-only run? exit=$? (1=skip)"
printf 'docs/x.md\ndeploy/zad/manager-migrate/Dockerfile\n' | grep -q '^deploy/zad/manager-migrate/'; echo "wrapper? exit=$? (0=build)"
```
Expected: eerste `exit=1` (docs-only → geen niet-docs → run=false), tweede `exit=0` (wrapper geraakt → changed=true).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/zad-deploy-directory.yml
git commit -m "feat(ci): changes-job classificeert run/changed voor push+PR+dispatch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `zad-deploy-directory.yml` — `build`- en `deploy`-job condities + preview-tag

**Files:**
- Modify: `.github/workflows/zad-deploy-directory.yml` (`build`- en `deploy`-job)

**Interfaces:**
- Consumes: `meta.outputs.{deployment,image_base,manager_suffix}`, `changes.outputs.{run,manager_migrate_changed}`.
- Produces: live ZAD-deployment (`test`/`pr-<n>`).

- [ ] **Step 1: Werk de `build`-job bij**

Vervang de `build`-job (`needs`, `if`, `with`) door:

```yaml
  build:
    needs: [meta, changes]
    if: ${{ needs.changes.outputs.run == 'true' && needs.changes.outputs.manager_migrate_changed == 'true' }}
    permissions:
      contents: read
      packages: write
    uses: ./.github/workflows/build-manager-migrate.yml
    with:
      image_tag: ${{ needs.meta.outputs.image_base }}
      image_suffix: ${{ needs.meta.outputs.manager_suffix }}
```

- [ ] **Step 2: Werk de `deploy`-job `needs` + `if` bij**

```yaml
  deploy:
    needs: [meta, changes, build]
    if: >-
      ${{ always() && needs.changes.outputs.run == 'true'
          && needs.changes.result == 'success'
          && (needs.build.result == 'success' || needs.build.result == 'skipped') }}
    runs-on: ubuntu-latest
```

- [ ] **Step 3: Werk het `env:`-blok van de deploy-step bij**

Vervang het `env:`-blok (`ZAD_API_KEY` … `CLONE_FROM`) door:

```yaml
        env:
          ZAD_API_KEY: ${{ secrets.ZAD_API_KEY_DIRECTORY }}
          ZAD_PROJECT: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
          # push/PR = altijd apply; dispatch gebruikt zijn mode-input.
          MODE: ${{ github.event_name == 'workflow_dispatch' && inputs.mode || 'apply' }}
          DEPLOYMENT: ${{ needs.meta.outputs.deployment }}
          IMAGE_TAG: ${{ needs.meta.outputs.image_base }}
          # PR met gewijzigde wrapper -> de zojuist gebouwde pr-<n>-image; anders leeg (canoniek).
          ZAD_MANAGER_TAG: ${{ (github.event_name == 'pull_request' && needs.changes.outputs.manager_migrate_changed == 'true') && format('{0}-{1}', needs.meta.outputs.image_base, needs.meta.outputs.manager_suffix) || inputs.manager_tag }}
          # Previews klonen NIET (SoR-DB uitgezonderd); dispatch mag clone_from meegeven.
          CLONE_FROM: ${{ github.event_name == 'workflow_dispatch' && inputs.clone_from || '' }}
        run: ./deploy/zad/upsert-directory.sh "${MODE}" "${DEPLOYMENT}" "${IMAGE_TAG}" "${CLONE_FROM}"
```

- [ ] **Step 4: Verifieer lint**

Run: `actionlint .github/workflows/zad-deploy-directory.yml && yamllint .github/workflows/zad-deploy-directory.yml`
Expected: geen output.

- [ ] **Step 5: Verifieer de tag-expressie-consistentie**

Run: `grep -n "manager_suffix\|image_base\|meta.outputs.deployment" .github/workflows/zad-deploy-directory.yml`
Expected: `deploy` gebruikt `needs.meta.outputs.deployment`, `image_base` en (in `ZAD_MANAGER_TAG`) `manager_suffix`; `build` gebruikt `image_base` + `manager_suffix`. Namen exact gelijk aan de `meta`-outputs uit Task 2.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/zad-deploy-directory.yml
git commit -m "feat(ci): deploy-job leidt deployment/tag af voor test+preview

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `zad-deploy-directory.yml` — PR-comment met preview-URL

**Files:**
- Modify: `.github/workflows/zad-deploy-directory.yml` (`deploy`-job: `permissions` + extra step)

**Interfaces:**
- Consumes: `meta.outputs.deployment`.
- Produces: een (ge-upsert) PR-comment met de directory-ui-preview-URL.

- [ ] **Step 1: Geef de `deploy`-job comment-rechten**

Voeg onder de `deploy`-job (naast `runs-on`) toe:

```yaml
    permissions:
      contents: read
      pull-requests: write
```

- [ ] **Step 2: Voeg na de deploy-step een comment-step toe** (alleen op PR-events)

```yaml
      - name: Preview-URL als PR-comment (upsert)
        if: ${{ github.event_name == 'pull_request' }}
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO: ${{ github.repository }}
          PR: ${{ github.event.pull_request.number }}
          DEPLOYMENT: ${{ needs.meta.outputs.deployment }}
          PROJECT: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
          BASE_DOMAIN: ${{ vars.ZAD_BASE_DOMAIN || 'rig.prd1.gn2.quattro.rijksapps.nl' }}
        run: |
          set -euo pipefail
          marker="<!-- fsc-directory-preview -->"
          ui="https://dirui-${DEPLOYMENT}-${PROJECT}.${BASE_DOMAIN}"
          mgr="https://dirmgr-${DEPLOYMENT}-${PROJECT}.${BASE_DOMAIN}"
          body="${marker}
          ### FSC directory-preview \`${DEPLOYMENT}\`
          - directory-ui: ${ui}
          - manager (SNI): ${mgr}
          _Wordt automatisch opgeruimd bij het sluiten van deze PR._"
          # Bestaand marker-comment zoeken en updaten; anders een nieuw comment plaatsen.
          id=$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
                --jq "map(select(.body | startswith(\"$marker\"))) | .[0].id // empty")
          if [ -n "$id" ]; then
            gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$body" >/dev/null
          else
            gh api -X POST "repos/$REPO/issues/$PR/comments" -f body="$body" >/dev/null
          fi
          echo "Preview: $ui"
```

- [ ] **Step 3: Verifieer lint**

Run: `actionlint .github/workflows/zad-deploy-directory.yml && yamllint .github/workflows/zad-deploy-directory.yml`
Expected: geen output.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/zad-deploy-directory.yml
git commit -m "feat(ci): PR-comment met directory-preview-URL (upsert)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `zad-deploy-directory.yml` — `cleanup-preview`-job bij PR-close

**Files:**
- Modify: `.github/workflows/zad-deploy-directory.yml` (nieuwe job)

**Interfaces:**
- Consumes: `meta.outputs.deployment`.
- Produces: opgeruimde ZAD-deployment + (optioneel) verwijderde ghcr preview-tag.

- [ ] **Step 1: Voeg de `cleanup-preview`-job toe** (na `deploy`)

```yaml
  # PR gesloten -> preview opruimen. Onafhankelijk van changes/deploy (die skippen op close).
  cleanup-preview:
    if: ${{ github.event_name == 'pull_request' && github.event.action == 'closed'
            && github.event.pull_request.head.repo.full_name == github.repository }}
    needs: meta
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false
      - name: Ruim de preview-deployment op
        env:
          ZAD_API_KEY: ${{ secrets.ZAD_API_KEY_DIRECTORY }}
          ZAD_PROJECT: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
          DEPLOYMENT: ${{ needs.meta.outputs.deployment }}
        run: ./deploy/zad/cleanup.sh apply "${DEPLOYMENT}"
      - name: Verwijder de ghcr preview-image-tag (idempotent)
        continue-on-error: true
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SUFFIX: ${{ needs.meta.outputs.manager_suffix }}
          IMAGE_BASE: ${{ needs.meta.outputs.image_base }}
        run: |
          set -euo pipefail
          tag="${IMAGE_BASE}-${SUFFIX}"
          # Version-id van de tag opzoeken in het org-package; niet gevonden = niets te doen.
          vid=$(gh api --paginate \
            "orgs/minbzk/packages/container/moza-fsc-testnet%2Fmanager-migrate/versions" \
            --jq "map(select(.metadata.container.tags[]? == \"$tag\")) | .[0].id // empty" || true)
          if [ -n "$vid" ]; then
            gh api -X DELETE "orgs/minbzk/packages/container/moza-fsc-testnet%2Fmanager-migrate/versions/$vid" && \
              echo "ghcr-tag $tag verwijderd" || echo "::warning::ghcr-tag $tag niet verwijderd (rechten?)"
          else
            echo "geen ghcr-tag $tag — niets op te ruimen"
          fi
```

- [ ] **Step 2: Verifieer lint**

Run: `actionlint .github/workflows/zad-deploy-directory.yml && yamllint .github/workflows/zad-deploy-directory.yml`
Expected: geen output.

- [ ] **Step 3: Verifieer de cleanup-naamvalidatie werkt met `pr-<n>`**

Run: `bash -n deploy/zad/cleanup.sh && printf 'pr-42' | grep -qE '^[a-z0-9-]+$' && echo "naam ok"`
Expected: `naam ok` (script-syntax valide + `pr-42` voldoet aan de `[a-z0-9-]`-validatie in `cleanup.sh`).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/zad-deploy-directory.yml
git commit -m "feat(ci): cleanup-preview-job ruimt pr-<n> op bij PR-close

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Documentatie bijwerken (auto-preview i.p.v. handmatige conventie)

**Files:**
- Modify: `docs/ontwerpkeuzes.md` (§"Auto-deploy directory naar `test` op main")
- Modify: `docs/zad-directory-deploy.md` (Deploymodel-noot + status-noot)
- Modify: `docs/zad-cleanup.md` (cleanup nu ook automatisch bij PR-close)

**Interfaces:** —

- [ ] **Step 1: `ontwerpkeuzes.md` — preview nu automatisch**

Vervang in de §"Auto-deploy" de zin uit de eerste bullet
(`... \`workflow_dispatch\` blijft voor PR-previews.`) door:

```markdown
- **Bestaande workflow uitbreiden** (niet een nieuwe file): `zad-deploy-directory.yml` krijgt náást
  `workflow_dispatch` een `push`-trigger op main én een `pull_request`-trigger. Een PR
  (`opened`/`synchronize`/`reopened`) rolt automatisch een preview `pr-<PR-nummer>` uit; bij
  `closed` ruimt een `cleanup-preview`-job die op. `workflow_dispatch` blijft voor handmatige
  overrides. `upsert-directory.sh`/`cleanup.sh` zijn de gedeelde bron.
```

- [ ] **Step 2: `ontwerpkeuzes.md` — noteer de preview-eigenschappen**

Voeg onderaan de §"Auto-deploy" toe:

```markdown
**PR-preview-eigenschappen:** eigen deployment `pr-<PR-nummer>` met een eigen verse managed DB
(de SoR-`test`-DB wordt niet gekloond/geleegd). Bijlagen (cert-mount) en "Publicatie op het web"
zitten op project/component-niveau en worden per deployment automatisch geërfd — geen handwerk per
PR. Fork-PR's worden geskipt (geen secrets). Docs-only PR's deployen niet.
```

- [ ] **Step 3: `zad-directory-deploy.md` — Deploymodel-noot herschrijven**

Vervang in de Deploymodel-`>`-noot de slotzin
(`... Een PR-preview gebruikt zijn eigen \`pr-<PR-nummer>\`-deployment i.p.v. \`test\`.`) door:

```markdown
> Een PR rolt **automatisch** een preview `pr-<PR-nummer>` uit (`pull_request`-trigger); bij het
> sluiten van de PR wordt die weer opgeruimd. `pr-<PR-nummer>` = het PR-nummer, niet het issuenummer.
```

- [ ] **Step 4: `zad-directory-deploy.md` — status-noot bijwerken**

Vervang de annotatie bij de live-status (`deployment \`pr-723\` — nog naar het issuenummer benoemd; ...`) door:

```markdown
> **Status (2026-06-30): directory LIVE op ZAD** (deployment `pr-723` — nog met de oude
> issuenummer-naam; auto-previews heten voortaan `pr-<PR-nummer>`). `migrate up` ok tegen de
```

- [ ] **Step 5: `zad-cleanup.md` — cleanup nu ook automatisch**

Voeg onder de `## Cleanup (directory)`-kop, vóór het codeblok, toe:

```markdown
Bij het **sluiten van een PR** ruimt `zad-deploy-directory.yml` (job `cleanup-preview`) de
`pr-<PR-nummer>`-deployment automatisch op via ditzelfde `cleanup.sh`. Handmatig
(`zad-cleanup.yml` / CLI) blijft mogelijk voor overige gevallen:
```

- [ ] **Step 6: Verifieer markdownlint**

Run: `npx --no-install markdownlint-cli2 docs/ontwerpkeuzes.md docs/zad-directory-deploy.md docs/zad-cleanup.md`
Expected: `Summary: 0 error(s)`.

- [ ] **Step 7: Commit**

```bash
git add docs/ontwerpkeuzes.md docs/zad-directory-deploy.md docs/zad-cleanup.md
git commit -m "docs(zad): directory-preview + cleanup nu automatisch via pull_request

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: PR her-titelen + volledige lint-sweep

**Files:** — (git/gh + verificatie)

**Interfaces:** —

- [ ] **Step 1: Volledige lint-sweep over alle geraakte files**

Run:
```bash
actionlint .github/workflows/zad-deploy-directory.yml .github/workflows/build-manager-migrate.yml
yamllint .github/workflows/zad-deploy-directory.yml .github/workflows/build-manager-migrate.yml
npx --no-install markdownlint-cli2 docs/ontwerpkeuzes.md docs/zad-directory-deploy.md docs/zad-cleanup.md
shellcheck deploy/zad/upsert-directory.sh deploy/zad/cleanup.sh
```
Expected: geen fouten (shellcheck: alleen de pre-existing SC2016-info op `upsert-directory.sh:46`, geen nieuwe).

- [ ] **Step 2: Push + PR her-titelen naar `feat`**

```bash
git push
gh pr edit 18 \
  --title "feat(ci): automatische directory-PR-preview + cleanup-on-close" \
  --body-file - <<'EOF'
## Waarom

PR-preview-deployments van de directory worden nu **automatisch** aangemaakt (`pr-<PR-nummer>`) bij
het openen/updaten van een PR en opgeruimd bij het sluiten — spiegelt het lifecycle-model van
`moza-poc-fbs-berichtenbox`, met onze curl-scripts i.p.v. de marketplace-action. Vervangt het
handmatige `workflow_dispatch`-only pad als gangbare manier.

Ontwerp: `docs/superpowers/specs/2026-07-02-directory-pr-preview-design.md`
Plan: `docs/superpowers/plans/2026-07-02-directory-pr-preview.md`

## Wat

- `zad-deploy-directory.yml`: `pull_request`-trigger, `meta`-job (deployment/tag), `changes`-gate
  (docs-only/fork/close), preview-deploy via `upsert-directory.sh apply pr-<n>`, PR-comment met
  URL, `cleanup-preview`-job via `cleanup.sh` bij close.
- `build-manager-migrate.yml`: losse branch-push-build vervangen door reusable `image_suffix`-build
  (ordering-veilig, geen dubbele build).
- Docs bijgewerkt (auto-preview i.p.v. handmatige conventie).

**Naamgeving = PR-nummer, niet issuenummer** (de oorspronkelijke aanleiding).

## Verificatie

`actionlint` + `yamllint` + `markdownlint` + `shellcheck` groen. Functionele e2e: zie Task 9 in het plan.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

Expected: PR #18 her-getiteld, body bijgewerkt, checks (`lint`, `Analyze (actions)`) draaien.

---

### Task 9: Handmatige end-to-end-verificatie (na merge-gereed, vóór definitief mergen)

**Files:** — (handmatig op ZAD)

Workflows zijn niet lokaal functioneel te testen (secrets + live ZAD). Deze e2e draait op een echte
test-PR en is de functionele acceptatie.

- [ ] **Step 1: Open een test-PR** die de directory raakt (bv. een triviale wijziging in `group/**`
  of `deploy/zad/manager-migrate/**`) tegen `main`.

- [ ] **Step 2: Controleer de preview-deploy.** In de Actions-run van `zad-deploy-directory`:
  `deploy`-job groen; er verschijnt een PR-comment met `dirui-pr-<n>-…`-URL.

- [ ] **Step 3: Controleer functioneel.** Open de directory-ui-URL uit de comment (bereikbaar via de
  automatisch geërfde web-publicatie). Optioneel: `psql` op de preview-DB →
  `SELECT id,name FROM peers.peers;` toont de self-announce-rij `00000000000000000010`/`directory`.

- [ ] **Step 4: Sluit de PR.** Controleer dat de `cleanup-preview`-job draait en de
  `pr-<n>`-deployment weg is (Operations Manager UI of `cleanup.sh validate`).

- [ ] **Step 5: Regressie test-pad.** Bevestig dat een merge naar `main` nog steeds `test` bijwerkt
  (het push-pad ongewijzigd).

---

## Self-Review

**Spec-dekking:**
- Naamgeving `pr-<n>` → Task 2 (`meta`), Global Constraints. ✓
- Curl-scripts, geen marketplace-action (Besl. A) → Tasks 4/6 gebruiken `upsert-directory.sh`/`cleanup.sh`. ✓
- Triggers + condities (Besl. B) → Tasks 2/3/4. ✓
- Docs-only-skip (Besl. C) → Task 3. ✓
- Volledig-functionele preview, geen clone-from (Besl. D) → Task 4 (`CLONE_FROM=''`, `ZAD_MANAGER_TAG`). ✓
- PR-comment, geen environment (Besl. E) → Task 5. ✓
- Geen check-gate (Besl. F) → bewust niet geïmplementeerd; genoemd. ✓
- Cleanup-on-close (Besl. G) → Task 6. ✓
- Redundante branch-push-build weg (Besl. H) → Task 1. ✓
- Fork-guard → Tasks 3 (run=false) + 6 (cleanup-if). ✓
- Verhouding tot #18 (her-titelen, docs herzien) → Tasks 7/8. ✓

**Placeholder-scan:** geen TBD/TODO in de stappen; alle code-blokken concreet. ✓

**Type-/naam-consistentie:** `meta.outputs.{deployment,image_base,manager_suffix}` gedefinieerd in Task 2 en exact zo geconsumeerd in Tasks 4/5/6. `changes.outputs.{run,manager_migrate_changed}` in Task 3, geconsumeerd in Task 4. `build-manager-migrate` input `image_suffix` in Task 1, geleverd in Task 4. ✓
