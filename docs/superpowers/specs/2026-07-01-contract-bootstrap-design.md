# Spec — herbruikbaar contract-bootstrap-mechanisme (#727)

> Status: ontwerp (#727). Branch: `feature/contract-bootstrap-727` (op `feature/peer-uitvraag-725`).
> Voorlopers: [Spec provider](2026-06-29-fsc-generiek-provider-onboarding-design.md) (#724),
> [Spec consumer](2026-07-01-fsc-generiek-consumer-onboarding-design.md) (#725).
> Volgorde/status: sub-issues van epic
> [#737](https://github.com/MinBZK/MijnOverheidZakelijk/issues/737).

## Aanleiding

In #724 bewezen we de **provider**-kant (dienst publiceren), in #725 de **consumer**-kant
(announce + discovery). Beide peers kennen elkaar nu via de directory, maar er is nog géén
**afspraak** die de consumer toegang geeft tot de dienst. FSC legt die afspraak vast in een
cryptografisch ondertekend **contract** met een **ServiceConnectionGrant**: de consumer stelt
'm op en tekent, de provider accepteert en tekent. Pas dan mag er data stromen (#728).

Dit issue levert het **generieke, idempotente bootstrap-mechanisme** dat zo'n contract opzet —
bewezen tussen `example-consumer` (OIN `…0020`) en `example-provider` (OIN `…0030`). De
FBS-toepassing (magazijn ↔ uitvraag) is een [FBS]-zusterissue in repo B.

## Gewenst resultaat

Een her-draaibaar `contracts/bootstrap.sh` (+ smoke) dat:

1. een `ServiceConnectionGrant` opstelt (consumer → provider, voor `example-service`) en via de
   **eigen manager Internal-API** indient (`POST /v1/contracts`), waarbij de manager server-side
   tekent namens de consumer en het contract via de mesh naar de provider synct;
2. de provider het contract laat **accepteren** (`PUT /v1/contracts/{hash}/accept` op de
   provider-manager), waarmee ook de provider-handtekening gezet wordt;
3. **idempotent** is: een al bestaand, wederzijds ondertekend contract voor dezelfde
   (service, outway) = no-op;
4. het resultaat **verifieert**: het contract is wederzijds ondertekend (accept-signatures van
   zowel consumer- als provider-OIN).

## Scope-grens (belangrijk)

- **In scope (#727):** het contract opzetten + accepteren + bewijzen dat het geldig/wederzijds
  ondertekend is. Dat is de precondtie voor een token.
- **Niet in scope (#728):** de **echte data-call** (outway → inway → upstream), het live
  **token-ophalen door de outway** (`Fsc-Authorization`) en de **transactie-logging**
  (`Fsc-Transaction-Id`). De outway haalt tokens native op tijdens egress; dat mechanisme
  bewijzen we in #728, niet hier. `bootstrap.sh` doet hooguit een **best-effort** token-fetch
  als bonus-signaal (non-fataal), maar de harde succesvoorwaarde is de wederzijdse handtekening.

Deze grens is bewust: het grant-hash/scope-token-detail van de OpenFSC-`/token` is versiegevoelig
en wordt in #728 met de echte outway-egress afgedekt. #727 blijft daardoor deterministisch en
API-stabiel (leunt alleen op het bewezen `contract_content`-POST-patroon uit `publish-service.sh`).

## Achtergrond: FSC-contractstroom (OpenFSC v1.43.7)

De Manager Internal-API accepteert een **`contract_content`**-body en tekent server-side met de
group-contract-cert (bewezen in `publish-service.sh` voor de `servicePublication`-grant). Voor de
`serviceConnection`-grant geldt hetzelfde patroon, met twee verschillen:

- de grant is `GRANT_TYPE_SERVICE_CONNECTION` met een **`service`**- én **`outway`**-blok;
- de provider tekent **niet automatisch**: `AUTO_SIGN_GRANTS` op de directory/managers dekt alleen
  `servicePublication,delegatedServicePublication`. De `serviceConnection`-accept moet dus
  **expliciet** met een `PUT …/accept` op de provider-manager gebeuren.

### Grant-body

```jsonc
{
  "contract_content": {
    "iv": "<uuid v4>",
    "group_id": "moza-fbs-test",
    "hash_algorithm": "HASH_ALGORITHM_SHA3_512",
    "created_at": <epoch>,
    "validity": { "not_before": <epoch-60>, "not_after": <epoch+10j> },
    "grants": [ {
      "type": "GRANT_TYPE_SERVICE_CONNECTION",
      "service": { "peer_id": "<provider-OIN>", "name": "example-service" },
      "outway": {
        "peer_id": "<consumer-OIN>",
        "identification": {
          "type": "OUTWAY_IDENTIFICATION_TYPE_PUBLIC_KEY_THUMBPRINT",
          "public_key_thumbprint": "<sha256-hex van de outway-group-publieke-sleutel>"
        }
      }
    } ]
  }
}
```

### `public_key_thumbprint`

Per fsc-core: *"de SHA-256-thumbprint van de publieke sleutel in het Outway-certificaat,
HEX-encoded"* (64 hex-tekens). Cruciaal: het is de **publieke sleutel** (SubjectPublicKeyInfo),
niet het hele certificaat — daardoor blijft het contract geldig bij cert-rotatie. **Bevestigd
(2026-07-02): het is het INTERNAL-cert** (`pki/internal/example-consumer/outway/cert.pem`), niet
het group-cert. De consumer identificeert zijn outway intern via de internal-CA (de outway spreekt
zijn eigen manager + controller over dat cert aan), en `GetOutwayServices` matcht het grant daarop;
met het group-thumbprint bleef `grant_links` leeg. Empirisch: de manager-actor-thumbprint in de
audit-log == SPKI-SHA256-hex van het manager-internal-cert. Berekening **host-side** (de
`toolbox`-image heeft geen openssl-CLI;
`bootstrap.sh` draait toch al host-side, net als de UUID/timestamp in `publish-service.sh`):

```bash
openssl x509 -in "$OUTWAY_CERT" -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -r | cut -d' ' -f1
```

> **De outway berekent zijn eigen thumbprint met hetzelfde SPKI-SHA-256-algoritme** en identificeert
> zich daarmee naar de provider (zie commit `bd567a2`, #725). Matcht de bootstrap-berekening niet
> met de outway-boot-log-regel, dan is dít de plek om te kijken (troubleshooting in de README).

## Implementatie

### `contracts/bootstrap.sh` (nieuw)

Spiegelt `deploy/local/publish-service.sh` (zelfde toolbox-mTLS-, idempotentie- en
`ERRLOG`-conventies):

1. **Thumbprint** van de consumer-outway-**internal**-cert berekenen (host-side openssl).
2. **Idempotentie-check** (scoped): als een eerdere run een geaccepteerd contract vastlegde
   (state-file met de `content_hash`), en die **exacte hash** staat nog op de provider →
   no-op. De check grept op de **globaal-unieke `content_hash`**, niet op servicenaam/OIN/`"accept"`
   (zie kader hieronder).
3. **Indienen**: `POST /v1/contracts` (`contract_content`) op de **consumer**-manager
   (Internal-API `:9443`, consumer internal-cert). Manager tekent namens consumer + synct naar de
   provider. **2xx + `content_hash` = de consumer-handtekening**; faalt de respons zonder
   `content_hash` → hard fail (spiegelt `publish-service.sh`).
4. **Accepteren**: poll de provider-manager tot het contract (op `content_hash`) daar zichtbaar is,
   dan `PUT /v1/contracts/{content_hash}/accept` op de **provider**-manager (provider internal-cert).
   **2xx = de provider-handtekening.** Daarna scoped re-GET (hash aanwezig) + state-file schrijven.
5. **Best-effort token** (bonus, non-fataal): `POST /token` (`scope=content_hash`); log het
   resultaat + diagnostiek, faal niet als het scope/grant-detail afwijkt (echte token-afdwinging
   = #728).

> **Waarom geen losse grep op servicenaam/OIN/`"accept"`.** Op de provider-manager staat óók het
> auto-geaccepteerde **servicePublication**-contract voor dezelfde `example-service`. Een losse
> grep over de hele contractenlijst op servicenaam, provider-OIN of `"accept"` matcht daardoor
> **altijd** (false green) — de tokens hoeven niet bij één contract te horen. Daarom rust het
> succes op de **twee deterministische 2xx-responsen** (POST = consumer-sig, PUT accept =
> provider-sig, scoped op exact die hash) en gebruiken idempotentie/verify uitsluitend een grep op
> de **unieke `content_hash`**, die het publicatie-contract per definitie niet deelt.

### Idempotentie via state-file

De `content_hash` van een succesvol geaccepteerd contract wordt weggeschreven naar
`contracts/.bootstrap-state/<consumer>-<provider>-<service>.hash` (gitignored; niet-geheim,
host-lokaal). Een herstart leest 'm terug en no-opt **als dat contract nog de provider-accept
draagt**; is de state weg, het contract verdwenen of niet meer geaccepteerd, dan bouwt de
bootstrap 'm opnieuw op (self-healing). Bij een verse checkout zónder state kan een 2e opzet een
tweede geldig contract aanmaken — onschadelijk (de outway gebruikt er één), en in de praktijk
begint `run-smokes.sh` vanaf `down -v`.

### Accept-STAAT i.p.v. blote aanwezigheid (jq)

Aanwezigheid van de `content_hash` in de contractenlijst bewijst géén accept: de consumer heeft
het contract zélf opgesteld, dus de hash staat er vanaf creatie (pending). Alleen een
provider-handtekening onder `signatures.accept` bewijst de accept. `bootstrap.sh` en
`smoke-contract.sh` checken die staat host-side met **jq** (shape-tolerant: `content_hash` op
top-niveau óf onder `.content`), en vallen zónder jq terug op een aanwezigheidscheck — verantwoord
omdat de accept dan al deterministisch bewezen is door de `PUT …/accept`-2xx tijdens de bootstrap.
Dit geldt voor (a) de idempotentie-skip, (b) de post-accept-verify in `bootstrap.sh`, en (c) de
onafhankelijke consumer-side verify in `smoke-contract.sh`.

Parametriseerbaar via env (defaults = de example-peers) zodat het mechanisme **generiek** is:
`CONSUMER_OIN`, `PROVIDER_OIN`, `SERVICE_NAME`, cert-paden, manager-hostnamen.

### `deploy/local/smoke-contract.sh` (nieuw)

Draait `bootstrap.sh` en **assert** hard dat het contract wederzijds ondertekend is: `GET
/v1/contracts` op zowel consumer- als provider-manager toont een accept-signature van **beide**
OIN's voor het `serviceConnection`-grant. Fail-hard met timeout + `curl`-stderr op FAIL-paden,
conform de bestaande smokes. Volgorde: `up` → `publish-service.sh` (provider) →
`smoke-discover.sh` (consumer, #725) → `smoke-contract.sh` (#727).

### `contracts/bootstrap.md`

Placeholder vervangen door de echte stappen + verwijzing naar `bootstrap.sh`.

### `deploy/local/README.md`

Fase F (#727) documenteren: contract-bootstrap + `smoke-contract.sh` + troubleshooting
(thumbprint-mismatch, provider-accept ontbreekt).

## Error handling

- Bestaande conventies: `--fail-with-body` op curl, `ERRLOG` opvangen + op FAIL-paden surfacen,
  poll met timeout, idempotente skips.
- **Provider-accept ontbreekt** (contract wel gesynct, niet geaccepteerd): expliciete
  foutmelding + provider-manager-logs.
- **Thumbprint-mismatch**: gedocumenteerd als eerste verdachte bij een latere egress-fout (#728).

## Testen / acceptatie

- `bootstrap.sh` idempotent her-draaibaar (2e run = no-op, geen dubbel contract).
- `smoke-contract.sh` groen: wederzijds ondertekend `serviceConnection`-contract tussen
  `example-consumer` en `example-provider`.
- Lint groen (shellcheck-schoon bash, markdownlint).
- **Bewijs draait op de docker-host** (geen docker in de agent-omgeving), net als #724/#725.

## Open punten

- **Grant-hash voor token-scope**: OpenFSC-versiegevoelig; daarom best-effort in #727 en hard
  afgedekt via de native outway-egress in #728.
- **`service`-veld in de connection-grant**: **bevestigd (2026-07-02)** — het `service`-blok
  VEREIST de discriminator `type: SERVICE_TYPE_SERVICE` (zonder → 500 "invalid service type"; de
  publicatie-grant defaultte 'm, de connection-grant niet). `protocol` is hier niet nodig (dat
  hoort bij de publicatie).
