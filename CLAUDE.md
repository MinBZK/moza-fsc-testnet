# CLAUDE.md — Projectcontext voor AI-assistentie

## Project

**moza-fsc-testnet** — een gedeelde **FSC-testomgeving** (Federated Service Connectivity) op ZAD,
waarmee MijnOverheid-Zakelijk-teams federatieve, beveiligde dienstverlening kunnen beproeven.
Begonnen voor de FBS-Berichtenbox-PoC, maar **generiek**: elk team sluit aan als eigen *peer*.

- **Parent-story:** [MinBZK/MijnOverheidZakelijk#661](https://github.com/MinBZK/MijnOverheidZakelijk/issues/661)
- **Gerelateerd project:** [MinBZK/moza-poc-fbs-berichtenbox](https://github.com/MinBZK/moza-poc-fbs-berichtenbox) (de PoC die hiermee gaat testen)

## Taal

Communicatie in het **Nederlands**. Code/technische termen in het Engels waar gangbaar.
Vaste FSC/infra-idiomen niet vertalen: inway, outway, manager, directory, peer, grant, contract,
trust-anchor, passthrough, SNI.

## Wat dit wel/niet is

- **GEEN fork** van de FSC-software. Dit is een **deploy- en configuratie-repo** die de
  [OpenFSC](https://gitlab.com/rinis-oss/fsc/open-fsc) reference implementation consumeert
  (via haar container-images en Helm-charts).
- **WEL**: onze test-CA, group-/peer-configuratie, ZAD-deploy-workflows, contract-bootstrap.

## Implementatie: OpenFSC

[OpenFSC](https://gitlab.com/rinis-oss/fsc/open-fsc) (EUPL-1.2) = reference implementation van de
[FSC Core-standaard](https://gitdocumentatie.logius.nl/publicatie/fsc/core/). **Let op:** `fsc-nlx`
is gearchiveerd en verhuisd naar deze repo (nu onderhouden door RINIS). Docs op
[docs.open-fsc.nl](https://docs.open-fsc.nl). Componenten: manager, inway, outway, directory,
`ca-certportal`, `sni-proxy` + PostgreSQL.

OpenFSC-keuzes die wij overnemen (en die FBS-integratie versimpelen):

- **Peer ID = geldige OIN** (afgeleid uit cert `subject.serialNumber`); Peer-naam uit
  `subject.organization`. In FBS ís het `magazijnId` al de afzender-OIN → **OIN↔PeerID is 1:1**.
- Logging-extensie **verplicht**; CRL-ondersteuning ingebouwd; TLS conform NCSC-richtlijn TLS 2.1.
- Volgt het Digikoppeling REST-API-profiel.

## Kernbeslissingen

- **Trust-anchor = eigen test-CA, GÉÉN PKIoverheid.** We draaien een *gesloten* testnet, dus de
  group zet een eigen test-CA als anchor (zoals OpenFSC lokaal). PKIoverheid is alleen nodig bij
  aansluiting op de productie-overheidsfederatie — buiten scope. (Besluit #720.)
- **Topologie:** één group + één directory + N peers. Elke peer = eigen ZAD-project
  (project-isolatie). FBS-peers (magazijn-org = provider/inway, uitvraag-org = consumer/outway)
  eerst; profiel-org later (#730).
- **Deploymodel (zie `docs/zad-projecten.md`):** peer-templates leven hier (source-of-truth),
  maar **deployen gebeurt bij de app** (inway/outway co-located met de app voor intra-project
  DNS). Directory/group draait centraal vanuit deze repo. Spiegelt OpenFSC's layout
  `helm/deploy/<org>/` (per peer) plus `helm/deploy/shared/` (gedeelde kern).
- **FBS-integratie = config-only:** `berichtenuitvraag` routeert magazijn-calls naar de lokale
  outway i.p.v. direct, door de `Magazijnregister`-URL (`magazijnen."<OIN>".url`) erheen te wijzen.

## ZAD / OpenShift (uit #720 — GO)

mTLS-passthrough is bewezen op het ODCN-prod-cluster (beide poorten, eigen cert, cert-binding intact).

- **Poort 443** (data, Outway→Inway): OpenShift Route met `passthrough`. Schaalt — gedeeld
  router-IP, routering op **SNI**-hostnaam. Elke inway krijgt een eigen, stabiele SNI-hostnaam.
- **Poort 8443** (management, Manager-mesh): MetalLB `LoadBalancer`, eigen publiek IP per endpoint.
  Publieke IP's zijn **schaars** → minimaliseer managers (~1 per project/peer), deel IP's.
- `edge`/`reencrypt`-terminatie of client-cert-in-header **breken** de certificate-binding — verboden.
- **ZAD deployt images, geen Helm.** `zad-actions/deploy` neemt een `components:`-lijst van
  `{name, image}`. OpenFSC-charts = bron voor image- + env-namen, niet het deploy-artefact.
  Config = env-vars + gemounte certs (Operations Manager, éénmalig; previews erven via
  `clone-from: test`). **Blocker #723:** DB-migratie draait in OpenFSC via init-container-args
  (`manager migrate up`) — ZAD staat geen args/init-containers toe; alternatief nodig.
- ZAD-pods configureren via **env-vars / gemounte files**, niet via CLI-args (ZAD staat geen
  component-args toe).

### Openstaande ZAD-dependency (blocker voor #722/#723)

ZAD heeft (nog) geen cert-upload. Er komt een generiek `attachments`-blok (encrypted opslag,
read-only mount in de pod). Nodig vóór per-peer certs gemount kunnen worden. Beleggen bij ZAD-beheer.

## Repo-structuur

```text
docs/        ontwerp: topologie.md + ontwerpkeuzes.md
pki/         test-CA als trust-anchor + cert-generatie
group/       group-id, trust-anchor, group rules (TLS)
peers/       per peer: Helm-values + OIN + adressen
contracts/   grant → sign → accept bootstrap
.github/     ZAD deploy/cleanup workflows
```

## Conventies

- **Secrets nooit committen.** Sleutels/certs/`.env` blijven buiten git (zie `.gitignore`).
  Alleen scripts en `.example`-templates in de repo.
- Toekomstig werk markeren met `TODO(#nnn)` verwijzend naar het GitHub-issue.
- **Git:** nooit direct naar `main` pushen — feature branch + PR. Branch-prefix `feature/`,
  `fix/`, `chore/`. Geen reviewer toevoegen bij aanmaken PR. `main` is **branch-protected**
  (1 review verplicht, conversation-resolution, geen force-push); required checks: `lint`,
  `Analyze (actions)`.
- **CI:** `lint.yml` (markdownlint + yamllint + actionlint), `codeql.yml` (Actions-analyse),
  `scorecard.yml` (OpenSSF). Actions SHA- of versie-gepind; Dependabot houdt ze maandelijks bij.
- **AI-verantwoording:** AI-bijdragen markeren met `Co-Authored-By`-trailer; zie `DISCLAIMER.md`
  en `docs/ai-verantwoording.md`. Governance/support/security delegeren naar de MOZa-hoofdrepo.
- `gh` CLI voor GitHub-operaties.

## Issues / stappenplan

Onder #661: #720 (mTLS-spike, **done/GO**) · #721 (repo-skelet + governance/CI, **in afronding**)
· #722 PKI · #723 directory+group · #724 peer magazijn · #725 peer uitvraag
· #726 FBS-integratie · #727 contracten · #728 e2e+logging · #729 CI+cleanup · #730 profiel-peer.

**Huidige stap: #722 (test-PKI).** Het CA/cert-genereer-werk kan vooruit (OpenFSC `ca`/`ca-certportal`);
alleen het *mounten* van certs wacht op de ZAD `attachments`-feature.

## Referenties

- [FSC Core-spec (Logius)](https://gitdocumentatie.logius.nl/publicatie/fsc/core/) — mTLS verplicht, poorten 443/8443
- [RFC 8705](https://datatracker.ietf.org/doc/html/rfc8705) — mTLS client-auth + certificate-bound tokens (`cnf.x5t#S256`)
- [OpenFSC](https://gitlab.com/rinis-oss/fsc/open-fsc) · [docs.open-fsc.nl](https://docs.open-fsc.nl)
