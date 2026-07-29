# Deploy via `zad-actions` — Implementatieplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alle ZAD-mutaties van dit repo laten lopen via `RijksICTGilde/zad-actions`, zodat het
deploy-pad gelijk is aan `moza-poc-fbs-berichtenbox`, en de eigen curl-scripts verwijderen.

**Architecture:** `zad-deploy-directory.yml` houdt zijn jobstructuur (`meta` → `changes` → `build`
→ `deploy`/`cleanup-preview`), maar de twee `run: ./deploy/zad/*.sh`-stappen worden vervangen door
`zad-actions/deploy` en `zad-actions/cleanup`. `zad-cleanup.yml` (workflow_dispatch) gebruikt
dezelfde cleanup-action plus een eigen guard op beschermde deployment-namen. `deploy/zad/` houdt
alleen `manager-migrate/` over. Projectconfig (env, services, bijlagen, web-publicatie) leeft
voortaan uitsluitend in de Operations Manager UI.

**Tech Stack:** GitHub Actions (YAML), `RijksICTGilde/zad-actions` v4.0.6, actionlint, yamllint,
markdownlint-cli2.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-29-zad-actions-convergentie-design.md` is leidend.
- **Action-pin:** `RijksICTGilde/zad-actions/<deploy|cleanup>@13434cd415db0cd195a2c5f12bf67645acfcb635 # v4.0.6`
  — SHA-gepind, met de versie als comment (Scorecard Pinned-Dependencies, zoals elders in dit repo).
- **Taal:** commentaar en documentatie in het Nederlands; code/technische termen in het Engels.
- **Git:** nooit direct naar `main`. Het werk gebeurt op de bestaande branch
  `fix/zad-component-attach` (PR #35), die van component-fix wordt **omgevormd** naar deze
  oplossing — die PR niet vooraf mergen, dat zou code repareren die hier verdwijnt. De branchnaam
  dekt de lading niet meer; hernoemen zou de PR sluiten, dus laat 'm staan en pas titel + body aan.
- **Vereiste checks:** `lint` (markdownlint + yamllint + actionlint) en `Analyze (actions)`.
- **Geen secrets in `run:`-blokken**; inputs via `env:` en gequote.
- **Erfenis in de branch:** #35 wijzigde `upsert-directory.sh` en `cleanup.sh`; Taak 4 verwijdert
  beide, dus die commits worden vanzelf ingehaald. `main` → `test` is tot de merge kapot (de
  `already exists`-fout) — dat is het bewuste gevolg van niet vooraf mergen.
- **Image-naam:** de wrapper-image heet voortaan `ghcr.io/minbzk/moza-fsc-testnet-manager-migrate`
  (koppelteken, géén slash). Reden: `zad-actions/cleanup` valideert containernamen op
  `^[a-zA-Z0-9._-]+$` en weigert dus een repo-scoped naam met `/`. Besluit van de opdrachtgever
  (2026-07-29) na de review van Taak 2.
- **Projectwaarden:** project `mft-tp9` (uit `vars.ZAD_PROJECT_ID_DIRECTORY`), key uit
  `secrets.ZAD_API_KEY_DIRECTORY`, base_domain `rig.prd1.gn2.quattro.rijksapps.nl`, componenten
  `dirmgr` + `dirui`, stock-tag `v1.43.7`.
- **Er zijn geen unit-tests in dit repo.** "Test" betekent hier: `actionlint` + `yamllint` +
  `markdownlint-cli2` lokaal groen, en daarna de echte PR-pipeline (Taak 6).

---

## File Structure

| Bestand | Verantwoordelijkheid na afloop |
|---|---|
| `.github/workflows/zad-deploy-directory.yml` | Wijzigen: deploy- en cleanup-stap via de action; path-filter en dispatch-inputs bijwerken |
| `.github/workflows/zad-cleanup.yml` | Wijzigen: cleanup via de action + guard op beschermde namen |
| `deploy/zad/upsert-directory.sh` | Verwijderen |
| `deploy/zad/cleanup.sh` | Verwijderen |
| `deploy/zad/manager-migrate/**` | Ongewijzigd (wrapper-image blijft van ons) |
| `docs/zad-directory-deploy.md` | Herschrijven: CI deployt images via de action; projectconfig in de UI |
| `docs/zad-cleanup.md` | Herschrijven: cleanup via de action; peer-repo's gebruiken dezelfde action |
| `CLAUDE.md` | Eén alinea bij: deploymodel is `zad-actions`, geen eigen scripts |

---

## Task 1: Deploy-stap omzetten naar `zad-actions/deploy`

**Files:**

- Modify: `.github/workflows/zad-deploy-directory.yml` (job `deploy`, de stappen
  "Upsert directory via ZAD v2-API" en "Preview-URL als PR-comment (upsert)")

**Interfaces:**

- Consumes: `needs.meta.outputs.deployment` (`pr-<n>` of `test`),
  `needs.meta.outputs.image_base` (`v1.43.7`), `needs.meta.outputs.manager_suffix` (`pr-<n>` of
  leeg), `needs.changes.outputs.manager_migrate_changed` (`true`/`false`).
- Produces: een `deploy`-job zonder checkout en zonder scriptaanroep; latere taken verwijderen het
  script en de docs die ernaar verwijzen.

- [ ] **Step 1: Vervang de hele `deploy`-job**

Zoek in `.github/workflows/zad-deploy-directory.yml` de job `deploy:` (begint bij de regel
`deploy:` en loopt tot het commentaar `# PR gesloten -> preview opruimen.`). Vervang die job volledig door:

```yaml
  # Rolt de directory uit via de upstream-action (zelfde mechanisme als moza-poc-fbs-berichtenbox).
  # Draait ná build-succes, of meteen als de build geskipt is -> de image bestaat gegarandeerd.
  # De action zet ALLEEN images + deployment; env/services/bijlagen/web-publicatie zijn projectconfig
  # in de Operations Manager UI (zie docs/zad-directory-deploy.md).
  deploy:
    needs: [meta, changes, build]
    if: >-
      ${{ always() && needs.changes.outputs.run == 'true'
          && needs.changes.result == 'success' && needs.meta.result == 'success'
          && (needs.build.result == 'success' || needs.build.result == 'skipped') }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - name: Deploy directory via zad-actions
        uses: RijksICTGilde/zad-actions/deploy@13434cd415db0cd195a2c5f12bf67645acfcb635 # v4.0.6
        with:
          api-key: ${{ secrets.ZAD_API_KEY_DIRECTORY }}
          project-id: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
          deployment-name: ${{ needs.meta.outputs.deployment }}
          # Previews erven de projectconfig van `test`; `test` zelf kloont niets.
          clone-from: ${{ github.event_name == 'pull_request' && 'test' || '' }}
          # Previews horen op ELKE PR te draaien, ook een Dependabot-bump (de key staat daarvoor
          # ook in de Dependabot-secretstore). Zonder dit skipt de action bot-PR's stilzwijgend.
          skip-bot-prs: 'false'
          # De action curlt één health-endpoint per component; dirmgr is mTLS-only en geeft daar
          # nooit 2xx -> de wachtlus zou altijd time-outen.
          wait-for-ready: 'false'
          # Verse preview-provisioning duurt structureel langer dan een update (300s is te krap).
          task-timeout: '600'
          comment-on-pr: ${{ github.event_name == 'pull_request' }}
          domain-format: component-deployment-project
          components: |
            [
              {"name": "dirmgr", "image": "ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:${{ (github.event_name == 'pull_request' && needs.changes.outputs.manager_migrate_changed == 'true') && format('{0}-{1}', needs.meta.outputs.image_base, needs.meta.outputs.manager_suffix) || needs.meta.outputs.image_base }}"},
              {"name": "dirui", "image": "docker.io/federatedserviceconnectivity/directory-ui:${{ needs.meta.outputs.image_base }}"}
            ]
```

Let op: de checkout-stap vervalt (de action heeft de repo niet nodig) en de eigen
comment-upsert-stap vervalt (`comment-on-pr` doet dat).

- [ ] **Step 2: Werk de `on:`-trigger en de kopregel bij**

Vervang bovenin hetzelfde bestand de regels 1–7 (het kopcommentaar) door:

```yaml
# Deploy van de directory (#723) via RijksICTGilde/zad-actions — zelfde mechanisme als
# moza-poc-fbs-berichtenbox. Model: push main -> deployment `test`; PR -> preview `pr-<PR-nummer>`
# (open/sync = deploy, close = cleanup); workflow_dispatch = handmatige override.
#
# De action zet deployment + componenten + images. Projectconfig (env_vars, aliases, services,
# bijlagen/cert-mount, "Publicatie op het web") staat in de Operations Manager UI en geldt voor
# ALLE deployments via deploy-variabelen ($DEPLOYMENT_NAME, $DATABASE_*).
```

Vervang in het `push`-blok het path-filter (`deploy/zad/upsert-directory.sh` bestaat straks niet
meer):

```yaml
  push:
    branches: [main]
    paths:
      - "deploy/zad/manager-migrate/**"
      - "group/**"
      - ".github/workflows/zad-deploy-directory.yml"
```

- [ ] **Step 3: Snoei de `workflow_dispatch`-inputs**

De action kent geen `validate`/`plan`-modus en geen `clone_from`-vrijheid meer. Vervang het
`workflow_dispatch:`-blok door:

```yaml
  workflow_dispatch:
    inputs:
      deployment:
        description: "deployment-naam (main -> test; PR -> pr-<PR-nummer>)"
        required: false
        default: "test"
      image_tag:
        description: "OpenFSC stock-tag (directory-ui; default voor de manager)"
        required: false
        default: "v1.43.7"
      manager_tag:
        description: "ghcr manager-migrate-tag (bv. branch-tag); leeg = image_tag"
        required: false
        default: ""
```

Verwijder daarna in de job `meta` niets — die gebruikt `inputs.deployment` en `inputs.image_tag`
al en blijft werken. `inputs.manager_tag` werd alleen in de oude deploy-stap gebruikt; laat de
input staan en gebruik 'm in de components-JSON door in Step 1 het `dirmgr`-image te vervangen
door:

```yaml
              {"name": "dirmgr", "image": "ghcr.io/minbzk/moza-fsc-testnet/manager-migrate:${{ inputs.manager_tag != '' && inputs.manager_tag || ((github.event_name == 'pull_request' && needs.changes.outputs.manager_migrate_changed == 'true') && format('{0}-{1}', needs.meta.outputs.image_base, needs.meta.outputs.manager_suffix) || needs.meta.outputs.image_base) }}"},
```

- [ ] **Step 4: Lint**

```bash
yamllint .github/workflows/zad-deploy-directory.yml
actionlint .github/workflows/zad-deploy-directory.yml
```

Verwacht: beide zonder output (exitcode 0). Een `actionlint`-fout over een onbekende input van de
action betekent dat de inputnaam niet klopt — controleer tegen
`gh api repos/RijksICTGilde/zad-actions/contents/deploy/action.yml --jq '.content' | base64 -d`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/zad-deploy-directory.yml
git commit -m "feat(ci): deploy directory via zad-actions i.p.v. eigen script"
```

---

## Task 2: Cleanup-on-close omzetten naar `zad-actions/cleanup`

**Files:**

- Modify: `.github/workflows/zad-deploy-directory.yml` (job `cleanup-preview`)

**Interfaces:**

- Consumes: `needs.meta.outputs.deployment`, `needs.meta.outputs.image_base`,
  `needs.meta.outputs.manager_suffix`.
- Produces: geen scriptafhankelijkheid meer in dit bestand; Taak 4 kan de scripts verwijderen.

- [ ] **Step 1: Vervang de job `cleanup-preview` volledig**

```yaml
  # PR gesloten -> preview opruimen (deployment + de ghcr-preview-tag). Onafhankelijk van
  # changes/deploy (die skippen op close). Géén GitHub-environment, dus geen GH_ADMIN_TOKEN nodig.
  cleanup-preview:
    if: ${{ github.event_name == 'pull_request' && github.event.action == 'closed'
            && github.event.pull_request.head.repo.full_name == github.repository }}
    needs: meta
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Ruim de preview op via zad-actions
        uses: RijksICTGilde/zad-actions/cleanup@13434cd415db0cd195a2c5f12bf67645acfcb635 # v4.0.6
        with:
          api-key: ${{ secrets.ZAD_API_KEY_DIRECTORY }}
          project-id: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
          deployment-name: ${{ needs.meta.outputs.deployment }}
          delete-github-env: 'false'
          delete-container: 'true'
          containers: |
            [
              {"org": "minbzk", "name": "moza-fsc-testnet-manager-migrate", "tag": "${{ needs.meta.outputs.image_base }}-${{ needs.meta.outputs.manager_suffix }}"}
            ]
```

- [ ] **Step 2: Hernoem de ghcr-image naar een naam zonder slash**

`zad-actions/cleanup` valideert `containers[].name` op `^[a-zA-Z0-9._-]+$` en `exit 1`t op een
repo-scoped naam met `/`. De image wordt daarom platgeslagen. Wijzig in
`.github/workflows/build-manager-migrate.yml` de `IMAGE`-env:

```yaml
          # Lowercase image-pad zonder slash: zad-actions/cleanup weigert `/` in een containernaam.
          IMAGE: ghcr.io/minbzk/moza-fsc-testnet-manager-migrate
```

Wijzig in `.github/workflows/zad-deploy-directory.yml` de `dirmgr`-regel in de components-JSON van
de `deploy`-job zo dat het image-pad `ghcr.io/minbzk/moza-fsc-testnet-manager-migrate:` wordt — laat
de tag-expressie erachter exact zoals 'ie staat.

Controleer daarna dat er nergens in `.github/` en `deploy/` nog een verwijzing met slash staat:

```bash
grep -rn "moza-fsc-testnet/manager-migrate" .github/ deploy/
```

Verwacht: **geen** treffers. (Treffers in `docs/**` pakt Taak 5; `deploy/zad/upsert-directory.sh`
verdwijnt in Taak 4 — als die nog bestaat en een treffer geeft, laat 'm dan staan.)

- [ ] **Step 3: Lint**

```bash
yamllint .github/workflows/zad-deploy-directory.yml .github/workflows/build-manager-migrate.yml
actionlint .github/workflows/zad-deploy-directory.yml .github/workflows/build-manager-migrate.yml
```

Verwacht: geen output.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/zad-deploy-directory.yml .github/workflows/build-manager-migrate.yml
git commit -m "feat(ci): cleanup-preview via zad-actions, image-naam zonder slash"
```

---

## Task 3: `zad-cleanup.yml` omzetten, met guard op beschermde namen

**Files:**

- Modify: `.github/workflows/zad-cleanup.yml` (hele `cleanup`-job)

**Interfaces:**

- Consumes: `inputs.deployment`, `inputs.allow_protected` (bestaande inputs).
- Produces: handmatige cleanup zonder script; de `mode`-input (`validate`/`plan`/`apply`) vervalt
  omdat de action die niet kent.

- [ ] **Step 1: Vervang het `workflow_dispatch`-blok**

De action heeft geen read-only modus; `validate`/`plan` verdwijnen.

```yaml
on:
  workflow_dispatch:
    inputs:
      deployment:
        description: "deployment-naam om op te ruimen (bv. een pr-preview)"
        required: true
      allow_protected:
        description: "sta het verwijderen van beschermde namen (test/main/...) toe"
        type: boolean
        default: false
```

- [ ] **Step 2: Vervang de `cleanup`-job**

De action kent géén beschermde-namen-check; die vangrail zat in `cleanup.sh` en komt hier terug als
eerste stap. Het cluster is odcn-**production** en `test` is een gedeelde singleton.

```yaml
jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      # Vangrail uit het verwijderde cleanup.sh: beschermde deployments niet per ongeluk slopen.
      - name: Weiger beschermde deployment-namen
        env:
          DEPLOYMENT: ${{ inputs.deployment }}
          ALLOW_PROTECTED: ${{ inputs.allow_protected }}
        run: |
          set -euo pipefail
          case "$DEPLOYMENT" in
            ""|*[!a-z0-9-]*)
              echo "::error::ongeldige deployment-naam '$DEPLOYMENT' (alleen a-z0-9-)"; exit 1 ;;
          esac
          case "$DEPLOYMENT" in
            test|main|master|production|prod)
              if [ "$ALLOW_PROTECTED" != "true" ]; then
                echo "::error::'$DEPLOYMENT' is beschermd; zet allow_protected aan om te forceren."
                exit 1
              fi
              echo "::warning::beschermde deployment '$DEPLOYMENT' wordt verwijderd (allow_protected)." ;;
          esac

      - name: Cleanup via zad-actions
        uses: RijksICTGilde/zad-actions/cleanup@13434cd415db0cd195a2c5f12bf67645acfcb635 # v4.0.6
        with:
          api-key: ${{ secrets.ZAD_API_KEY_DIRECTORY }}
          project-id: ${{ vars.ZAD_PROJECT_ID_DIRECTORY }}
          deployment-name: ${{ inputs.deployment }}
          delete-github-env: 'false'
          delete-container: 'false'
```

- [ ] **Step 3: Werk het kopcommentaar bij**

Vervang de eerste regels (t/m `name: zad-cleanup`) door:

```yaml
# ZAD-cleanup (#729) via RijksICTGilde/zad-actions/cleanup: verwijdert een deployment uit het
# directory-project (project uit vars.ZAD_PROJECT_ID_DIRECTORY, key uit
# secrets.ZAD_API_KEY_DIRECTORY). Het PR-pad ruimt zichzelf op in zad-deploy-directory.yml;
# deze workflow is voor handmatige gevallen. Een peer-deployment ruim je op bij de app-repo met
# dezelfde action en het eigen project + de eigen key. Zie docs/zad-cleanup.md.
name: zad-cleanup
```

- [ ] **Step 4: Test de guard-logica los**

De guard is shell; test 'm zonder de workflow te draaien:

```bash
guard() {
  DEPLOYMENT="$1"; ALLOW_PROTECTED="$2"
  case "$DEPLOYMENT" in ""|*[!a-z0-9-]*) echo "REJECT ongeldig"; return 1 ;; esac
  case "$DEPLOYMENT" in
    test|main|master|production|prod)
      [ "$ALLOW_PROTECTED" = "true" ] || { echo "REJECT beschermd"; return 1; }
      echo "WARN forceer" ;;
  esac
  echo "OK"
}
guard pr-31 false   # verwacht: OK
guard test false    # verwacht: REJECT beschermd
guard test true     # verwacht: WARN forceer + OK
guard "pr 31" false # verwacht: REJECT ongeldig
```

Verwacht: exact die vier uitkomsten.

- [ ] **Step 5: Lint**

```bash
yamllint .github/workflows/zad-cleanup.yml
actionlint .github/workflows/zad-cleanup.yml
```

Verwacht: geen output.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/zad-cleanup.yml
git commit -m "feat(ci): zad-cleanup via zad-actions, guard op beschermde namen"
```

---

## Task 4: Scripts verwijderen

**Files:**

- Delete: `deploy/zad/upsert-directory.sh`
- Delete: `deploy/zad/cleanup.sh`

**Interfaces:**

- Consumes: niets meer — Taken 1–3 hebben alle verwijzingen uit de workflows gehaald.
- Produces: `deploy/zad/` bevat alleen nog `manager-migrate/`.

- [ ] **Step 1: Controleer dat er geen verwijzingen meer zijn in code/CI**

```bash
grep -rn "upsert-directory\|zad/cleanup.sh" --include="*.yml" --include="*.yaml" --include="*.sh" .
```

Verwacht: **geen** treffers. Treffers in `docs/**` zijn hier oké — die pakt Taak 5.

- [ ] **Step 2: Verwijder de scripts**

```bash
git rm deploy/zad/upsert-directory.sh deploy/zad/cleanup.sh
ls deploy/zad/
```

Verwacht: alleen `manager-migrate/`.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(zad): verwijder eigen deploy- en cleanup-scripts"
```

---

## Task 5: Documentatie bijwerken

**Files:**

- Modify: `docs/zad-directory-deploy.md`
- Modify: `docs/zad-cleanup.md`
- Modify: `CLAUDE.md`

**Interfaces:**

- Consumes: de eindtoestand uit Taken 1–4.
- Produces: docs die de UI als bron van projectconfig benoemen; geen verwijzingen meer naar de
  verwijderde scripts.

- [ ] **Step 1: `docs/zad-directory-deploy.md` — sectie "Taakverdeling: API/CI vs UI"**

Vervang die sectie (de twee bullets) door:

```markdown
## Taakverdeling: CI vs UI

- **Via CI (`zad-deploy-directory.yml` → `RijksICTGilde/zad-actions/deploy`):** het deployment en
  per component het draaiende **image**. Meer niet.
- **In de Operations Manager UI, op projectniveau:** `env_vars`, `aliases`, `services`
  (managed Postgres), **bijlagen** (cert-mount, ontwerp A) en **"Publicatie op het web"**
  (passthrough-TLS, modus 2). Die config geldt voor **alle** deployments doordat ze
  deploy-variabelen gebruikt (`$DEPLOYMENT_NAME`, `$DATABASE_*`) — een nieuw `pr-<n>` erft 'm dus
  zonder handwerk.

> Git dwingt de env **niet** af: `peers/directory/manager.env.example` is de referentie van wat er
> in de UI hoort te staan. De v2-API kan env alleen bij het *aanmaken* van een component zetten
> (`AddComponentRequest`), niet bijwerken (`UpdateComponentRequest` heeft geen `env_vars`/`aliases`).
> Er loopt een feature request bij ZAD-beheer om dat te openen.
```

- [ ] **Step 2: `docs/zad-directory-deploy.md` — sectie "6. Deployen"**

Vervang het codeblok met de drie `upsert-directory.sh`-aanroepen en de alinea eronder door:

````markdown
Deployen doet CI. Handmatig kan via **Actions → zad-deploy-directory → Run workflow**
(`deployment`, `image_tag`, `manager_tag`). Er is geen lokaal deploy-script meer; wil je zien wat
er staat, kijk dan in de Operations Manager UI of doe een read-only API-call:

```bash
read -rs ZAD_API_KEY; export ZAD_API_KEY     # plak de key niet inline
curl -sS -H "X-API-Key: $ZAD_API_KEY" \
  https://zad.rijksapp.nl/api/v2/projects/mft-tp9/deployments | jq -r '.deployments[].name'
```

**Blijft handwerk in de UI (stappen 3 + 5):** bijlagen (certs) + Publicatie op het web modus 2 op
`dirmgr` — eenmalig per project, niet per deployment.
````

Werk in dezelfde file elke resterende verwijzing naar `upsert-directory.sh` bij (o.a. in de
statusblokken bovenaan en in "Componenten"): vervang "aangemaakt door
`deploy/zad/upsert-directory.sh`" door "aangemaakt in de Operations Manager UI (project `mft-tp9`)".

Vind ze met:

```bash
grep -n "upsert-directory" docs/zad-directory-deploy.md
```

Verwacht na afloop: geen treffers.

- [ ] **Step 3: `docs/zad-cleanup.md` — script → action**

Wijzig de tabel in "Model: per onderdeel, deploy bij de app" zo dat beide kolommen naar de action
verwijzen:

```markdown
| Onderdeel | Deploy | Cleanup | Beheerd vanuit |
|-----------|--------|---------|----------------|
| directory | `zad-deploy-directory.yml` → `zad-actions/deploy` | `zad-cleanup.yml` → `zad-actions/cleanup` | **dit repo** |
| peer (magazijn/uitvraag/…) | app-repo's `deploy.yml` → `zad-actions/deploy` | app-repo → `zad-actions/cleanup` | bij de app |
```

Vervang de alinea eronder ("Beide scripts zijn volledig env-gedreven …") door:

```markdown
Een app-repo hoeft niets uit dit repo te vendoren: dezelfde SHA-gepinde action met het eigen
project-id + de eigen key volstaat. Dat is de "kopiëren + pinnen"-variant uit `zad-projecten.md`,
nu met de action als gedeeld artefact in plaats van een gekopieerd script.
```

Vervang het `cleanup.sh`-codeblok door een verwijzing naar de workflow-dispatch, en werk de bullets
bij: de idempotentie- en beschermde-namen-claims horen nu bij respectievelijk de action en de
`if`-guard in `zad-cleanup.yml`.

```bash
grep -n "cleanup.sh\|upsert-directory" docs/zad-cleanup.md
```

Verwacht na afloop: geen treffers.

- [ ] **Step 4: `CLAUDE.md` — deploymodel**

Vervang in de sectie "ZAD / OpenShift (uit #720 — GO)" de alinea die begint met
"**ZAD deployt images, geen Helm.**" door:

```markdown
- **ZAD deployt images, geen Helm.** CI gebruikt `RijksICTGilde/zad-actions/deploy` (SHA-gepind,
  zoals `moza-poc-fbs-berichtenbox`) met een `components:`-lijst van `{name, image}`.
  OpenFSC-charts = bron voor image- + env-namen, niet het deploy-artefact. **Projectconfig**
  (env_vars, aliases, services, bijlagen, web-publicatie) staat in de Operations Manager UI en
  gebruikt deploy-variabelen (`$DEPLOYMENT_NAME`, `$DATABASE_*`), zodat elk deployment 'm erft;
  `peers/directory/manager.env.example` documenteert die waarden maar dwingt niets af.
  **DB-migratie (#723, opgelost):** ZAD ondersteunt nog geen args/init-containers → migreren zit in
  een wrapper-image `deploy/zad/manager-migrate/` (`migrate up && serve` in de entrypoint).
```

- [ ] **Step 4b: Werk het image-pad in de docs bij**

De wrapper-image is hernoemd naar `ghcr.io/minbzk/moza-fsc-testnet-manager-migrate` (zie Global
Constraints). Vervang elk voorkomen van het oude pad met slash:

```bash
grep -rn "moza-fsc-testnet/manager-migrate" docs/ CLAUDE.md
```

Werk elke treffer bij naar `moza-fsc-testnet-manager-migrate`. In
`docs/superpowers/specs/2026-07-29-zad-actions-convergentie-design.md` staat het pad in het
YAML-voorbeeld van Besl. B; werk dat bij én voeg direct onder dat codeblok één regel toe:

```markdown
> Naschrift (2026-07-29): de ghcr-image is hernoemd van `moza-fsc-testnet/manager-migrate` naar
> `moza-fsc-testnet-manager-migrate` — `zad-actions/cleanup` valideert containernamen op
> `^[a-zA-Z0-9._-]+$` en weigert dus een repo-scoped naam met `/`.
```

Herhaal de grep na afloop; verwacht: geen treffers meer met slash.

- [ ] **Step 5: Lint**

```bash
npx --yes markdownlint-cli2 docs/zad-directory-deploy.md docs/zad-cleanup.md CLAUDE.md docs/superpowers/specs/2026-07-29-zad-actions-convergentie-design.md
```

Verwacht: `Summary: 0 issues in 0 files`.

- [ ] **Step 6: Commit**

```bash
git add docs/zad-directory-deploy.md docs/zad-cleanup.md CLAUDE.md docs/superpowers/specs/2026-07-29-zad-actions-convergentie-design.md
git commit -m "docs(zad): projectconfig in de UI, deploy via zad-actions"
```

---

## Task 6: PR openen en de preview verifiëren

**Files:** geen wijzigingen — dit is de acceptatietest uit de spec.

**Interfaces:**

- Consumes: de branch met Taken 1–5.
- Produces: bewijs dat het nieuwe pad werkt, of een weerlegging van de risicotabel.

- [ ] **Step 1: Push en open de PR**

PR #35 bestaat al op deze branch; alleen pushen en de PR omtitelen:

```bash
git push
gh api -X PATCH repos/MinBZK/moza-fsc-testnet/pulls/35 \
  -f title='feat(ci): deploy en cleanup via zad-actions' \
  -f body='Implementeert docs/superpowers/specs/2026-07-29-zad-actions-convergentie-design.md — CI deployt images via RijksICTGilde/zad-actions, projectconfig staat in de Operations Manager UI, eigen ZAD-scripts vervallen. Vervangt de eerdere component-koppelfix in deze PR: die repareerde een script dat hier verdwijnt.'
```

- [ ] **Step 2: Wacht op de deploy-run en lees de uitkomst**

```bash
PR=35
until [ "$(gh run list --branch fix/zad-component-attach \
  --workflow zad-deploy-directory.yml --limit 1 --json status --jq '.[0].status')" = "completed" ]; do
  sleep 20
done
gh run list --branch fix/zad-component-attach --workflow zad-deploy-directory.yml \
  --limit 1 --json databaseId,conclusion --jq '.[]|[.conclusion,.databaseId]|@tsv'
```

Verwacht: `success`. Bij `failure`: haal de joblog op met
`gh api repos/MinBZK/moza-fsc-testnet/actions/jobs/<id>/logs` en beoordeel of de fout in de
action-inputs zit (herstelbaar) of in de aanname dat een vers deployment de projectconfig erft
(dan is de spec weerlegd — meld dat en stop).

- [ ] **Step 2b: Controleer dat ZAD de nieuwe ghcr-package kan pullen**

De hernoemde image (`moza-fsc-testnet-manager-migrate`) is een **nieuwe** package; de eerste push
maakt 'm aan met de standaard-zichtbaarheid van de org. Kan ZAD 'm niet pullen, dan crashloopt
`dirmgr` met een pull-fout terwijl de deploy-task zelf slaagt.

```bash
gh api "orgs/minbzk/packages/container/moza-fsc-testnet-manager-migrate" \
  --jq '{visibility, repository: .repository.full_name}'
```

Verwacht: dezelfde zichtbaarheid als de oude package
(`gh api "orgs/minbzk/packages/container/moza-fsc-testnet%2Fmanager-migrate" --jq .visibility`) en
`repository: MinBZK/moza-fsc-testnet` (via het `org.opencontainers.image.source`-label). Wijkt het
af, meld het — dat is handwerk in de package-instellingen, geen code.

De oude package blijft met zijn bestaande tags achter; die opruimen is een aparte, handmatige actie.

- [ ] **Step 3: Controleer de preview functioneel**

```bash
PR=35
curl -sS -o /dev/null -w '%{http_code}\n' \
  "https://dirui-pr-${PR}-mft-tp9.rig.prd1.gn2.quattro.rijksapps.nl/"
```

Verwacht: `200`. Dat bewijst tegelijk dat `dirui` de manager op :443 kan verifiëren, dus dat de
certs gemount zijn in het nieuwe deployment.

Controleer daarnaast in de Operations Manager UI de log van `dirmgr` op de `pr-<n>`-deployment:
`migrate up` slaagt en de self-announce (`EVENT_TYPE_CREATE_PEER`, OIN `00000000000000000010`)
staat op SUCCEEDED.

- [ ] **Step 4: Leg de uitkomst vast op de PR**

```bash
gh pr comment 35 --body "Preview-verificatie: deploy-run groen, dirui-URL HTTP 200, migrate up + self-announce SUCCEEDED op pr-<n>."
```

Pas de tekst aan op wat je werkelijk zag — neem geen resultaten over die je niet hebt gecontroleerd.

- [ ] **Step 5: Na merge — controleer `test` en de opruiming**

Na het mergen rolt de push-trigger `test` uit met hetzelfde pad. Controleer:

```bash
gh run list --workflow zad-deploy-directory.yml --limit 1 \
  --json headBranch,conclusion --jq '.[]|[.headBranch,.conclusion]|@tsv'
curl -sS -H "X-API-Key: $ZAD_API_KEY" \
  https://zad.rijksapp.nl/api/v2/projects/mft-tp9/deployments | jq -r '.deployments[].name'
```

Verwacht: de `main`-run is `success`, en `pr-<n>` staat niet meer in de lijst (cleanup-on-close
heeft 'm opgeruimd).

---

## Zelfcontrole van dit plan

- **Spec-dekking:** Besl. A → Taak 4; Besl. B → Taak 1; Besl. C → Taken 2 + 3; Besl. D → Taak 5;
  verificatie-sectie → Taak 6; risicotabel → beoordelingspunt in Taak 6 Step 2.
- **Niet gedekt, bewust:** de eenmalige UI-config hoeft niet te veranderen (spec, sectie
  "Wat er níét verandert") en de `manager-migrate`-build blijft ongemoeid.
- **Namen die over taken heen consistent moeten zijn:** `needs.meta.outputs.deployment`,
  `needs.meta.outputs.image_base`, `needs.meta.outputs.manager_suffix`,
  `needs.changes.outputs.run`, `needs.changes.outputs.manager_migrate_changed` — alle vijf bestaan
  al in de huidige `zad-deploy-directory.yml` en worden in dit plan niet hernoemd.
