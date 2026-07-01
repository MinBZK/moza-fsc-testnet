# Spec — generieke consumer-onboarding (example-consumer)

> Status: ontwerp (#725). Branch: `feature/peer-uitvraag-725`.
> Voorloper/template: [Spec A](2026-06-29-fsc-generiek-provider-onboarding-design.md)
> (`example-provider`, #724). Volgorde/status: sub-issues van epic
> [#737](https://github.com/MinBZK/MijnOverheidZakelijk/issues/737).

## Aanleiding

Spec A bewees de generieke **provider**-onboarding (`example-provider`: cert → announce →
dienst publiceren → vindbaar in directory) en scoopte de **consumer**-kant expliciet uit naar
#725. Deze spec is de tegenhanger: een neutrale afnemende peer die zich aanmeldt op de
federatie en de gepubliceerde dienst terugvindt.

De grenzen zijn scherp getrokken tegen de buur-issues (in #725's body vastgelegd):

- **Contract** (ServiceConnectionGrant grant→sign→accept) → #727.
- **Echte data-call** (outway → inway → upstream + token/transactie-logging) → #728.
- **Groene ZAD-run** → #729.

Deze spec levert dus de consumer-peer die **boot, announcet en discovert** — klaar om in #727
een contract te leggen en in #728 daadwerkelijk af te nemen.

## Gewenst resultaat

Een neutrale `example-consumer`-peer (synthetische OIN `00000000000000000020`, organisatie-naam
`example-consumer`) die lokaal (`deploy/local/`) bewijst:

1. **Boot** — manager + outway + controller + eigen DB komen gezond op naast de bestaande
   centrale kern en `example-provider`.
2. **Announce** — de consumer-manager meldt zich bij de directory (verschijnt in `peers.peers`
   met `manager_address` op `:443`).
3. **Discovery** — de door `example-provider` gepubliceerde `example-service` is vindbaar in de
   directory (poll op de directory-DB, zoals `smoke-publish.sh`).

## Niet in scope

- Contract-bootstrap (#727), echte data-call + logging (#728), groene ZAD-run (#729).
- De outway **routeert** nog niet: zonder contract heeft-ie niets te doen. In #725 boot-t en
  healthcheckt-ie enkel (config valide, group-cert geladen). Echte egress = #728.
- De consumer-**controller** is idle in #725: zijn taak (grant-admin voor afnemer-toegang) begint
  in #727. Meegenomen omdat het acceptatiecriterium `manager+outway+controller+DB` het eist en om
  de compose niet twee keer te bedraden.
- FBS-uitvraagpeer (echte OIN, co-located bij de app) → [FBS]-zusterissue #781 (repo B).

## Architectuur

Gespiegeld op `example-provider` (Spec A). De `example-consumer` draait als **tweede peer in
dezelfde `deploy/local`-compose** naast de provider. Dat is een bewuste keuze: de
discovery-assert heeft een gepubliceerde `example-service` nodig, dus de provider (en zijn
publish-flow) moet mee-draaien. De centrale kern (directory-manager, directory-ui, postgres,
router) staat er al en wordt gedeeld.

### Componenten `example-consumer`

| Component | Rol in #725 | Bron (OpenFSC) |
|-----------|-------------|----------------|
| `manager-example-consumer` | peer-manager (consumer-mode): **announce** bij directory; ontvangt later de ServiceConnectionGrant (#727). `SELF_ADDRESS=https://example-consumer.fsc-test.local:443`, eigen DB `fsc_example_consumer`. | `open-fsc-manager` |
| `outway-example-consumer` | egress-proxy; **enkel booten/healthy** in #725 (routeren = #728). Group-cert (client-auth naar provider-inway) + internal-cert (naar eigen manager). | `open-fsc-outway` |
| `controller-example-consumer` | dienst/afname-administratie (Registration- + Administration-API + UI); `AUTHN_TYPE=none` lokaal. **Idle in #725**, host-poorten los van de provider-controller. Eigen DB `fsc_controller_example_consumer`. | `open-fsc-controller` |
| gedeeld | postgres, router (HAProxy SNI), directory-manager, directory-ui | — |

Geen inway en geen stub-upstream: de consumer biedt zelf niets aan.

### Env-patroon (mirror provider)

`manager-example-consumer` erft de `x-manager-common-env`-anchor en zet, net als
`manager-example-provider`:

- `SELF_ADDRESS=https://example-consumer.fsc-test.local:443`;
- poorten `LISTEN_ADDRESS_EXTERNAL=:8443`, `_INTERNAL=:9443`, `_INTERNAL_UNAUTHENTICATED=:9444`,
  `MONITORING_ADDRESS=:8080`;
- `STORAGE_POSTGRES_DSN=…/fsc_example_consumer`;
- group-certs uit `pki/out/example-consumer/manager/` (token + contract = zelfde cert);
- internal-certs uit `pki/internal/example-consumer/{ca,manager}/`;
- `TX_LOG_API_ADDRESS=https://txlog.placeholder.invalid:7611` (presence-check; niet gedialed bij
  announce). Directory-mode-velden (`AUTO_SIGN_GRANTS`, lege txlog) zijn provider/directory-only
  en dus **niet** op de consumer.

`outway-example-consumer`: de exacte OpenFSC-outway-env (naam van de manager-adres-variabele,
listen-poort van de lokale proxy, cert-env-namen) wordt in de plan-fase geverifieerd tegen de
OpenFSC `helm/charts` outway-values — het provider-compose bevat geen outway om van te kopiëren.
Werkhypothese (te bevestigen): group-cert (`TLS_GROUP_*`) + internal-cert (`TLS_*`) +
`MANAGER_INTERNAL_UNAUTHENTICATED_ADDRESS` naar de eigen manager `:9444`, plus `GROUP_ID` en
`TLS_GROUP_ROOT_CERT`, analoog aan de inway.

## Data flow (onboarding, geen data-pad)

```text
example-consumer                          centrale kern
  manager ───announce──────────────────► directory-manager (peers.peers)
  outway  ──(boot; contract-config leeg)  (geen egress in #725; routeren = #728)
  controller (idle)                                       directory-ui / directory-DB
                                                              ▲
example-provider ──ServicePublicationGrant──► directory ─────┘  (example-service in catalogus)
  smoke: consumer-discovery leest example-service uit de directory-DB
```

## Wijzigingen in dit repo

### Toevoegen

- **`pki/peers/example-consumer/{manager,outway,controller}/csr.json`** — CSR's met
  `serialnumber=00000000000000000020`, `O=example-consumer`, `C=NL`. CN/hosts per endpoint:
  - manager: CN `manager.example-consumer.fsc-test.local`, hosts + `example-consumer.fsc-test.local`;
  - outway: CN/host `outway.example-consumer.fsc-test.local`;
  - controller: CN/host `controller.example-consumer.fsc-test.local`.

  `pki/issue.sh` auto-discovert elke `pki/peers/*/*/csr.json` en genereert group-cert
  (`pki/out/example-consumer/<endpoint>/`) + per-peer internal-CA
  (`pki/internal/example-consumer/…`). `pki/verify.sh` dekt de nieuwe certs automatisch.
  **Geen wijziging aan de pki-scripts nodig.**

- **`peers/example-consumer/values.example.yaml`** — neutrale consumer-template, spiegel van
  `peers/example-provider/`: OIN `…0020`, `outway` i.p.v. `inway`, geen `upstream`. Zelfde
  TODO-comment-structuur (certs/poorten/txlog via vervolgwerk / ZAD `attachments`).

### `deploy/local`-harness

- **`docker-compose.yaml`** — nieuwe services:
  - `migrate-example-consumer` (DB `fsc_example_consumer`, run-to-completion, `restart: on-failure`);
  - `manager-example-consumer` (network-alias `manager.example-consumer.fsc-test.local`;
    `depends_on` migrate + `manager-directory`);
  - `migrate-controller-example-consumer` (DB `fsc_controller_example_consumer`);
  - `controller-example-consumer` (alias `controller.example-consumer.fsc-test.local`;
    host-poorten los van de provider-controller, bv. UI `127.0.0.1:8091`);
  - `outway-example-consumer` (alias `outway.example-consumer.fsc-test.local`; `depends_on`
    manager-example-consumer).

  Plus **symmetrie-rename** van de bestaande provider-controllerservices:
  `controller` → `controller-example-provider`, `migrate-controller` →
  `migrate-controller-example-provider`. Alleen de compose-service-keys + `depends_on`-verwijzingen
  wijzigen; de network-alias is al `controller.example-provider.fsc-test.local` en de smoke-scripts
  reiken de controller via `toolbox`-curl op die hostnaam (niet via de service-key), dus DNS en
  scripts blijven werken.

- **`postgres-init.sql`** — + `CREATE DATABASE fsc_example_consumer;` +
  `CREATE DATABASE fsc_controller_example_consumer;`.

- **`haproxy.cfg`** — + SNI-backend `example-consumer.fsc-test.local` →
  `manager-example-consumer:8443` (manager-mesh op `:443`). De outway is een **client**; geen
  inbound-SNI-route nodig in #725.

- **`router`** (compose) — network-alias `example-consumer.fsc-test.local` toevoegen.

- **`smoke-discover.sh`** (nieuw) — bewijst de consumer-kant:
  1. assert **announce**: `example-consumer`-OIN staat in de directory-`peers.peers`
     (hergebruik van het `smoke-announce.sh`-patroon met `CONSUMER_OIN=…0020`);
  2. assert **discovery**: poll de directory-DB tot `example-service` in de catalogus staat
     (zoals `smoke-publish.sh`), met positief-controle op de directory-self-row om
     query/schema-fouten van een echte discovery-fout te onderscheiden.

  Fail-hard met timeout + `psql`-stderr op FAIL-paden, conform de bestaande smokes. De discovery
  vereist dat de provider eerst publiceert; de smoke-volgorde is `up` → `publish-service.sh`
  (provider) → `smoke-discover.sh` (consumer).

### Docs

- **`deploy/local/README.md`** — consumer-flow + `smoke-discover.sh` beschrijven; de
  controller-rename benoemen.
- **`docs/topologie.md`** — checken dat de consumer-kant generiek staat (geen FBS-namen).
- **`CLAUDE.md`** — al gepatcht (issues-sectie wijst naar #737; huidige stap #725).

## Error handling

Bestaande harness-conventies aanhouden:

- `restart: on-failure` voor boot-races; health-gated `depends_on`; `migrate-*` als aparte
  run-to-completion service.
- Smoke poll't met timeout en surfacet `psql`-stderr op FAIL-paden.
- **Discovery-negatief**: smoke faalt expliciet als `example-service` niet binnen de timeout in de
  directory-catalogus staat; positief-controle (staat de directory-self-row er?) onderscheidt een
  query-fout van een echte discovery-fout.
- **Outway-boot**: faalt hard als de outway niet gezond opkomt met group-cert; in #725 wordt geen
  egress verwacht (geen contract), dus de healthcheck bewijst enkel gereedheid.

## Testen / acceptatie

- `pki/issue.sh` genereert `example-consumer`-certs; `pki/verify.sh` slaagt (inclusief de nieuwe
  endpoints).
- `docker compose up` brengt centrale kern + `example-provider` + `example-consumer` gezond op.
- `smoke-discover.sh`: **announce** + **discovery** beide groen.
- `grep -ri 'magazijn\|berichtenmagazijn\|uitvraag-org\|00000001…'` over config/harness geeft geen
  FBS-treffers (docs mogen FBS als voorbeeld noemen).
- Lint groen (markdownlint + yamllint + actionlint).

## Open punten

- **Outway-env**: exacte OpenFSC-outway-env-namen bevestigen tegen `helm/charts` in de plan-fase
  (werkhypothese hierboven).
- **Synthetische OIN `…0020`**: bevestigen dat dit nergens botst met een echte OIN (net als `…0030`
  voor de provider).
- **Host-poorten consumer-controller**: kiezen zodat ze niet botsen met de provider-controller
  (`8090`) en directory-ui (`8080`) — voorstel UI `8091`.
