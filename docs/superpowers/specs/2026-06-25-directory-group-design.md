# Ontwerp — centrale directory + federatiegroep (#723)

> Status: ontwerp, goedgekeurd 2026-06-25, **herzien na grounding tegen OpenFSC +
> de 443-mesh-spike**. Vervolg: implementatieplan via `docs/superpowers/plans/`.
> Hoort bij issue
> [MinBZK/MijnOverheidZakelijk#723](https://github.com/MinBZK/MijnOverheidZakelijk/issues/723)
> onder parent #661.

## 1. Aanleiding & doel

De federatie heeft een centraal "telefoonboek" nodig waar peers zich aanmelden
(announce) en diensten publiceren. #723 levert de **directory + groep**: de
group-anker-deploy op ZAD plus de configuratie die peers nodig hebben om zich te
melden.

### Acceptatiecriteria (uit het issue)

1. Directory + ondersteunende onderdelen draaien op ZAD.
2. Groep geconfigureerd: group-id, vertrouwensbasis = test-CA, minimale TLS-regels.
3. Aantoonbaar dat een peer zich kan aanmelden (announce) bij de directory.

### Blockers en de gekozen omgang ermee

Twee ZAD-blockers raken criterium 1 en 3, beide bevestigd door grounding:

- **Geen cert-mount** (`attachments`) op ZAD — bekend (#722/#723).
- **Geen migratie zonder args/init-container.** De manager migreert *alleen* via
  `manager migrate up` (CLI-subcommand; geen env-auto-migrate). OpenFSC draait dat
  in een init-container met args; ZAD verbiedt beide
  (`open-fsc/helm/charts/open-fsc-manager/templates/deployment.yaml:214`,
  `manager/cmd/migrate.go`).

Besluit (2026-06-25): werk splitsen in twee sporen die beide *nu* af kunnen; de
echte ZAD-deploy slaagt pas zodra `attachments` er is.

- **Spoor A — ZAD-deploy-prep.** Alle deploy-artefacten productieklaar: component-
  + image-lijst, env-templates met échte OpenFSC-namen, group-config, deploy-job,
  én een **wrapper-image** die de migratie-blocker omzeilt (zie §5).
- **Spoor B — lokale docker-compose harness (shift-left).** Een getrouwe, runnable
  spiegel, **voortbouwend op de bewezen 443-mesh-spike** (§7). Bewijst criterium 3
  lokaal nu en is herbruikbaar voor e2e (#728).

## 2. Twee grounding-correcties t.o.v. eerdere aannames

1. **Keycloak, geen Dex.** OpenFSC levert **Keycloak** als OIDC-provider
   (`open-fsc/docker-compose.yml:28`, chart `open-fsc-keycloak`,
   `helm/deploy/shared`). Het issue noemt "Dex"; wij volgen OpenFSC → Keycloak.
2. **Manager-mesh op 443, géén 8443/MetalLB.** Bewezen in de spike
   (`docs/spikes/manager-443-sni.md`, runtime-groen 2026-06-25, image `v1.43.7`):
   de manager authenticeert op **OIN, niet op hostname**, dus de mesh draait op
   **:443 achter een SNI-passthrough-router** (HAProxy `mode tcp` lokaal ≙
   OpenShift-`passthrough`-Route op ZAD). Dit schrapt de MetalLB-`LoadBalancer` +
   schaarse publieke IPv4 per manager uit het ZAD-ontwerp (#720-aanname vervalt
   voor de mesh). Cert hoeft de hostname niet in z'n SAN te hebben.

## 3. Parity-principe (lokaal ≡ ZAD)

De harness is geen apart bouwsel maar een shift-left van de ZAD-deploy. Wat
**identiek** is over beide omgevingen:

- **Container-images** — zelfde OpenFSC-images, zelfde gepinde tags (`v1.43.7`,
  zoals de spike draaide; tags pinnen tijdens implementatie).
- **Env-var-namen** — alleen de *waarden* verschillen.
- **Cert-mount-paden** — lokaal bind-mount van de test-CA read-only op hetzelfde
  pad als de ZAD-`attachments`-mount, zodat `TLS_*`-env letterlijk gelijk is.
- **Router-mechanisme** — SNI-passthrough op :443 (HAProxy `mode tcp` lokaal,
  OpenShift-`passthrough`-Route op ZAD).

Wat **noodzakelijk verschilt** (alleen env-*waarden*): adressen (compose-service-DNS
+ SNI-hostnames lokaal vs ZAD-ingress-URL's op ZAD).

## 4. Componenten — wie waar

Het **directory-project** (`fsc-directory`, group-anker, beheerd vanuit deze repo)
is het #723-deploy-target. "directory" is **geen apart image** maar een **manager in
directory-mode** (`DIRECTORY_PEER_ID` = eigen peer-ID, lege `TX_LOG_API_ADDRESS`;
`open-fsc/helm/charts/open-fsc-manager/values.yaml:119`). De **peer**-rij hoort op
ZAD bij #724; lokaal draaien we 'm mee om announce te bewijzen.

| Component | Image (registry `docker.io/federatedserviceconnectivity/`) | ZAD-project | In harness? | Rol |
|-----------|------------------------------------------------------------|-------------|-------------|-----|
| directory-manager | `manager` | `fsc-directory` | ✅ | manager in directory-mode; group-anker |
| directory-ui | `directory-ui` | `fsc-directory` | ✅ | gedeelde dienstencatalogus (web-UI) |
| keycloak | `registry.gitlab.com/rinis-oss/fsc/images/keycloak` | `fsc-directory` | ✅ | OIDC voor directory-ui + controller |
| postgres | `postgres:17` | `fsc-directory` | ✅ | DB (meerdere databases, per peer één) |
| router | `haproxy` (lokaal) / OpenShift-Route (ZAD) | infra | ✅ | SNI-passthrough op :443 |
| magazijn-a manager | `manager` | peer-project (#724) | ✅ | announcer in de demo |
| magazijn-a controller | `controller` | peer-project (#724) | ✅ | peer-side beheer-UI |
| magazijn-a txlog-api | `txlog-api` | peer-project (#724) | ✅ | transaction-log (verplicht voor niet-directory peers) |

> `controller` + `txlog-api` zijn **per-peer** (`docs/ontwerpkeuzes.md`,
> `open-fsc/helm/deploy/gemeente-stijns`), niet in het directory-project. De
> directory-manager zet `TX_LOG_API_ADDRESS` leeg (directory-mode).
> `AUDITLOG_TYPE=stdout` lokaal → geen aparte auditlog-container nodig.

## 5. Migratie (blocker uit `docs/zad-projecten.md`) — opgelost

- **Lokaal**: one-shot compose-service per DB, `command: [".../manager","migrate",
  "up","--postgres-dsn", …]` (compose mág args). Bewezen in de spike.
- **ZAD** (geen args/init-containers): **dunne wrapper-image** —
  `FROM docker.io/federatedserviceconnectivity/manager:<tag>` met een entrypoint
  dat `manager migrate up && manager serve` draait. Daarmee is "migreren-dan-serven"
  in de image gebakken, zonder ZAD-args. Gekozen 2026-06-25.
  - **Let op — afwijking van CLAUDE.md "geen eigen image/fork".** Dit is een
    *deploy-image* (dunne laag boven de stock-image), géén fork van de
    FSC-broncode. Leg de rationale vast in `docs/ontwerpkeuzes.md` + werk de
    kernbeslissing in `CLAUDE.md` bij. Build/publish hoort bij #729 (CI).

## 6. PKI-afhankelijkheid (#722)

Een werkende manager wil méér certs dan het ene identity-cert dat #722 nu uitgeeft
(`open-fsc/helm/charts/open-fsc-manager/templates/deployment.yaml:103-128`):
`TLS_GROUP_TOKEN_*`, `TLS_GROUP_CONTRACT_*`, `TLS_CERT/KEY` + `TLS_ROOT_CERT`
(internal), `TLS_INTERNAL_UNAUTHENTICATED_*`. Dit is **cert-gen-werk = #722-domein**;
gemeld als comment op PR #5. **#723 consumeert** deze certs; de uitbreiding zelf is
een prerequisite (zie §11, open beslissing over waar het werk landt).

## 7. Lokale harness (spoor B) — voortbouwend op de spike

De spike `docs/spikes/manager-443-sni/` bewijst de kern al: directory + 2
peer-managers + postgres + HAProxy-SNI-router op :443, announce gepersisteerd in de
directory-DB. Spoor B **evolueert** die spike naar de echte harness:

```text
deploy/local/docker-compose.yaml   directory-mode-manager + directory-ui + keycloak
                                    + postgres + HAProxy-router + magazijn-a-peer
                                    (manager + controller + txlog-api)
deploy/local/haproxy.cfg           SNI-passthrough (uit de spike)
deploy/local/smoke-announce.sh     compose up -> assert announce -> exit 0
deploy/local/README.md             run-instructies
```

Verschillen met de spike (= het #723-werk):

- **Onze test-CA** i.p.v. de open-fsc dev-`pki` (afhankelijk van §6).
- **Onze peers** (`magazijn-a` als announcer) i.p.v. generieke org-a/org-b.
- **+ directory-ui + keycloak + controller + echte txlog-api** (volledige stack,
  gekozen 2026-06-25) i.p.v. alleen de mesh.
- **CRL aan** waar mogelijk (de spike zette `DISABLE_CRL_CHECKS=true`); lokaal de
  test-CRL hosten of bewust uitgezet documenteren.
- **Announce-assert geautomatiseerd** (`smoke-announce.sh`) i.p.v. handmatig logs
  lezen.

**Announce-verify**: na `compose up` de directory bevragen via `GET /v1/peers`
(interne API, poort 9443, mTLS met internal-cert) **of** de directory-DB
(`peers.peers`) en asserten dat de magazijn-a-peer-ID met `manager_address` op :443
verschijnt; exit 0 = groen. (`open-fsc/manager/ports/int/rest/list_peers.go`.)

## 8. ZAD-deploy-artefacten (spoor A)

- **`peers/directory/values.example.yaml`** + per-component **env-templates** met
  échte OpenFSC env-namen (gegrond tegen de manager-chart).
- **`.github/workflows/deploy.yml`**: `directory`-job die `zad-actions/deploy`
  aanroept met `components`-JSON (images gepind, manager = wrapper-image).
  Blijft `workflow_dispatch`.
  - Inputs (gegrond tegen `RijksICTGilde/zad-actions` `deploy/action.yml`):
    `api-key` ← secret **`ZAD_API_KEY_DIRECTORY`**; `project-id` ←
    **`ZAD_PROJECT_ID_DIRECTORY`**; `components` ← de directory-componentlijst.
    Beide secrets bestaan al in de repo.
  - Manager-mesh op **:443 via OpenShift-`passthrough`-Route** (geen MetalLB, §2).
  - SHA-pinnen conform repo-conventie.
- **DB-duurzaamheid = ZAD-vereiste** (scope-aanvulling #723-comment 2026-06-24).
  De directory- en manager-PostgreSQL zijn **system-of-record** (geen eigen
  dienst/afnemer-administratie meer — `docs/ontwerpkeuzes.md`). Daarom moet de
  directory-DB op ZAD **persistent + gebackupt** zijn en **uitgezonderd van
  `clone-from: test`** (previews mogen 'm niet klonen/legen). Vastleggen in
  `docs/zad-projecten.md` + beleggen bij ZAD-beheer als deploy-vereiste.

### ZAD-projecten die de mens moet aanmaken

- **Eén** project voor #723: het directory/group-anker (`fsc-directory`). ZAD kent
  de echte `project-id` toe (format `xxxx-xxx`).
- Peer-projecten (magazijn #724, uitvraag #725, profiel #730) worden **bij de app**
  in die issues aangemaakt — niet in #723.

## 9. Groep- & trust-configuratie (criterium 2)

`group/group-config.example.yaml` finaliseren: **group-id** `moza-fbs-test`,
**trust-anchor** = test-CA root + CRL (géén PKIoverheid), **TLS-min** conform NCSC
TLS 2.1 / OpenFSC-default. Group-id in de harness = `GROUP_ID`-env op alle managers.

## 10. Testing & bewijs

| Criterium | Bewijs op deze branch |
|-----------|------------------------|
| 1. Directory draait | ZAD-artefacten compleet + lokaal `compose up` groen (live-ZAD wacht op `attachments`). |
| 2. Groep geconfigureerd | `group-config` gefinaliseerd; harness gebruikt 'm via `GROUP_ID` + trust-anchor. |
| 3. Peer announce aantoonbaar | `smoke-announce.sh` exit 0 (lokaal, test-CA, mesh op :443). |

Volgorde: certs (§6) → `docker compose up` → `smoke-announce.sh`. Live-ZAD niet
getest (geen `attachments`); bewust geaccepteerde gap.

## 11. Te wijzigen / nieuwe bestanden

```text
group/group-config.example.yaml            finalize (§9)
peers/directory/values.example.yaml        echte OpenFSC env-namen + directory-mode
peers/directory/*.env.example              per-component env-templates (nieuw)
deploy/local/docker-compose.yaml           nieuw — harness (evolueert spike)
deploy/local/haproxy.cfg                    nieuw — SNI-router (uit spike)
deploy/local/smoke-announce.sh             nieuw — announce-assert
deploy/local/README.md                     nieuw — run-instructies
deploy/zad/manager-migrate/Dockerfile      nieuw — wrapper-image (§5)
.github/workflows/deploy.yml               + directory-job (§8)
docs/zad-projecten.md                      migratie + 443-mesh open-punten sluiten
docs/ontwerpkeuzes.md                      wrapper-image-rationale + 443-mesh
CLAUDE.md                                  kernbeslissing 8443→443 + wrapper-image
```

## 12. Open beslissingen vóór het plan

- **PKI-extensie (§6)**: landt in #722 (PR #5) of toch in #723? Bepaalt of de
  harness-cert-stap een prerequisite of een #723-taak is.
- **Spike-dispositie (§7)**: `docs/spikes/manager-443-sni/` promoveren naar
  `deploy/local/`, of de spike als bewijs laten staan en de harness vers bouwen?

## 13. Buiten scope

- Live-ZAD-deploy die slaagt (wacht op `attachments`).
- Peer-deploys magazijn/uitvraag op ZAD (#724/#725).
- Contract-bootstrap grant→sign→accept (#727).
- Echte auth op de UIs vervangt default Keycloak-admin (signaleren, niet oplossen).
