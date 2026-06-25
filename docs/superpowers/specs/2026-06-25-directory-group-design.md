# Ontwerp — centrale directory + federatiegroep (#723)

> Status: ontwerp, goedgekeurd 2026-06-25. Vervolg: implementatieplan via
> `docs/superpowers/plans/`. Hoort bij issue
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

### Blocker en de gekozen omgang ermee

ZAD heeft (nog) geen `attachments` (cert-mount), de bekende blocker voor #722/#723
(`docs/zad-projecten.md`). Zonder cert-mount kan de live-ZAD-deploy geen
group-trust opzetten → **criterium 1 en 3 kunnen niet live groen** op deze branch.

Besluit (2026-06-25): we splitsen het werk in twee sporen die beide *nu* af kunnen,
en nemen voor lief dat de echte ZAD-deploy pas slaagt zodra `attachments` er is.

- **Spoor A — ZAD-deploy-prep.** Alle deploy-artefacten productieklaar: component-
  + image-lijst, env-templates met échte OpenFSC-namen, group-config, deploy-job.
  De `workflow_dispatch`-deploy zal falen op de ontbrekende certs; dat is verwacht.
- **Spoor B — lokale docker-compose harness (shift-left).** Een getrouwe,
  *runnable* spiegel van de directory-stack + één announcing peer, met onze test-CA-
  certs. Bewijst criterium 3 lokaal **nu** en is herbruikbaar voor e2e (#728).

## 2. Parity-principe (lokaal ≡ ZAD)

De harness is geen apart bouwsel maar een shift-left van de ZAD-deploy. Wat
**identiek** is over beide omgevingen:

- **Container-images** — zelfde OpenFSC-images, zelfde gepinde tags.
- **Env-var-namen** — alleen de *waarden* verschillen (zie hieronder).
- **Cert-mount-paden** — lokaal bind-mount van `pki/out/` read-only op hetzelfde
  pad als de ZAD-`attachments`-mount, zodat `TLS_*`-env letterlijk gelijk is.

Wat **noodzakelijk verschilt** (en alleen in env-*waarden* zit):

- **Adressen** — compose-service-DNS (`directory-manager:8443`) lokaal vs
  ZAD-ingress-URL's (`<component>-<deployment>-<projectid>.rig.prd1…`) op ZAD.
- **Management-laag (8443)** — lokaal plain TCP tussen compose-services; op ZAD een
  MetalLB-`LoadBalancer`-IP per manager (#720, IP-schaarste).

## 3. Componenten — wie waar

Het **directory-project** (`fsc-directory`, group-anker, beheerd vanuit deze repo)
is het #723-deploy-target. De **peer**-rij hoort op ZAD bij #724 (magazijn-project);
lokaal draaien we 'm mee om announce te kunnen bewijzen.

| Component | ZAD-project | In lokale harness? | Rol |
|-----------|-------------|--------------------|-----|
| directory-manager | `fsc-directory` | ✅ | FSC-manager, directory-rol; group-anker |
| directory | `fsc-directory` | ✅ | directory-dienst (catalogus-backend) |
| directory-ui | `fsc-directory` | ✅ | gedeelde dienstencatalogus (web-UI) |
| dex | `fsc-directory` | ✅ | OIDC-provider voor directory-ui + controller |
| txlog-api | `fsc-directory` | ✅ | transaction-log (verplichte logging-extensie) |
| postgres | `fsc-directory` | ✅ | DB directory-project |
| magazijn-a manager | peer-project (#724) | ✅ | announcer in de demo |
| magazijn-a controller | peer-project (#724) | ✅ | peer-side beheer-UI |
| magazijn-a postgres | peer-project (#724) | ✅ | DB peer |

> `controller` is **per-peer** (`docs/ontwerpkeuzes.md`), niet onderdeel van het
> directory-project. In de harness hangt 'ie aan de magazijn-a-peer, puur om de
> volledige stack te tonen.

De exacte componentnamen, images en env-var-sets worden tijdens implementatie
**gegrond tegen de echte OpenFSC** (`helm/charts/open-fsc-*` + de meegeleverde
`docker-compose`/`deploy`-voorbeelden op
<https://gitlab.com/rinis-oss/fsc/open-fsc>), niet tegen het uittreksel in
`docs/zad-projecten.md`. Reden: eerdere `values.example.yaml` bevatte verzonnen
keys; die fout herhalen we niet.

## 4. Groep- & trust-configuratie (criterium 2)

`group/group-config.example.yaml` finaliseren tot de echte OpenFSC-group-config:

- **group-id**: `moza-fbs-test`.
- **trust-anchor**: `pki/ca/root.pem` (test-CA root) + `pki/ca/intermediate.crl`
  (CRL, intermediate als issuer). Géén PKIoverheid (#720).
- **TLS-min-regel**: conform NCSC-richtlijn TLS 2.1 / OpenFSC-default. Exacte
  sleutel + waarde grounden tegen de OpenFSC-group-schema.

## 5. DB-migratie (open blocker uit `docs/zad-projecten.md`)

OpenFSC draait migraties in zijn charts via een init-container met args
(`manager migrate up`); ZAD staat geen args/init-containers toe. Aanpak:

1. **Onderzoek** het echte OpenFSC-startgedrag bij het bouwen van de harness — de
   compose moet sowieso migreren, dus het mechanisme blijkt empirisch.
2. **Voorkeur**: een stock-env die auto-migratie-bij-boot aanzet, als die bestaat
   (dan is ZAD-compatibel = env zetten, klaar).
3. **Fallback**: documenteer een one-shot migratie-component (eigen deployment die
   het migrate-entrypoint draait), géén eigen image bakken indien vermijdbaar
   (CLAUDE.md: geen fork / stock-images).
4. **Resultaat** sluit het open punt in `docs/zad-projecten.md`.

## 6. ZAD-deploy-artefacten (spoor A)

- **`peers/directory/values.example.yaml`** + per-component **env-templates**
  (`.env.example`-stijl) met échte OpenFSC env-namen.
- **`.github/workflows/deploy.yml`**: `directory`-job die `zad-actions/deploy`
  aanroept met `components`-JSON (images gepind). Blijft `workflow_dispatch`.
  - Inputs (gegrond tegen `RijksICTGilde/zad-actions` `deploy/action.yml`):
    `api-key` ← secret **`ZAD_API_KEY_DIRECTORY`** (project-gescoopt, ZAD geeft 'm
    uit bij projectaanmaak); `project-id` ← **`ZAD_PROJECT_ID_DIRECTORY`**;
    `components` ← de directory-componentlijst. Beide secrets bestaan al in de repo.
  - SHA-pinnen conform repo-conventie.

### ZAD-projecten die de mens moet aanmaken

- **Eén** project voor #723: het directory/group-anker (`fsc-directory`). ZAD kent
  de echte `project-id` toe (format `xxxx-xxx`).
- Peer-projecten (magazijn #724, uitvraag #725, profiel #730) worden **bij de app**
  in die issues aangemaakt — niet in #723.

## 7. Lokale harness (spoor B)

```text
deploy/local/docker-compose.yaml   volledige directory-stack + announcing peer
deploy/local/smoke-announce.sh     compose up -> assert announce -> exit 0
deploy/local/README.md             run-instructies (pki-scripts vooraf)
```

- **Certs**: bind-mount `pki/out/` + `pki/ca/` read-only op de cert-paden uit de
  env-templates. User draait eerst de `pki/`-scripts (bestaan al uit #722).
- **Announcer**: `magazijn-a`-manager (heeft al cert in `pki/out/magazijn-a/manager/`).
- **Smoke-assert**: na `compose up` bevragen we de directory (directory-API of de
  manager) en asserten dat de magazijn-a-peer-ID als aangemeld verschijnt; exit 0 =
  groen. Exacte query grounden tegen de OpenFSC-directory-API.

## 8. Testing & bewijs

| Criterium | Bewijs op deze branch |
|-----------|------------------------|
| 1. Directory draait | ZAD-deploy-artefacten compleet + lokaal `compose up` groen (live-ZAD wacht op `attachments`). |
| 2. Groep geconfigureerd | `group-config` gefinaliseerd; harness gebruikt 'm. |
| 3. Peer announce aantoonbaar | `smoke-announce.sh` exit 0 (lokaal, met test-CA-certs). |

Volgorde: `pki/`-scripts → `docker compose up` → `smoke-announce.sh`. Live-ZAD niet
getest (geen `attachments`); dat is de bewust geaccepteerde gap.

## 9. Te wijzigen / nieuwe bestanden

```text
group/group-config.example.yaml            finalize (sectie 4)
peers/directory/values.example.yaml        echte OpenFSC env-namen
peers/directory/*.env.example              per-component env-templates (nieuw)
deploy/local/docker-compose.yaml           nieuw — harness
deploy/local/smoke-announce.sh             nieuw — announce-assert
deploy/local/README.md                     nieuw — run-instructies
.github/workflows/deploy.yml               + directory-job (sectie 6)
docs/zad-projecten.md                      migratie-open-punt sluiten (sectie 5)
```

## 10. Buiten scope

- Live-ZAD-deploy die slaagt (wacht op `attachments`).
- Peer-deploys magazijn/uitvraag op ZAD (#724/#725).
- Contract-bootstrap grant→sign→accept (#727).
- Echte auth op de UIs vervangt default `admin/password` (signaleren, niet oplossen).
