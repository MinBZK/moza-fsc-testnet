# Ontwerpkeuzes

## Implementatie: OpenFSC

We gebruiken [OpenFSC](https://gitlab.com/rinis-oss/fsc/open-fsc) (EUPL-1.2), de reference
implementation van de [FSC Core-standaard](https://gitdocumentatie.logius.nl/publicatie/fsc/core/)
(voorheen `fsc-nlx`, nu onderhouden door RINIS). Levert manager, inway, outway, directory,
controller (beheer-UI), directory-ui (dienstencatalogus), ca-certportal en sni-proxy als
containers + Helm-charts.

Afgewogen alternatieven: Logius `fsc-test-suite` (= conformance-tests, geen draaibaar netwerk —
optioneel later als poort) en zelf bouwen (te veel werk voor een PoC).

### Relevante OpenFSC-implementatiekeuzes (overgenomen)

- **Peer ID = geldige OIN**, afgeleid uit `subject.serialNumber` van het X.509-cert.
- **Peer-naam** uit `subject.organization`.
- Logging-extensie **verplicht**; CRL-ondersteuning ingebouwd.
- TLS conform NCSC-richtlijn TLS 2.1.

> **Aansluiting op FBS:** in FBS ís het `magazijnId` al de afzender-OIN. Dat valt 1:1 samen
> met de FSC Peer ID — de OIN↔PeerID-mapping (#726) is daarmee triviaal.

## Trust-anchor: eigen test-CA, géén PKIoverheid

We draaien een **gesloten testnet**, dus de group zet een **eigen test-CA** als trust-anchor
(zoals OpenFSC lokaal ook doet). PKIoverheid is alleen vereist bij aansluiting op de
**productie-overheidsfederatie** — buiten scope. Zelf-ondertekende certs zijn direct beschikbaar
en vermijden levertijd/IP-schaarste. Besluit bevestigd in #720.

## Beheer via controller-UI + directory-ui (geen eigen dienst/afnemer-administratie)

We gebruiken OpenFSC's **controller** (per-peer beheer-UI) en **directory-ui** (gedeelde
dienstencatalogus) als beheer-interface — zoals het productie-systeem werkt. De controller
biedt: dienst publiceren (provider), *connect-to-service* (afnemer vraagt toegang aan →
ServiceConnectionGrant), contracten accepteren/intrekken en transactielogs inzien.

**Gevolg — geen eigen administratie van diensten/afnemers.** De waarheid leeft in het draaiende
systeem: gepubliceerde diensten in de **directory**, contracten/grants in elke **manager** (hun
PostgreSQL). Geen apart, met-de-hand-bijgehouden register. In ruil komt er één
verantwoordelijkheid bij: **DB-duurzaamheid** — directory- en manager-databases zijn nu
system-of-record en moeten persistent + gebackupt op ZAD (niet ephemeral/preview-cloned).

**Wat tóch van ons blijft** (laag ónder de controller):

1. **Identiteit/toelating** — wie een cert van onze test-CA krijgt bepaalt netwerktoegang (#722);
   de controller/directory beheren géén identiteiten.
2. **Group/trust-config** — group-id, trust-anchor, group-rules (`group/`).
3. **Deploy/peer-config** — `peers/*/values` (OIN, adressen), per peer = ZAD-project.
4. **FBS-routing** (#726) — `magazijnen."<OIN>".url` → outway, business-app-kant.

**Scope-gevolg:**

- **#723 (deploy):** componentlijst uitbreiden met `controller` (per peer) + `directory-ui`
  (gedeeld). ZAD-impact beperkt: controller = HTTP web-UI via edge-Route, géén 8443-mesh, dus
  geen IP-schaarste. Let op: default-login `admin/password` → echte auth vereist op ZAD.
- **#727 (contracten):** met de controller-UI wordt het gescripte `grant→sign→accept` **optioneel**
  — nog nuttig om initiële contracten voor te laden of voor e2e-tests (#728), niet voor dagelijks
  gebruik.

## ZAD / OpenShift (uit #720, GO)

- **mTLS-passthrough bewezen** op het ODCN-prod-cluster, beide poorten, eigen cert.
- Poort **443** (data Outway→Inway **én manager-mesh**): OpenShift Route met `passthrough`.
  Schaalt — gedeeld router-IP, routering op **SNI**-hostnaam. Elke inway én elke manager
  krijgt een eigen, stabiele SNI-hostnaam. **Manager-mesh op :443 bewezen** in
  `docs/spikes/manager-443-sni.md` (#723).
- Poort **8443** (Manager-mesh via MetalLB): **vervallen (#723)** — de mesh loopt nu op
  :443-SNI (zie boven). MetalLB-IP's blijven schaars maar zijn voor de mesh niet meer nodig.
- `edge`/`reencrypt` of client-cert-in-header **breken** de certificate-binding — verboden.

### Migratie op ZAD = wrapper-image (#723)

OpenFSC migreert de DB via een init-container met args (`manager migrate up`). ZAD ondersteunt
(nog) geen component-args/init-containers. Oplossing: een dunne **wrapper-image**
(`deploy/zad/manager-migrate/`) met een entrypoint dat eerst `manager migrate up` draait en
daarna `manager serve` exec't. Het is een *deploy-image* boven de stock-image, **geen
broncode-fork** — consistent met "geen fork van de FSC-software".

### Keycloak als OIDC-provider (#723)

De controller-beheer-UI doet OIDC. OpenFSC levert standaard **Keycloak** (baked realm
`organization-a`), niet Dex. Lokaal draait de controller bewust **zonder** login
(`AUTHN_TYPE=none`, een door OpenFSC ondersteunde modus); volledige OIDC is een
gedocumenteerde TODO (issuer-split + redirect-URI — zie `deploy/local/README.md`).

### ZAD-dependency: cert-mount (opgelost, 2026-06-29)

ZAD `attachments` (generiek blok: encrypted opslag, read-only mount in de pod) is beschikbaar.
Per-peer certs kunnen gemount worden — #722/#723 zijn hierop niet langer geblokkeerd.

### Auto-deploy directory naar `test` op main

Een merge naar `main` (CI groen) rolt de centrale **directory** automatisch uit naar
ZAD-deployment `test`. Dit spiegelt het `moza-poc-fbs-berichtenbox`-model: geautomatiseerde tests
(en eventueel functioneel op de preview-branch) → main → automatische update van `test`. Vóór dit
besluit was `zad-deploy-directory.yml` alleen handmatig (`workflow_dispatch`).

**Scope: alleen de centrale directory.** Peers (`example-consumer`/`-provider`) deployen bij de app
(eigen ZAD-projecten) en beslissen **zelf** of/hoe ze auto-deployen — geen generiek peer-mechanisme
hier.

Gemaakte keuzes:

- **Bestaande workflow uitbreiden** (niet een nieuwe file): `zad-deploy-directory.yml` krijgt náást
  `workflow_dispatch` een `push`-trigger op main én een `pull_request`-trigger. Een PR
  (`opened`/`synchronize`/`reopened`) rolt automatisch een preview `pr-<PR-nummer>` uit; bij
  `closed` ruimt een `cleanup-preview`-job die op. `workflow_dispatch` blijft voor handmatige
  overrides. `upsert-directory.sh`/`cleanup.sh` zijn de gedeelde bron.
- **Eén workflow, 3 jobs** (`changes` → `build` → `deploy`) tegen de build-deploy-race: een
  image-wijziging bouwt éérst (`build-manager-migrate` als reusable `workflow_call`), pas dán
  deployt `apply`. Een config/group-only merge skipt de build en herbruikt de bestaande tag.
- **`git diff` in een run-step** detecteert de image-wijziging — geen marketplace-action, dus geen
  extra action-SHA te pinnen → OpenSSF Scorecard blijft groen. Om dezelfde reden stopt
  `build-manager-migrate` z'n eigen `push`-build op main (`branches-ignore: [main]`): main bouwt
  via de reusable-call (geen dubbele build + geen concurrency-clash).
- **Trigger-paths:** `deploy/zad/upsert-directory.sh`, `deploy/zad/manager-migrate/**`, `group/**`
  en de workflow zelf. `group/**` erbij voor zichtbaarheid, al is een group-wijziging via de API
  meestal een no-op (trust-anchor/certs zijn UI-only bijlagen).
- **Failure = kale rode workflow-run** in de Actions-tab. Bewust geen auto-issue: wordt dit ooit te
  vaak gemist, dan gaan we naar échte externe notificatie (Slack/mail), niet naar een
  half-oplossing. Fully-auto, géén environment-approval (conform het FBS-model).

Ontwerp: `docs/superpowers/specs/2026-07-02-auto-deploy-test-design.md`. Mechaniek:
`docs/zad-directory-deploy.md`.

**PR-preview-eigenschappen:** eigen deployment `pr-<PR-nummer>` met een eigen verse managed DB
(de SoR-`test`-DB wordt niet gekloond/geleegd). Bijlagen (cert-mount) en "Publicatie op het web"
zitten op project/component-niveau en worden per deployment automatisch geërfd — geen handwerk per
PR. Fork-PR's worden geskipt (geen secrets). Docs-only PR's deployen niet.
