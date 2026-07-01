# Spec — end-to-end afname + verantwoording (#728)

> Status: ontwerp (#728). Branch: `feature/e2e-afname-728` (op `feature/contract-bootstrap-727`).
> Voorlopers: #724 (provider-publicatie), #725 (consumer-discovery), #727 (contract-bootstrap).
> Volgorde/status: sub-issues van epic
> [#737](https://github.com/MinBZK/MijnOverheidZakelijk/issues/737).

## Aanleiding

In #727 legden we het contract. Nu moet blijken dat een **echte aanroep** end-to-end via FSC werkt én
**achteraf verantwoord** kan worden. Dit issue bewijst de keten
`consumer → outway → inway → stub-upstream → terug` met (a) **token-afdwinging**
(`Fsc-Authorization`, certificate-bound) en (b) **correleerbare transactie-logging**
(`Fsc-Transaction-Id`) — tussen `example-consumer` en `example-provider`. FBS-e2e = [FBS]-zusterissue.

## Acceptatiecriteria (#728)

- [x] Aanroep loopt `example-consumer → outway → inway → stub-upstream → terug`.
- [x] Toegang afgedwongen via geldig certificate-bound token (`Fsc-Authorization`); geen geldig
      token = geweigerd (inway 401 `ERROR_CODE_ACCESS_TOKEN_MISSING`).
- [x] End-to-end correleerbaar via `Fsc-Transaction-Id` in de logging (zelfde id bij outway
      `direction: out` én inway `direction: in`).
- [ ] Optioneel: fsc-test-suite (Logius) als conformance-poort — **niet** meegenomen (buiten scope).

## Wat OpenFSC hier doet (gegrond op de helm-charts)

- **Outway-routing gaat via de `Fsc-Grant-Hash`-header**, niet via een `/<peer>/<service>/`-pad
  (dat is NLX-legacy). De app zet de header; de outway resolvet grant-hash → service → inway-adres
  **native** via de eigen manager (auto-discovery; geen statische services-lijst). Met een
  geldig contract haalt de outway zélf het certificate-bound token op (`POST /token`,
  `scope=<grantHash>`) en zet `Fsc-Authorization: Bearer <jwt>` op de call naar de inway.
  De app ziet geen token.
- **`Fsc-Transaction-Id` genereert de outway**; hij logt de transactie (`direction: out`) in zijn
  **eigen txlog-api** en propageert de id naar de inway, die 'm (`direction: in`) in de
  **provider-txlog** logt. Zo is de keten correleerbaar op één id.
- **txlog-api** = eigen component per peer, eigen DB (`open_fsc_tx_log`-analoog), `migrate up` +
  serve. Spreekt **mTLS op de INTERNAL PKI** (niet de group): inway/outway/manager presenteren hun
  internal-cert, txlog trust de per-peer internal-CA. Group-agnostisch (geen `GROUP_ID`).

## Wijzigingen in dit repo

### PKI

- `pki/peers/{example-provider,example-consumer}/txlog/csr.json` — internal-cert voor de txlog-api
  (CN `txlog.<peer>.fsc-test.local`). `pki/issue.sh`/`verify.sh` pikken ze automatisch op.

### `deploy/local`-harness

- **`docker-compose.yaml`**:
  - Nieuw: `migrate-txlog-*` + `txlog-example-{provider,consumer}` (image `txlog-api`, eigen DB,
    internal-cert-mTLS, alias `txlog.<peer>.fsc-test.local:9443`). Gedeelde env-anchor
    `x-txlog-common-env`.
  - `TX_LOG_API_ADDRESS` op manager+inway (provider) en manager+outway (consumer) van de
    placeholder naar de **echte** txlog gezet.
  - **Outway-egress-config** (uit de open-fsc-outway-chart): `MANAGER_INTERNAL_ADDRESS` (:9443,
    authenticated), `CONTROLLER_REGISTRATION_API_ADDRESS`, `GRANT_LINKS_CACHE_TTL=30s`,
    `ENABLE_GRANT_HASH_SUGGESTION=true`, en app-ingress als **plain HTTP `:8080`**
    (`https.enabled=false`). De `MANAGER_INTERNAL_UNAUTHENTICATED_ADDRESS` (#725, boot-only)
    vervalt — de chart gebruikt de authenticated variant.
- **`haproxy.cfg` + router-alias**: nieuwe `:443`-SNI-passthrough-route
  `inway.example-provider.fsc-test.local → inway-example-provider:8443`. De inway kan als non-root
  geen `:443` binden; de outway dialt zijn geregistreerde `SELF_ADDRESS` (`…:443`). De inway-alias
  verhuist naar de **router** (anders round-robint docker-DNS tussen router en inway → halve calls
  op een dode `:443`).
- **`postgres-init.sql`**: + `fsc_txlog_example_{provider,consumer}`.
- **`smoke-e2e.sh`** (nieuw): bewijst (1) data-call 200 + stub-echo, (2) directe inway-call zónder
  token = 401 **én** `ERROR_CODE_ACCESS_TOKEN_MISSING` (AND, niet OR — een kale 401 mag geen
  afdwinging voorwenden), (3) de transactie van díe call correleert: de **nieuwe** out-id in de
  consumer-txlog (t.o.v. een baseline vóór de call) staat óók als **in**-id in de provider-txlog.
  Baseline-diff + `direction`-predicaat voorkomen een false-green op een gedeelde id uit een
  eerdere run of uit de token-/mesh-uitwisseling. Ontdekt de grant-hash via de outway-suggestie
  (pollt tot de outway het #727-contract kent; grept body én headers).
- **`run-smokes.sh`**: `smoke-e2e.sh` toegevoegd aan de keten.

## Error handling

Bestaande conventies: poll-met-timeout, `ERRLOG` op FAIL-paden, `restart: on-failure` voor
boot-races, health-gated `depends_on`, schema-agnostische txlog-tabelresolutie (zoals
`smoke-discover.sh` voor de services-tabel).

## Testen / acceptatie

Geen docker in de agent-omgeving → **bewijs draait host-side** (net als #724–#727):

```bash
./deploy/local/run-smokes.sh    # ...→ smoke-e2e.sh, verwacht: SMOKE-E2E GROEN + ALLE SMOKES GROEN
```

## Open punten / eerste-run-checks (untestbaar in de agent-omgeving)

Deze zijn gegrond op de helm-charts + OpenFSC-docs, maar niet live geverifieerd; controleer op de
docker-host bij de eerste run:

1. **txlog serve-subcommando**: `txlog-api serve` (gespiegeld op `manager serve`). Als het image
   een ander default-commando heeft: `docker run --rm …/txlog-api:v1.43.7 --help`.
2. **Grant-hash-suggestie-formaat**: `smoke-e2e.sh` grept `$1$<n>$<base64url>` (in body én headers).
   Wijkt het formaat af, pas de regex aan (dump de outway-respons op de FAIL-tak).
3. **txlog-tabel/-kolommen**: schema-agnostisch opgezocht op kolom `transaction_id`; de correlatie
   gebruikt ook een `direction`-kolom (predicaat `LIKE '%out%'`/`'%in%'`, tolerant voor de encoding).
   Gebruikt fsc-logging andere kolomnamen, dan faalt de query luid (FAIL-dump toont het schema) —
   nooit stil groen.
4. **Outway-egress-env**: `MANAGER_INTERNAL_ADDRESS` (authenticated :9443) vervangt de #725-
   unauthenticated variant; bevestig dat de outway registreert + routeert (outway-logs).
5. **Inway-401-body**: `ERROR_CODE_ACCESS_TOKEN_MISSING` komt uit de FSC-standaard-errortabel; de
   exacte header/body van v1.43.7 kan iets afwijken (de smoke matcht op HTTP 401 óf de errorcode).
</content>
