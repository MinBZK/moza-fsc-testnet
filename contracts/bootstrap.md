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
4. **Verifiëren** — het contract draagt nu accept-signatures van **beide** peers.

> **Best-effort token** — `bootstrap.sh` probeert daarna een `POST /token`
> (client_credentials, `scope=<hash>`) als bonus-signaal, maar faalt daar niet op: de outway haalt
> tokens **native** op tijdens egress en de **harde token-afdwinging + transactie-logging** worden in
> **#728** bewezen. #727 levert de precondtie: een geldig contract.

## Draaien

```bash
# vanuit de repo-root, ná `docker compose up` + provider-publicatie:
./deploy/local/publish-service.sh        # dienst moet bestaan om op te contracteren
./contracts/bootstrap.sh                 # zet het contract op (idempotent, her-draaibaar)
./deploy/local/smoke-contract.sh         # bewijst: wederzijds ondertekend contract  (SMOKE-CONTRACT GROEN)
```

**Idempotent**: `bootstrap.sh` legt de `content_hash` van het geaccepteerde contract vast in
`contracts/.bootstrap-state/` (gitignored). Een 2e run no-opt als díe exacte hash nog op de
provider staat. Het succes rust op de twee 2xx-responsen (POST = consumer-sig, `PUT …/accept` =
provider-sig) en checks greppen alléén op de unieke `content_hash` — nooit op servicenaam/`"accept"`,
want het auto-geaccepteerde publicatie-contract voor dezelfde dienst zou dat altijd laten matchen.

## Let op bij een OpenFSC-versiesprong (v1.x → v2.x)

OpenFSC v2.0.0 heeft de contract-hash gewijzigd: de content wordt nu gecanonicaliseerd met JCS
(RFC 8785) en de content bevat een `fsc_version`. Hashes van vóór v2 zijn daardoor **niet
converteerbaar**; upstream schrijft voor om bestaande contracten uit de database te verwijderen
vóór de upgrade. Ook de grant-vorm veranderde: de outway wordt geïdentificeerd via
`outway.identification` (union op `type`), niet meer via een platte `outway.public_key_thumbprint`.

Gevolg voor deze bootstrap: de state-file uit `contracts/.bootstrap-state/` houdt een oude hash
vast die op een v2-manager nooit meer opduikt. Laat je 'm staan, dan valt de idempotentie-check
terug op een contract dat de nieuwe manager niet meer als geldig ziet. Bij een versiesprong dus:

```bash
docker compose -f deploy/local/docker-compose.yaml down -v   # wist ook de contract-DB's
rm -rf contracts/.bootstrap-state
```

Daarna de normale volgorde uit **Draaien** hierboven.

**Generiek**: alle peers/paden zijn via env te overrulen (`CONSUMER_OIN`, `PROVIDER_OIN`,
`SERVICE_NAME`, `*_MANAGER`, `*_CERT/KEY/CA`, `OUTWAY_CERT_HOST`). Defaults = de example-peers. De
FBS-toepassing (magazijn ↔ uitvraag) is een [FBS]-zusterissue in repo B.
