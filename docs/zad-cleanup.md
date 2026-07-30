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
- **Pre-flight vóór de handmatige cleanup** (`zad-cleanup.yml`): één GET stelt vóór de action vast of
  de deployment bestónd. Dat onderscheidt "was al opgeruimd" (groene `::notice::`) van "je hebt de
  naam verkeerd getypt / er is een verwijdering gevraagd die niet gebeurde" (harde `::error::`) —
  zonder dat onderscheid zijn beide een groene run. Een 404 telt daarbij alleen als "bestond niet"
  als het lijst-endpoint 200 geeft (key + project bevestigd); bij elke twijfel (401/403/5xx/000, of
  een onbevestigde 404) gaat de check naar de veilige kant en neemt aan dat de deployment bestónd.
  De `cleanup-preview`-job in `zad-deploy-directory.yml` heeft deze stap niet: daar komt de naam uit
  het PR-nummer, dus een typo bestaat er niet.
- **Container-delete via de action is best-effort én kan verdergaan dan de gevraagde tag**: weigert
  GitHub een losse tag te verwijderen omdat het de laatste getagde versie van het package is, dan
  verwijdert de action het **hele package** in plaats van alleen die tag (zie `zad-actions@v4.0.6:cleanup/action.yml`,
  stap "Delete Container Image"). Precies daarom zetten **beide** workflows `delete-container:
  'false'` en geven ze geen `containers:` mee — maar alleen `zad-deploy-directory.yml`
  (job `cleanup-preview`) heeft daarna een **eigen** stap die de ghcr-preview-tag zelf verwijdert:
  deelt de tag een versie met een andere tag (bv. `v1.43.7`), dan slaat die eigen stap het
  verwijderen over (anders verdwijnt de gedeelde versie mee). `zad-cleanup.yml` heeft géén eigen
  ghcr-stap — een preview-image die je daarmee handmatig opruimt, blijft dus staan tot een latere
  `cleanup-preview`-run 'm meepakt, of tot handmatig opruimen via de package-UI.
- **Verificatie zit in één gedeelde composite action**:
  `.github/actions/verify-zad-deleted/action.yml`, aangeroepen vanuit zowel de
  `cleanup-preview`-job in `zad-deploy-directory.yml` (PR-close) als vanuit `zad-cleanup.yml`
  (handmatig). Eén plek, omdat twee kopieën van deze bewijsvoering onvermijdelijk uiteen gaan lopen
  — en een verificatie die op de ene plek strenger is dan op de andere geeft valse zekerheid.
- **Een mislukte delete faalt de step niet**: `zad_delete_deployment` (in `zad-actions@v4.0.6:scripts/zad-common.sh`) logt bij
  een fout eerst een `::warning::`, en laat `report_zad_error` daarna ook `::error::`-annotaties zien
  (met een gestructureerde CLI-diagnose als die er is, anders de ruwe uitvoer); geen van beide doet de step
  `exit` met een fout, dus de job blijft groen. Een groene job bewijst dus niet dat het deployment
  weg is, ook al staan er soms error-annotaties in de run. Precies dáárom bestaat de
  verificatiestap: die controleert onafhankelijk van wat de `cleanup`-action zelf rapporteert.
- **Verificatie = drie calls, niet één kale 404**: de composite action pollt eerst het **scoped**
  endpoint `GET /api/v2/projects/{project}/deployments/{deployment}`. Een 404 daar is op zichzelf
  géén bewijs — live tegen de API geprobeerd komt diezelfde 404 ook terug op een onbekend pad en
  op een leeg project-segment, zónder dat de key ooit gecontroleerd wordt. Pas als een
  vervolgcall naar het lijst-endpoint (`GET .../deployments`, zonder `/{deployment}`) HTTP 200
  teruggeeft, telt de 404 als bevestigd: dat lijst-endpoint is authenticated + project-scoped, dus
  alleen een 200 daar bevestigt dat de key en het project kloppen (een foute key geeft 401, een
  verkeerd project geen 200). Van die 200-lijst telt daarna alléén de **positieve** richting: staat
  de deployment-naam er, ondanks de 404 op het scoped endpoint, tóch in — dan is dat een
  tegenspraak en faalt de stap (het scoped pad is vermoedelijk stuk, of upstream gewijzigd).
  *Afwezigheid* in die lijst bewijst niets: het endpoint is *"Returns only deployments targeting
  the current cluster"* (`openapi.json`) en `DeploymentListResponse.required` is enkel
  `["project","cluster"]`, dus `deployments` mag legitiem ontbreken — de negatieve richting is
  dus niet bruikbaar als bewijs. Transiënte fouten (`000`, 5xx) op zowel de scoped als de
  bevestigingscall krijgen een begrensde retry (4 pogingen, 10s interval — de rekensom achter de
  `timeout-minutes` van beide aanroepende jobs hangt aan dat getal); elke andere status (2xx = nog
  aanwezig, of een onverwachte 4xx/5xx na de laatste poging) faalt de stap hard.
- **Die 200 moet ook de juiste vórm hebben**: een object met `cluster` en met `.project` gelijk aan het
  opgevraagde project. Zonder die eis gelden `{}`, `[]`, `0` en `"onderhoud"` als "lijst waarin de naam
  niet staat" — en dus als bewijs van verwijdering. Een gateway- of onderhoudspagina met HTTP 200 kwam
  daar eerder groen door.
- **Derde call = positieve controle op het scoped pad.** Een 404 kan ook betekenen dat het pad zelf
  stuk is (upstream-wijziging), en dat kan het lijst-endpoint niet uitsluiten — dat is een ander pad.
  Daarom moet een deployment die zeker bestaat (input `control-deployment`, standaard de gedeelde
  `test`) op datzelfde scoped pad 2xx geven. Staat die controle-deployment wél in de lijst maar geeft
  hij 404, dan is het pad stuk en faalt de stap. Is hij ook uit de lijst verdwenen (zelf opgeruimd, of
  nog niet uitgerold), dan wordt de controle met een `::warning::` overgeslagen — dat mag de cleanup
  niet blokkeren, maar de slotmelding zegt dan expliciet dat dit gat niet gedekt is. Ruim je `test`
  zélf op, dan valt de controle om dezelfde reden weg (`control-deployment` == de deployment).
- **De action wordt uit de default branch geladen** (`ref:` op de checkout in `cleanup-preview`), niet
  uit de PR-branch: de verificatiecode die de productie-API-key krijgt is daarmee de gereviewde versie.
  Gevolg voor onderhoud: een wijziging aan deze action wordt niet getest door de PR die 'm invoert —
  z'n eerste uitvoering is een echte cleanup ná merge. Houd action-inputs achterwaarts compatibel, want
  een oudere openstaande PR roept bij het sluiten de main-versie aan. De `lint`-workflow shellcheckt de
  `run:`-blokken van composite actions, zodat shellfouten wél vóór merge opvallen.
- **Beschermde namen** (`test`, `main`, `master`, `production`, `prod`) weigeren tenzij de
  workflow-input `allow_protected` aanstaat. Dat is een `if`-guard-stap vóór de action in
  `zad-cleanup.yml` — de action kent zelf geen beschermde-namen-check. Het cluster is
  **odcn-production** — dit voorkomt dat een losse hand de gedeelde `test`-singleton sloopt.
  Previews (`pr-<PR-nummer>`) ruim je vrij op.

## Beveiliging & versievastlegging

- **SHA-pinning dekt `zad-actions` zelf, niet alles eronder** (Scorecard Pinned-Dependencies):
  `zad-deploy-directory.yml` en `zad-cleanup.yml` gebruiken `RijksICTGilde/zad-actions/deploy` resp.
  `/cleanup`, beide SHA-gepind (`@13434cd4…` # v4.0.6). **Beide** workflows checken de repo daarnaast
  uit met `actions/checkout` (al SHA-gepind): `zad-deploy-directory.yml` voor `git diff` in de
  `changes`-job én voor de composite verificatie-action in `cleanup-preview`, `zad-cleanup.yml` alleen
  voor die action — lokale actions (`uses: ./.github/actions/...`) worden uit de workspace geladen en
  niet gedownload, dus zonder checkout faalt de job op "Can't find 'action.yml'". Binnen `zad-actions`
  zelf zijn twee stappen **niet** SHA-gepind: `astral-sh/setup-uv@v6` (mutable major-tag) en
  `zad-cli`, geïnstalleerd via `uv tool install git+https://github.com/RijksICTGilde/zad-cli.git@v0.8.0`
  (een mutable git-tag). Het is uiteindelijk `zad-cli` dat de ZAD-API-call uitvoert en dus de
  `api-key` te zien krijgt — die niet-SHA-gepinde keten valt buiten de Scorecard-dekking. Openstaand:
  een upstream-verzoek aan RijksICTGilde om die twee te pinnen
  ([#898](https://github.com/MinBZK/MijnOverheidZakelijk/issues/898)).
- **De key komt ook in een `run:`-stap terecht, maar veilig**: de action krijgt 'm als action-input
  (`api-key: ${{ secrets.ZAD_API_KEY_DIRECTORY }}`), en twee eigen `curl`-stappen hebben 'm ook nodig:
  de verificatie-action en de pre-flight in `zad-cleanup.yml`. Beide zetten de key via
  `env: ZAD_API_KEY: ${{ secrets... }}` en gebruikt 'm in `run:` alleen als gequote `"$ZAD_API_KEY"`, nooit geïnterpoleerd
  in de commandoregel zelf; de key wordt nergens geëcht of gelogd. De `if`-guard in
  `zad-cleanup.yml` valideert de deployment-naam (`[a-z0-9-]`) tegen injectie vóór de action draait.
- **`api-key`** komt uit `secrets.ZAD_API_KEY_DIRECTORY` (write-only); nooit gelogd.

## Openstaand

- **Peer-deploys** (manager/inway/outway/txlog/controller) draaien in het app-repo op dezelfde
  manier: een eigen `deploy.yml` met `zad-actions/deploy` en een eigen `components:`-lijst. De
  component-definities + env-templates hier blijven de bron voor image- en env-namen — maar gebruik
  daarvoor `peers/directory/*.env.example` en de lokale `deploy/local/docker-compose.yaml`, niet de
  platte keys in `peers/*/values.example.yaml`: die zijn illustratief en corresponderen niet 1-op-1
  met OpenFSC-env-namen (zie `docs/zad-projecten.md`).
- Een gedeelde **reusable `workflow_call`-cleanup** is bewust niet gedaan: dispatch (repo-secret)
  en call (doorgegeven secret) mengen in één workflow botst met de secrets-context. Elke app-repo
  roept `zad-actions/cleanup` rechtstreeks aan in een eigen dunne dispatch-workflow — simpeler en
  even reproduceerbaar, en er is niets meer te vendoren.
- **Task-timeout**: de deploy-actie gebruikt `task-timeout: '600'` (zie `zad-deploy-directory.yml`)
  — dezelfde ruimte als `PREVIEW_TASK_TIMEOUT` in `moza-poc-fbs-berichtenbox`, want verse
  preview-provisioning duurt langer dan een update. Beide cleanup-aanroepen (de `cleanup`-stap in
  `zad-cleanup.yml` én in de `cleanup-preview`-job van `zad-deploy-directory.yml`) zetten
  inmiddels dezelfde `task-timeout: '600'`, om dezelfde reden: de upstream-default (`300`) is ook
  voor een delete krap tegenover een ArgoCD-sync, en een delete die daardoor timet uit wordt door
  de action — zoals hierboven beschreven — sowieso al als `::warning::` gelogd zonder de step te
  laten falen. De ruimere timeout voorkomt dat de verificatiestap hierna een preview aantreft die
  nog volop aan het verdwijnen is.
