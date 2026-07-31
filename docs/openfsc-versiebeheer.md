# OpenFSC-versiebeheer

OpenFSC releaset `manager`, `controller`, `txlog-api`, `inway`, `outway` en `directory-ui` in
lockstep: elke release krijgt dezelfde versietag op alle images. Ze moeten ook in lockstep
**draaien** — de contract-hash en de vorm van een grant zijn versiegebonden, dus een group waarin
componenten van verschillende versies staan, praat niet meer met zichzelf.

## Waar de versie staat

| Plek | Wat |
|------|-----|
| `deploy/zad/{manager,controller,txlog}-migrate/Dockerfile` | `FROM …:<tag>@sha256:<digest>` — het base-image van de migrate-wrapper |
| `.github/workflows/build-manager-migrate.yml` | default van `image_tag` (dispatch + `workflow_call`) en de fallback in de build-stap |
| `.github/workflows/build-migrate-images.yml` | idem, voor de controller-/txlog-wrappers |
| `.github/workflows/zad-deploy-directory.yml` | `IMAGE_TAG_DEFAULT` — de stock-tag voor `dirui` en de manager |
| `deploy/local/docker-compose.yaml` + `.env.example` | `${IMAGE_TAG:-<tag>}` voor de lokale omgeving |

De wrapper-Dockerfiles zijn digest-gepind (Scorecard Pinned-Dependencies). Bij `repo:tag@digest`
resolvet Docker op de digest en wordt de tag niet gevalideerd — de tag is daar dus documentatie, en
de output-tag van het gebouwde image komt uit de **workflow-default**. Loopt die uiteen met de
`FROM`-regel, dan publiceert de build een image dat de oude versie heet en de nieuwe ís.

`.github/scripts/check-openfsc-version.sh` (stap in `lint.yml`, required check) faalt als niet alle
plekken hierboven dezelfde versie noemen. Docs blijven er bewust buiten: daar staan versies in een
historische context (spikes, design-notities).

## Dependabot

Eén `docker`-ecosystem-entry met `directories:` over alle drie de wrappers, en een groep
`openfsc-images` op `*federatedserviceconnectivity/*`. Dat levert **één** PR die de drie
base-images tegelijk verzet, in plaats van drie los mergebare PR's. De busybox-donor (`/bin/sh`
voor het distroless base-image) zit in een eigen groep, zodat een busybox-CVE niet hoeft te wachten
op een OpenFSC-release.

Wat Dependabot **niet** kan: de workflow-defaults en de compose meebewegen. Die horen bij de
groep-PR handmatig mee; de guard hierboven bewaakt dat je het niet vergeet.

## Bij een versiesprong

1. Lees de upstream [CHANGELOG](https://gitlab.com/rinis-oss/fsc/open-fsc/-/blob/main/CHANGELOG.md)
   op `⚠ BREAKING CHANGES` tussen de oude en de nieuwe versie.
2. **Diff de required-vlaggen**, want de CHANGELOG alleen is niet genoeg: een vlag die verplicht
   wordt breekt elke deploy, maar upstream labelt dat als *Bug Fix*, niet als BREAKING CHANGE. Dat
   is precies hoe wij het bij v2.0.0 misten. Vergelijk per component:

   ```bash
   for v in <oud> <nieuw>; do
     curl -s "https://gitlab.com/api/v4/projects/rinis-oss%2Ffsc%2Fopen-fsc/repository/files/manager%2Fcmd%2Fserve.go/raw?ref=$v" \
       | grep -o 'MarkFlagRequired("[a-z-]*")'
   done
   ```

3. Verzet de tags met `.github/scripts/bump-openfsc.sh <versie>`, en de **digests** in de drie
   wrapper-Dockerfiles met de hand (die kan het script niet weten).
4. Draai `.github/scripts/check-openfsc-version.sh`.
5. Draai de lokale smokes (`deploy/local/run-smokes.sh`) tegen de nieuwe images vóór je naar ZAD
   deployt.
6. Bij een sprong over een major heen: eerst de contract-state op de ZAD-DB's opruimen (zie de
   ZAD-callout hieronder), anders faalt `migrate up` bij de deploy.

### v1.43.7 → v2.5.2 (uitgevoerd)

Drie upstream-wijzigingen uit **v2.0.0** raken deze repo. Let op de versie: ze zijn niet nieuw in
v2.5.2 — wij liepen er tegenaan omdat wij vanaf v1.43.7 in één keer over v2.0.0 heen sprongen. Pin
je ooit terug op een tussenliggende v2.x, dan gelden ze onverkort.

- **Contract-hash.** De contract-content wordt nu gecanonicaliseerd met JCS (RFC 8785) en bevat een
  `fsc_version`. Hashes van vóór v2 zijn niet converteerbaar; upstream schrijft voor bestaande
  contracten uit de database te verwijderen vóór de upgrade. Lokaal: `docker compose … down -v` plus
  `rm -rf contracts/.bootstrap-state`. Zie [`contracts/bootstrap.md`](../contracts/bootstrap.md).
- **Outway-identificatie in een grant.** `outway.public_key_thumbprint` is vervangen door een union
  `outway.identification` met `type` als discriminator
  (`OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT` of `…_DOMAIN_NAME`). `contracts/bootstrap.sh`
  stuurt de thumbprint-variant.

- **`CONTROLLER_REGISTRATION_API_ADDRESS` is verplicht geworden voor de manager.** In v1.43.7 (en
  nog in v1.46.1) was `--controller-registration-api-address` optioneel, met een gedeprecieerd alias
  `--controller-api-address`; **v2.0.0** voegt `MarkFlagRequired` toe — upstream onder *Bug Fixes*,
  niet onder BREAKING CHANGES, wat precies de reden is dat stap 1 hierboven alléén niet volstaat.
  Nagerekend tegen `manager/cmd/serve.go` op v1.46.1 (0 treffers) en v2.0.0 (1). Een manager zonder die env
  weigert te starten met `required flag(s) "controller-registration-api-address" not set` — een
  crashloop met een melding die niet naar de eigenlijke oorzaak wijst. Dit trof onze
  **directory-manager** en de **consumer-manager**; de provider-manager zette 'm al.

  De directory heeft geen controller-component en heeft er ook geen nodig: de manager belt die API
  uitsluitend vanuit het `/token`-endpoint (`manager/apps/ext/query/get_token.go` → `GetService`),
  voor een dienst die déze peer gepubliceerd heeft. De directory publiceert niets. Daarom staat er
  een bewust niet-resolvende hostnaam (`.invalid`): wordt de aanname ooit onwaar, dan faalt het
  luid op DNS in plaats van stil naar een verkeerde controller te praten.

  > **ZAD-actie, buiten git:** `peers/directory/manager.env.example` documenteert deze waarde
  > alleen. De werkelijke env leeft in de Operations Manager UI en moet dáár toegevoegd worden vóór
  > de volgende directory-deploy, anders crashloopt `dirmgr`.

#### ZAD-DB's vóór een major-sprong opruimen

Lokaal wist `docker compose down -v` de databases, maar op ZAD draait `dirmgr` op **managed
Postgres** die een deploy overleeft. De migrate-wrapper voert `migrate up && serve` automatisch uit
bij elke pod-start, dus er is geen moment waarop iemand tussenbeide komt: de v2-manager start op een
DB met v1-contracten. Migratie `023_fsc_version` doet

```sql
ALTER TABLE contracts.content ADD COLUMN fsc_version VARCHAR(20) NOT NULL;   -- geen DEFAULT
```

en Postgres weigert dat bij ook maar één bestaande rij (`column "fsc_version" contains null
values`). Idem `025_outway_identification` op `contracts.grants_service_connection`. De directory
heeft die rijen: hij tekent publicatiecontracten zelf (`AUTO_SIGN_GRANTS`).

Stel vóór de deploy vast of het speelt, en ruim zo nodig op:

```sql
SELECT count(*) FROM contracts.content;                       -- 0 = niets te doen
SELECT count(*) FROM contracts.grants_service_connection;
```

De deploy-workflow draait met `wait-for-ready: 'false'` en meldt **groen** op een crashloopende pod,
dus dit valt niet vanzelf op. Loopt een migratie halverwege stuk, dan blijft golang-migrate `dirty`
achter; herstel dan naar de laatst **geslaagde** versie, niet naar de dirty-versie — anders wordt die
migratie overgeslagen en ontbreken de kolommen permanent. `migrate force` bestaat niet in dit
binary (alleen `up` en `status`), dus dat is handwerk in SQL. Upstream heeft geen down-migraties
(25 up, 0 down): forward-only.

Wat **niet** wijzigde: de wrapper-entrypoints (`<component> migrate up --postgres-dsn` en `serve`
bestaan onveranderd in v2.5.2), de overige env-namen die wij zetten, en het request-body-schema van
`POST /v1/contracts` (dat neemt `createContractContent`, zónder `fsc_version` — de manager vult dat
veld zelf). Verder is `manager --controller-registration-api-address` de **enige** vlag die in de
sprong v1.43.7 → v2.5.2 verplicht werd; controller, txlog-api, inway en outway hebben een
ongewijzigde required-set. Verdwenen zijn twee gedeprecieerde aliassen die wij niet gebruiken:
`manager --controller-api-address` en `controller --listen-address-api` /
`--listen-address-internal`.
