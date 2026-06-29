# Spec A — moza-fsc-testnet generiek maken + provider-onboarding bewijzen

> Status: ontwerp (#724). Branch: `feature/peer-magazijn-724`.
> Gerelateerd: [Spec B](2026-06-29-fbs-peers-onboarding-design.md) (FBS-peers in
> `moza-poc-fbs-berichtenbox`), epic [#737](https://github.com/MinBZK/MijnOverheidZakelijk/issues/737).

## Aanleiding

Dit repo (`moza-fsc-testnet`) is bedoeld als **generieke FSC-testomgeving**: het draait
OpenFSC voor MOZa, en elk team sluit aan als eigen peer. In de praktijk is het tijdens
#722/#723 vermengd geraakt met de FBS-PoC: echte FBS-OINs (magazijn-a/-b, uitvraag-org),
`berichtenmagazijn`-upstream en FBS-peer-config staan nu hardcoded in dit repo. Dat hoort
hier niet: FBS-peers worden door het FBS-team opgezet, co-located met hun app, in
`moza-poc-fbs-berichtenbox` (Spec B).

Deze spec maakt het repo **FBS-agnostisch** en bewijst de **generieke provider-onboarding**
end-to-end met één neutraal voorbeeld.

## Gewenst resultaat

1. Dit repo bevat geen FBS-specifieke peers/OINs/upstreams meer.
2. Eén neutrale `example-provider`-peer (synthetische OIN) bewijst de provider-onboarding
   lokaal: cert → announce → dienst publiceren → vindbaar in directory.
3. De centrale kern is uitgebreid met self-service cert-uitgifte (CA + cert-portal),
   zodat externe peers (zoals FBS in Spec B) zelf certs kunnen aanvragen.
4. Documentatie beschrijft de infrastructuur generiek; FBS verschijnt hooguit als
   "voorbeeld-consument van deze infra", niet als ingebakken config.

## Niet in scope

- Generieke **consumer**-onboarding (outway, `example-consumer`) → #725, aparte branch.
- De échte data-call dóór de inway naar de app → #728.
- De FBS-peers zelf → Spec B (repo B).
- De reusable cross-repo deploy-workflow → #729.
- Groen draaien op ZAD → geblokkeerd door ZAD `attachments` (cert-mount); deze spec
  levert de ZAD-artefacten als source-of-truth, niet een groene ZAD-run.

## Architectuur

Gespiegeld op OpenFSC's eigen layout (`helm/deploy/shared/` + `helm/deploy/<org>/`).

### Centrale kern (shared) — FBS-agnostisch

| Component | Rol | Bron (OpenFSC) |
|-----------|-----|----------------|
| directory-manager | group-anker; manager in directory-mode (`DIRECTORY_PEER_ID` = eigen OIN, lege txlog, `AUTO_SIGN_GRANTS=servicePublication,...`) | `open-fsc-manager` |
| ca-cfssl | draaiende test-CA (CFSSL, :8888) die certs signt tegen onze test-trust-anchor | `open-fsc-ca-cfssl-unsafe` |
| ca-certportal | web/HTTP-portal waarmee een peer een group-cert aanvraagt; client van ca-cfssl (`--ca-host`) | `open-fsc-ca-certportal` |
| directory-ui | dienstencatalogus-UI | `open-fsc-directory-ui` |
| postgres | system-of-record directory (persistent) | — |

**Cert-portal & onze PKI.** Onze `pki/`-scripts gebruiken al cfssl. De `ca-cfssl`-component
draait dezelfde CA-config (root + intermediate uit `pki/`) als HTTP-service; `ca-certportal`
is er een client van. Self-service onboarding = een peer vraagt via de portal een group-cert
aan; dat blijft de gecontroleerde gatekeeper-stap (wie een cert krijgt, zit in de federatie).

### Neutrale voorbeeld-provider — bewijs + kopieer-template

`example-provider` (synthetische OIN `00000000000000000030`, organisatie-naam
`example-provider`):

| Component | Rol |
|-----------|-----|
| manager | peer-manager (provider-mode): announce bij directory, ontvangt ServicePublicationGrant |
| controller | dienst-administratie (Registration-API + Administration-API + UI); `AUTHN_TYPE=none` lokaal |
| inway | ingress; registreert bij controller, haalt dienst-config on-demand |
| stub-upstream | kleine echo/hello-container die `berichtenmagazijn` vervangt; geeft de inway een gezonde upstream |
| postgres | peer-DB |

### Onboarding-flow (wat de smoke-test bewijst)

Gegrond op OpenFSC-bron (controller-gedreven dienst-config):

1. **Cert** — `example-provider` verkrijgt een group-cert (lokaal: vooraf gegenereerd via
   `pki/issue.sh`; het cert-portal-pad wordt apart aangetoond, zie "Cert-portal-bewijs").
2. **Announce** — manager-`example-provider` meldt zich bij de directory bij start
   (verschijnt in `peers.peers` met `manager_address` op `:443`).
3. **Dienst aanmaken** — via de controller Administration-API: `CreateService`
   (`name=example-service`, `endpointUrl=<stub-upstream>`, `inwayAddress=<inway>`).
4. **Publiceren** — provider-manager maakt een ServicePublicationGrant-contract richting de
   directory; directory auto-signt (`AUTO_SIGN_GRANTS` staat al aan).
5. **Vindbaar** — de dienst verschijnt in de directory (DB + directory-ui).

De smoke-test assert stap 2 (announce) **en** stap 5 (dienst vindbaar). De échte HTTP-call
dóór de inway is #728.

## Data flow (onboarding, niet data-pad)

```
example-provider                          centrale kern
  controller ──CreateService(admin-API)──► (eigen DB)
  manager ───announce──────────────────► directory-manager (peers.peers)
  manager ───ServicePublicationGrant────► directory-manager ──auto-sign──► directory (services)
  inway ────GetService(registration-API)─► controller            directory-ui ◄── leest catalogus
```

## Wijzigingen in dit repo

### Verwijderen (FBS-specifiek)

- `peers/magazijn-a/`, `peers/magazijn-b/`, `peers/uitvraag-org/`
- `pki/peers/magazijn-a/`, `pki/peers/magazijn-b/`, `pki/peers/uitvraag-org/`

(De inhoud — echte OINs, CSR-templates, berichtenmagazijn-upstream — wordt heropgezet in
Spec B / repo B. Niet letterlijk kopiëren: in repo B opnieuw aanmaken volgens de generieke
template.)

### Toevoegen / neutraliseren

- **`peers/example-provider/`** — nieuwe neutrale provider-template (`values.example.yaml`,
  `manager.env.example`, `inway.env.example`) met echte OpenFSC-env-namen, OIN `...030`.
- **`pki/peers/example-provider/{manager,inway}/csr.json`** — CSR's met `serialnumber=...030`.
  OIN in lockstep met `peers/example-provider/values.example.yaml`.
- **Centrale kern uitbreiden:** componentlijst + env-templates voor `ca-cfssl` + `ca-certportal`
  (+ paden/poorten), naast de bestaande directory.
- **Harness (`deploy/local/`)** — herbedraden van `magazijn-a` → `example-provider`:
  - `docker-compose.yaml`: services `migrate-magazijn-a`/`manager-magazijn-a` → `*-example-provider`;
    cert-paden, DB-namen (`fsc_example_provider`, `fsc_controller_example_provider`), router-alias
    `example-provider.fsc-test.local`, controller `MANAGER_ADDRESS_INTERNAL`,
    `directory-ui` lezer-cert. **Toevoegen:** `ca-cfssl` + `ca-certportal` + stub-upstream services.
  - `haproxy.cfg`: backend `maga`/SNI → `example-provider`.
  - `postgres-init.sql`: DB-namen neutraliseren.
  - `smoke-announce.sh`: `MAGA_OIN` → `...030`; uitbreiden met dienst-publicatie-assert
    (poll directory tot `example-service` in de catalogus staat).
  - `README.md`: voorbeelden herschrijven.
- **Docs herschrijven naar generiek** (`docs/topologie.md`, `docs/zad-projecten.md`,
  `docs/ontwerpkeuzes.md`, `README.md`, `CLAUDE.md`, `pki/README.md`): peer-namen/OINs →
  `example-provider` + synthetische OIN; FBS hooguit als voorbeeld-consument genoemd.
- **ZAD-deploy** (`.github/workflows/deploy.yml`): centrale-kern-job uitbreiden met
  `ca-cfssl` + `ca-certportal` (gepinde images). Geen peer-job (peers deployen bij de app).
- **Oude superpowers-plans/specs** (`docs/superpowers/{plans,specs}/2026-06-2[45]-*`):
  laten staan als historische context; deze spec is de nieuwe bron. Niet herschrijven
  (ze documenteren wat #722/#723 destijds deden).

### Cert-portal-bewijs

Aparte, kleine verificatie (script of gedocumenteerde stappen): start `ca-cfssl` +
`ca-certportal`, vraag via de portal een cert aan voor een test-OIN, en toon dat het
geldige cert tegen de test-trust-anchor verifieert (`pki/verify.sh`-stijl). Bewijst de
self-service-onboarding zonder de hele tweede peer te hoeven draaien.

## Error handling

- **Harness**: bestaande conventies aanhouden — `restart: on-failure` voor boot-races,
  health-gated `depends_on`, `migrate-*` als aparte run-to-completion. Smoke-test poll't
  met timeout en surfacet psql-stderr op FAIL-paden (zoals `smoke-announce.sh` nu).
- **Dienst-publicatie**: smoke faalt expliciet als de dienst niet binnen de timeout in de
  directory-catalogus verschijnt; positief-controle (staat de directory-self-row er?) om
  query/schema-fouten te onderscheiden van een echte publicatie-fout.
- **Cert-portal**: faal hard als de portal geen geldig cert teruggeeft; verifieer chain
  tegen de trust-anchor vóór "OK".

## Testen / acceptatie

- `pki/`-flow genereert `example-provider`-certs; `pki/verify.sh` slaagt.
- `docker compose up` brengt centrale kern + `example-provider` op; geen FBS-namen meer.
- `smoke-announce.sh` (uitgebreid): **announce** + **dienst vindbaar** beide groen.
- Cert-portal-bewijs: aangevraagd cert verifieert tegen trust-anchor.
- `grep -ri 'magazijn\|berichtenmagazijn\|berichtenuitvraag\|00000001003214345000\|00000001823288444000'`
  over het repo geeft geen treffers meer in config/harness (docs mogen FBS als voorbeeld
  noemen, maar niet als ingebakken peer).
- Lint groen (markdownlint + yamllint + actionlint).

## #737-herziening (labels)

Elk sub-issue krijgt een `repo: A` / `repo: B`-markering (sectie in de body; geen nieuwe
epic). #724/#725 worden generiek (A); hun FBS-deel als checklist-item richting B. De
concrete issue-body-edits worden apart gedraft en vóór toepassen voorgelegd (issues
aanpassen vereist akkoord).

## Open punten / blockers

- **ZAD `attachments`** (cert-mount) nog niet beschikbaar → centrale kern + peers draaien
  nog niet groen op ZAD. Deze spec levert artefacten als source-of-truth.
- **ca-cfssl op ZAD**: of de CFSSL-CA centraal op ZAD draait of alleen lokaal/offline blijft,
  is een vervolgkeuze (raakt #729). Lokaal bewijzen we de portal; ZAD-deploy van de CA is
  TODO(#729).
- **Synthetische OIN `...030`**: bevestigen dat dit nergens botst met een echte OIN.
