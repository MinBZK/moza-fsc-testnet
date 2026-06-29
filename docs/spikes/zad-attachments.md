# Spike: ZAD attachments → FSC-cert-mount

> Status: **beantwoord (2026-06-29)** — ontwerp **A** gekozen (zie Conclusie). De FSC-certs
> gaan als **bestand-bijlagen** op zelfgekozen `/etc/fsc/...`-paden; inbound :443 via
> "Publicatie op het web" modus 2 (passthrough). #723/#722.

## Context

ZAD `attachments` / **bijlagen** (sinds 2026-06-29 beschikbaar, zie [[zad-attachments-available]]):

- Een attachment = één bestand, **max 256 kB**, met een **identifier**.
- Een deployment heeft een checkbox **"bijlagen"**; aangevinkt koppel je ze als **bestand**
  (op een **zelfgekozen pad**) of als **env-var** (met een zelfgekozen naam).
- **Meerdere bijlagen per component**: geen maximum.

FSC-certs zijn klein (~2–4 kB elk), dus 256 kB is ruim per cert.

## Inbound TLS-exposure: "Publicatie op het web" (apart mechanisme)

ZAD-deployments hebben een kop **"Publicatie op het web"** met 3 TLS-modi voor inkomend :443:

| Modus | Wat | FSC? |
|-------|-----|------|
| 1. Standaard certificaat (platform regelt het) | Platform termineert TLS aan de edge | **NEE** — edge-terminatie breekt de certificate-binding (#720, CLAUDE.md) |
| 2. Eigen certificaat op de pod (passthrough) | Ingress is volledig passthrough; de **pod** draait de HTTPS-server + presenteert de cert | **JA** — de bewezen passthrough-Route (#720/#723) |
| 3. Eigen certificaat op de Ingress (aangeleverd) | Ingress termineert met een geüpload cert | **NEE** — ingress-terminatie breekt de cert-binding |

**Besluit: modus 2 (passthrough).** De ingress termineert de TLS **niet** (bevestigd) en
SNI-routet per hostnaam; de pod presenteert zelf de via-bijlage-gemounte group-cert. Modi 1 en 3
termineren aan de rand → certificate-bound tokens (RFC 8705, `cnf.x5t#S256`) breken. Verboden per #720.

> **Geen aparte cert-upload nodig.** De group-cert komt via een bestand-bijlage
> (`TLS_GROUP_CERT`/`KEY` als losse files); de pod serveert die. Een gecombineerde cert+key-PEM
> is voor modus 2 dus **niet** vereist (`combine-pem.sh` blijft als optie, maar is niet nodig).

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

Elk als bestand-bijlage op exact dat pad. `directory-ui` heeft een subset nodig (group-root +
een lezer-cert/key); zelfde mechaniek. `pki/zad-bundle.sh <peer>` levert deze set + een manifest.

## Vragen aan ZAD-beheer — beantwoord (2026-06-29)

Nummering = de naar ZAD gestuurde lijst (**1–4** bijlagen, **5–8** "Publicatie op het web"):

1. Bestand-bijlage → pad zelf bepaalbaar?
   **Bevinding:** **JA, volledig vrij** — in de UI: "bijlage met identifier X op pad Y". We
   mounten elke cert direct op zijn `/etc/fsc/...`-pad.
2. Hoeveel bijlagen per component?
   **Bevinding:** **Geen maximum.** De ~6 certs per component passen.
3. Env-var-koppeling → inhoud of pad? Encoding?
   **Bevinding:** Env-var-optie = **alleen tekstbestanden**, bevat de *inhoud*. **Niet voor certs
   gebruiken** — het mount-pad is logischer. Certs dus als **bestand**-bijlage.
4. Read-only + byte-intact?
   **Bevinding:** **Ja, read-only en volledig binary-safe** — PEM blijft intact.
5. Modus 2 → cert in de pod of op de route-laag?
   **Bevinding:** **Je mount de bijlage zelf op een eigen pad; de app draait de HTTPS-server +
   presenteert het cert. De ingress is volledig passthrough.** Dus geen aparte cert-upload: de
   group-cert komt via de bijlage; `TLS_GROUP_CERT`/`KEY` wijzen naar de gemounte files.
6. SNI-routing per hostnaam?
   **Bevinding:** **Ja.**
7. Eigen, stabiele externe hostnaam per deployment?
   **Bevinding:** **Ja** — afhankelijk van het 'domein-formaat'. Je kunt combinaties maken van
   `component-deployment-projectid` waarbij **component + deployment zelf kiesbaar en voorspelbaar**
   zijn. Dat wordt de SNI-hostnaam voor `SELF_ADDRESS` / `DIRECTORY_MANAGER_ADDRESS`.
8. Ingress termineert TLS niet (passthrough)?
   **Bevinding:** **Bevestigd** — volledig passthrough.

## Ontwerp-keuze → **A gekozen**

- **A — direct mount (GEKOZEN).** Elke cert als bestand-bijlage op zijn exacte `/etc/fsc/...`-pad;
  de `TLS_*`-env-vars uit `manager.env.example` wijzen er al naar — **geen wijziging nodig**.
  Per component: 6 bijlagen (manager), subset (directory-ui). Mogelijk dankzij vrij-kiesbare paden
  (vraag 1) + geen maximum (vraag 2).
- ~~B — pad afgeleid van identifier~~ — n.v.t., paden zijn vrij.
- ~~C — gebundeld + wrapper-split~~ — niet nodig.

## Conclusie

**Cert-mount-ontwerp = A (direct mount via bestand-bijlagen).**

- Elke cert als **bestand-bijlage** op zijn `/etc/fsc/...`-pod-pad (vrij, geen max, read-only,
  binary-safe). `TLS_*`-env-vars ongewijzigd t.o.v. `peers/directory/manager.env.example`.
  Genereer de upload-set met `pki/zad-bundle.sh directory` (zie `MANIFEST.md`).
- Inbound :443 via "Publicatie op het web" **modus 2 (passthrough)**: pod draait de HTTPS-server,
  ingress SNI-routet en termineert niet. **Geen `combined.pem` / geen aparte cert-upload.**
- **Hostnaam** = voorspelbaar `<component>-<deployment>-<projectid>...`; zet die in
  `SELF_ADDRESS` / `DIRECTORY_MANAGER_ADDRESS`. De cert-**SAN hoeft de hostnaam NIET te bevatten**
  (mesh valideert op OIN; SNI-routing gebruikt de ClientHello-SNI) → placeholder-hostnames in de
  certs zijn prima, geen her-uitgifte nodig.

Hiermee is de cert-mount voor #723-op-ZAD volledig gespecificeerd. Resterende #723-prereqs (image
via `build-manager-migrate.yml`, DB via `peers/directory/postgres.env.example`, env in Operations
Manager) staan onder "Aangrenzende ZAD-prereqs".

## Aangrenzende ZAD-prereqs (#723-deploy)

- **Secrets/vars bestaan:** GitHub Actions secret `ZAD_API_KEY_DIRECTORY` + var
  `ZAD_PROJECT_ID_DIRECTORY` (bevestigd, 2026-06-29) — `deploy.yml` gebruikt deze al.
- **Image:** `manager-migrate` → ghcr via `.github/workflows/build-manager-migrate.yml` (#729).
- **DB-bootstrap:** `POSTGRES_DB=fsc_directory` op directory-postgres
  (`peers/directory/postgres.env.example`); de wrapper draait alleen `migrate up`.
