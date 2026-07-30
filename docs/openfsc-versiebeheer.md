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
2. Verzet tag **én** digest in de drie Dockerfiles, de workflow-defaults en de lokale compose.
3. Draai `.github/scripts/check-openfsc-version.sh`.
4. Draai de lokale smokes (`deploy/local/run-smokes.sh`) tegen de nieuwe images vóór je naar ZAD
   deployt.

### v1.43.7 → v2.5.2 (uitgevoerd)

Twee breaking changes uit v2.0.0 raken deze repo:

- **Contract-hash.** De contract-content wordt nu gecanonicaliseerd met JCS (RFC 8785) en bevat een
  `fsc_version`. Hashes van vóór v2 zijn niet converteerbaar; upstream schrijft voor bestaande
  contracten uit de database te verwijderen vóór de upgrade. Lokaal: `docker compose … down -v` plus
  `rm -rf contracts/.bootstrap-state`. Zie [`contracts/bootstrap.md`](../contracts/bootstrap.md).
- **Outway-identificatie in een grant.** `outway.public_key_thumbprint` is vervangen door een union
  `outway.identification` met `type` als discriminator
  (`OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT` of `…_DOMAIN_NAME`). `contracts/bootstrap.sh`
  stuurt de thumbprint-variant.

Wat **niet** wijzigde: de wrapper-entrypoints (`<component> migrate up --postgres-dsn` en `serve`
bestaan onveranderd in v2.5.2), de env-namen die wij zetten, en het request-body-schema van
`POST /v1/contracts` (dat neemt `createContractContent`, zónder `fsc_version` — de manager vult dat
veld zelf). Wel verdwenen zijn twee gedeprecieerde vlaggen die wij niet gebruiken:
`manager --controller-api-address` en `controller --listen-address-api` /
`--listen-address-internal`.
