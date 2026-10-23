# Contract-bootstrap (#727)

Idempotent mechanisme dat na deploy een geldig, **wederzijds ondertekend**
`ServiceConnectionGrant`-contract opzet tussen een consumer en een provider — bewezen tussen
`example-consumer` (OIN `…0020`) en `example-provider` (OIN `…0030`). Geïmplementeerd in
[`bootstrap.sh`](bootstrap.sh); ontwerp in
[`docs/superpowers/specs/2026-07-01-contract-bootstrap-design.md`](../docs/superpowers/specs/2026-07-01-contract-bootstrap-design.md).

## Stappen (FSC Manager Internal-API, OpenFSC)

1. **Thumbprint** — bereken de SPKI-SHA-256-thumbprint (hex) van de outway-group-publieke sleutel.
   De outway identificeert zich hiermee naar de provider-inway; stabiel bij cert-rotatie.
2. **Indienen** — de consumer stelt een `GRANT_TYPE_SERVICE_CONNECTION`-grant op en dient 'm in via
   de **eigen** manager (`POST /v1/contracts`, `contract_content`). De manager tekent server-side
   namens de consumer en synct het contract via de mesh naar de provider.
3. **Accepteren** — de provider tekent (`PUT /v1/contracts/{content_hash}/accept` op de
   provider-manager). Dit is **expliciet**: `AUTO_SIGN_GRANTS` dekt alleen (delegated)service­publication,
   niet serviceConnection.
4. **Verifiëren** — wacht tot de **consumer**-manager het contract als `valid` ziet (beide
   accept-signatures in díe database). Strandt de push van de provider-handtekening, dan forceert
   de bootstrap een her-distributie.

> **Best-effort token** — `bootstrap.sh` probeert daarna een `POST /token`
> (client_credentials, `scope=<hash>`) als bonus-signaal, maar faalt daar niet op: de outway haalt
> tokens **native** op tijdens egress en de **harde token-afdwinging + transactie-logging** worden in
> **#728** bewezen. #727 levert de preconditie: een geldig contract.

## Draaien

```bash
# vanuit de repo-root, ná `docker compose up` + provider-publicatie:
./deploy/local/publish-service.sh        # dienst moet bestaan om op te contracteren
./contracts/bootstrap.sh                 # zet het contract op (idempotent, her-draaibaar)
./deploy/local/smoke-contract.sh         # bewijst: wederzijds ondertekend contract  (SMOKE-CONTRACT GROEN)
```

**Idempotent zonder state-bestand**: `bootstrap.sh` leidt het bestaan van een contract af uit de
contractenlijst van de **consumer**-manager, niet uit een lokaal bestand — een deploy start met een
lege schijf, dus een onthouden hash zou daar elke run weg zijn. De matcher staat in
[`contracten.sh`](contracten.sh) en wordt ook door `smoke-contract.sh` gebruikt:

- **Identiteit = service + provider + consumer-outway + thumbprint**, in een contract met precies
  één `GRANT_TYPE_SERVICE_CONNECTION`-grant voor een gewone dienst. Verlopen en zelf ingetrokken
  contracten tellen niet mee. Alleen op servicenaam matchen volstaat niet: het
  servicePublication-contract voor dezelfde dienst staat op dezelfde managers.
- **Toestand uit `state`**, niet uit `has_rejected`/`has_revoked`: die zeggen alleen of de manager
  zélf getekend heeft, dus een afwijzing of intrekking door de andere peer zie je daar niet aan.
  'Geldig' eist bovendien beide accept-handtekeningen.
- **Geldig** (op de consumer) → no-op. Liggen er meerdere, dan blijft het oudste staan
  (`created_at`; het meest waarschijnlijk al via zijn grant-hash in gebruik) en worden de overige
  geldige én lopende ingetrokken. Twee gelijktijdige runs kunnen elk indienen; zonder gedeeld lock
  is dat niet te voorkomen, wel bij de volgende run te herstellen.
- **Ingediend maar nog niet geldig** → de bootstrap maakt dát contract af in plaats van een tweede
  in te dienen: de consumer-accept als de provider het voorstelde, her-distributie naar de provider
  als het daar nooit aankwam, de accept, of alleen de her-distributie terug als de provider al
  tekende. Is het op de provider inmiddels afgewezen of ingetrokken, dan stopt de bootstrap.
- **Afgewezen, of door de andere peer ingetrokken** → de bootstrap stopt: dat is een besluit van
  een van beide peers, en een nieuw contract zou de bootstrap zelf als provider tekenen. Na het
  oplossen van de oorzaak dient `OPNIEUW_INDIENEN=1` een nieuw contract in.
- **Onbekende of ontbrekende `state`** → de bootstrap stopt in plaats van te gokken.

Intrekken slaat OpenFSC eerst lokaal op en pusht daarna naar de provider; faalt die push, dan
probeert de bootstrap meteen de her-distributie, omdat een volgende run het contract niet meer ziet.

De consumer-kant is de maatstaf omdat de outway daar de grant resolvet: op de provider kan een
contract al geldig zijn terwijl de provider-handtekening nooit bij de consumer aankwam.

`jq` is vereist: zonder het uitlezen van de contract-JSON is idempotentie niet vast te stellen.
Zonder draaiende managers (ook in CI): `./contracts/contracten.test.sh` toetst de matcher,
`./contracts/bootstrap.test.sh` de beslislogica hierboven tegen nagespeelde managers — waaronder
"drie runs op een lege omgeving leveren één contract op".

## Let op bij een OpenFSC-versiesprong (v1.x → v2.x)

OpenFSC v2.0.0 heeft de contract-hash gewijzigd: de content wordt nu gecanonicaliseerd met JCS
(RFC 8785) en de content bevat een `fsc_version`. Hashes van vóór v2 zijn daardoor **niet
converteerbaar**; upstream schrijft voor om bestaande contracten uit de database te verwijderen
vóór de upgrade. Ook de grant-vorm veranderde: de outway wordt geïdentificeerd via
`outway.identification` (union op `type`), niet meer via een platte `outway.public_key_thumbprint`.

Bij een versiesprong dus de contract-DB's wissen:

```bash
docker compose -f deploy/local/docker-compose.yaml down -v   # wist ook de contract-DB's
```

Daarna de normale volgorde uit **Draaien** hierboven.

**Generiek**: alle peers/paden zijn via env te overrulen (`CONSUMER_OIN`, `PROVIDER_OIN`,
`SERVICE_NAME`, `*_MANAGER`, `*_CERT/KEY/CA`, `OUTWAY_CERT_HOST`; voor diagnose en de token-probe
`LOG_SERVICES`, `OUTWAY_CERT/KEY`, `GROUP_CA`, `PROVIDER_TOKEN_URL`). Defaults = de example-peers.
`smoke-contract.sh` leest dezelfde namen. De FBS-toepassing (magazijn ↔ uitvraag) kan
[`contracten.sh`](contracten.sh) sourcen voor de matcher; de regels hebben de vorm
`<hash> <state> <provider-getekend> <consumer-getekend> <grant-hash>`, en `grant_hash_van` levert de
waarde voor `Fsc-Grant-Hash`.
