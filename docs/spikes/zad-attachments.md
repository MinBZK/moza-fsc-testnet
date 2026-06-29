# Spike: ZAD attachments → FSC-cert-mount

> Status: **open** (#723/#722). Doel: vaststellen hoe ZAD `attachments` precies werken, zodat
> we de FSC-certs op de juiste paden in de pods krijgen. Vul de **Bevinding:**-regels in na het
> testen in ZAD; daarna kiezen we het cert-mount-ontwerp en schrijven het #723-ZAD-plan.

## Context

ZAD `attachments` (sinds 2026-06-29 beschikbaar, zie [[zad-attachments-available]] / repo-docs):

- Een attachment = één bestand, **max 256 kB**, met een **identifier**.
- Per component te **koppelen** als **bestand** (mount) of als **env-var**.
- **Meerdere attachments per component is mogelijk** (bevestigd door beheer, 2026-06-29).

FSC-certs zijn klein (~2–4 kB elk), dus 256 kB is ruim per cert.

## Inbound TLS-exposure: "Publicatie op het web" (apart mechanisme)

ZAD-deployments hebben een kop **"Publicatie op het web"** met 3 TLS-modi voor inkomend :443:

| Modus | Wat | FSC? |
|-------|-----|------|
| 1. Standaard certificaat (platform regelt het) | Platform termineert TLS aan de edge | **NEE** — edge-terminatie breekt de certificate-binding (#720, CLAUDE.md) |
| 2. Eigen certificaat op de pod (passthrough) | Route forwardt raw TLS; de pod presenteert de cert | **JA** — de bewezen passthrough-Route (#720/#723) |
| 3. Eigen certificaat op de Ingress (aangeleverd) | Ingress termineert met een geüpload cert | **NEE** — ingress-terminatie breekt de cert-binding |

**Besluit: modus 2 (passthrough).** Modi 1 en 3 termineren TLS aan de rand → de outway/manager
ziet geen client-cert meer → certificate-bound tokens (RFC 8705, `cnf.x5t#S256`) breken. Verboden
per #720.

**De passthrough-cert moet één PEM zijn met cert + key.** `pki/issue.sh` levert gescheiden
`cert.pem` (leaf + intermediate-chain) en `key.pem`; voor deze upload samenvoegen:
`cat pki/out/<peer>/<endpoint>/cert.pem pki/out/<peer>/<endpoint>/key.pem > combined.pem`.

> Twee mechanismen, niet verwarren: **attachments** = de cert-files op de `TLS_*`-paden ín de pod
> (tabel hieronder); **"Publicatie op het web" modus 2** = de inbound :443-cert+key-PEM voor de
> passthrough-Route.

### Extra vragen (modus 2)

- **Pod-cert vs Route-laag.** Wordt de geüploade cert+key-PEM de cert die de pod presenteert op
  :443, of zit die op de Route-laag? Moet FSC's `TLS_GROUP_CERT`/`KEY` (op
  `LISTEN_ADDRESS_EXTERNAL` :8443) naar hetzelfde materiaal wijzen, of regelt modus 2 het
  externe TLS volledig?
  **Bevinding:** _(in te vullen)_
- **SNI-routing.** Doet de passthrough SNI-routing per hostname? Per manager/inway is een eigen,
  stabiele SNI-hostname nodig op een gedeeld router-IP (zie `manager-443-sni.md`).
  **Bevinding:** _(in te vullen)_
- **Eigen hostname.** Krijgt elke deployment een eigen, stabiele hostname via "Publicatie op het
  web"? Is dat de SNI-hostname die in `SELF_ADDRESS` / `DIRECTORY_MANAGER_ADDRESS` moet?
  **Bevinding:** _(in te vullen)_

## Wat de directory-manager nodig heeft

Cert-files + `TLS_*`-paden uit `peers/directory/manager.env.example` (6 losse files):

| Bestand (pod-pad) | `TLS_*`-env-var(s) |
|-------------------|--------------------|
| `/etc/fsc/ca/root.pem` | `TLS_GROUP_ROOT_CERT` |
| `/etc/fsc/out/directory/directory/cert.pem` | `TLS_GROUP_CERT`, `TLS_GROUP_TOKEN_CERT`, `TLS_GROUP_CONTRACT_CERT` |
| `/etc/fsc/out/directory/directory/key.pem` | `TLS_GROUP_KEY`, `TLS_GROUP_TOKEN_KEY`, `TLS_GROUP_CONTRACT_KEY` |
| `/etc/fsc/internal/directory/ca/root.pem` | `TLS_ROOT_CERT`, `TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT` |
| `/etc/fsc/internal/directory/directory/cert.pem` | `TLS_CERT`, `TLS_INTERNAL_UNAUTHENTICATED_CERT` |
| `/etc/fsc/internal/directory/directory/key.pem` | `TLS_KEY`, `TLS_INTERNAL_UNAUTHENTICATED_KEY` |

`directory-ui` heeft een subset nodig (group-root + een lezer-cert/key); zelfde mechaniek.

## Te beantwoorden (test met één dummy-bestand, bv. `root.pem`)

1. **Koppelen als bestand → op welk pad landt het in de pod?** Is het pad/de filenaam zelf
   te kiezen (kunnen we `/etc/fsc/out/directory/directory/cert.pem` afdwingen), of vast/afgeleid
   van de identifier?
   **Bevinding:** _(in te vullen)_

2. **Meerdere attachments op één component.** → **JA, mogelijk** (beheer, 2026-06-29). Is er een
   praktisch maximum (we hebben er ~6 op de manager)?
   **Bevinding:** _(aantal-limiet in te vullen)_

3. **Koppelen als env-var → wat is de waarde?** De _inhoud_ (PEM-tekst) of een pad/identifier?
   Welke encoding (raw of base64)? (Bepaalt of env-koppeling überhaupt bruikbaar is voor certs —
   FSC `TLS_*` verwacht een **pad**, geen inhoud.)
   **Bevinding:** _(in te vullen)_

4. **Read-only + inhoud onaangetast?** Wordt de PEM exact bewaard (geen newline-mangling, geen
   BOM)? Mount read-only?
   **Bevinding:** _(in te vullen)_

## Ontwerp-keuze (afhankelijk van vraag 1 + 3)

- **A — pad kiesbaar bij bestand-koppeling (voorkeur).** Mount elke cert direct op zijn
  `TLS_*`-pad; de env-vars (uit `manager.env.example`) wijzen er al naar. Geen extra logica.
  Per component: 6 attachments (manager), subset (directory-ui).
- **B — pad NIET kiesbaar / afgeleid van identifier.** Mount op de ZAD-paden en zet de `TLS_*`-env
  op díe paden (env-template aanpassen). Werkt zolang de paden stabiel zijn.
- **C — fallback: gebundeld.** Eén attachment met alle certs (256 kB ruim); de `manager-migrate`-
  wrapper splitst ze bij start naar de losse paden (entrypoint doet al `migrate`). Alleen nodig
  als bestand-koppeling te beperkt blijkt. Env-koppeling (vraag 3) zou hier de bundel kunnen leveren.

## Aangrenzende ZAD-prereqs (#723-deploy, geen spike — vastgelegd)

- **Secrets/vars bestaan:** GitHub Actions secret `ZAD_API_KEY_DIRECTORY` + var
  `ZAD_PROJECT_ID_DIRECTORY` (bevestigd, 2026-06-29) — `deploy.yml` gebruikt deze al.
- **Image:** `manager-migrate` → ghcr via `.github/workflows/build-manager-migrate.yml` (#729).
- **DB-bootstrap:** `fsc_directory` aanmaken op directory-postgres (`POSTGRES_DB=fsc_directory`
  of init-stap); de wrapper draait alleen `migrate up`.

## Conclusie

TODO: gekozen ontwerp A/B/C na de spike + eventuele aanpassing aan de env-template/paden.
