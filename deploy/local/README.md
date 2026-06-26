# Lokale harness (#723) — directory + announce-proof

Runnable shift-left van de ZAD-deploy: directory + magazijn-a-peer + SNI-router op
:443. Bewijst dat een peer zich aanmeldt (announce) bij de directory. Bouwt voort op
`docs/spikes/manager-443-sni/`.

> **Geen wachten op #722.** De test-PKI-tooling (#722) zit al in deze branch
> (`pki/`). Je genereert de certs lokaal met `./pki/issue.sh` (stap 2 hieronder).
> De enige externe afhankelijkheid voor de harness is een **Docker-host** — dus je
> eigen laptop volstaat. (De ZAD `attachments`-cert-mount is een aparte
> ZAD-beheer-dependency en raakt alléén de echte ZAD-deploy, niet deze harness.)

## Benodigdheden op je laptop

- **Docker** + `docker compose` (v2).
- **cfssl + cfssljson + openssl** voor de cert-generatie — zie `pki/README.md`
  ("Benodigdheden") voor de `go install`-commando's.

## Draaiboek

Alle commando's vanuit de **repo-root**, op branch `feature/directory-group-723`.

```bash
# 1. Juiste branch (cert-set + harness zitten hier).
git switch feature/directory-group-723

# 2. Genereer de test-CA + per-peer certs (#722-tooling, lokaal — nooit in CI).
./pki/init-ca.sh          # group root + intermediate -> pki/ca/
./pki/issue.sh -f         # per peer: group- + internal-certs -> pki/out, pki/internal
./pki/gen-crl.sh          # lege CRL -> pki/ca/intermediate.crl
./pki/fix-permissions.sh  # privékeys -> 0600 (owner-only); de pod leest ze via stap 3
./pki/verify.sh           # acceptatie-asserts; verwacht: "== ALLE ASSERTS GROEN =="

# 3. Harness-env. De cert-lezende pods draaien als JOUW UID/GID, zodat ze de
#    0600-privékeys via de owner-bit lezen (keys blijven dicht).
cp deploy/local/.env.example deploy/local/.env
printf 'HOST_UID=%s\nHOST_GID=%s\n' "$(id -u)" "$(id -g)" >> deploy/local/.env

# 4. Start de stack (postgres, SNI-router, directory + magazijn-a, UIs).
docker compose -f deploy/local/docker-compose.yaml up -d

# 5. Bewijs de announce (pollt de directory-DB tot magazijn-a verschijnt).
./deploy/local/smoke-announce.sh     # verwacht: "OK: magazijn-a is aangemeld" + exit 0
```

Klaar met kijken? Opruimen:

```bash
docker compose -f deploy/local/docker-compose.yaml down -v
```

> **Hosts-bestand niet nodig.** De SNI-hostnames (`directory.fsc-test.local`,
> `magazijn-a.fsc-test.local`) resolven *binnen* het docker-netwerk via de
> router-aliases. De UIs benader je via `localhost`-poorten (hieronder).

## Beheer-UI (Fase C) — keycloak + controller

Na stap 4 draaien ook:

- **directory-ui** (catalogus): `http://localhost:8080`, geen login. De aangemelde
  magazijn-a-peer is hier zichtbaar.
- **controller** (beheer-UI): `http://localhost:8090`. Draait lokaal **zonder login**
  (`AUTHN_TYPE=none`, een door OpenFSC ondersteunde modus). De management — dienst
  publiceren, toegang aanvragen, contract grant→sign→accept — werkt zonder loginscherm,
  dus dit volstaat om dienst-koppeling lokaal te testen.
- **keycloak**: `http://localhost:8081`, admin `keycloak-admin` / `keycloak` (dev-defaults
  — **niet voor productie**). Alleen nodig voor de optionele OIDC-login hieronder.

### Volledige OIDC-login (later, conform OpenFSC) — TODO

OIDC is enkel de auth-laag vóór de controller; niet nodig om diensten te koppelen.
Volledig bedraden zoals OpenFSC vergt:

- realm **`organization-a`** + client **`open-fsc-controller-a`** (de keycloak-image bakt
  deze; **niet** `open-fsc`, wat het plan abusievelijk aannam). De echte waarden staan al
  in de controller-env (`docker-compose.yaml`).
- de **issuer-split** oplossen: `KC_HOSTNAME` (browser, `localhost`) vs intern
  (`keycloak:8080`) met één gedeelde hostnaam + `/etc/hosts` (zoals `open-fsc/.hosts`),
  anders faalt de OIDC-init met `issuer mismatch`.
- de **redirect-URI** van de baked client uitbreiden met onze controller-URL (de client
  kent alleen OpenFSC's eigen `…open-fsc.localhost:3011`).

Zet daarna `AUTHN_TYPE=oidc` op de controller.

## Troubleshooting

- **`verify.sh` rood / certs ontbreken** → stap 2 niet (volledig) gedraaid; draai
  `./pki/issue.sh -f` opnieuw.
- **Container kan cert niet vinden** → controleer dat `pki/out/<peer>/<endpoint>/`
  en `pki/internal/<peer>/…` bestaan; paden moeten matchen met de compose-env.
- **`permission denied` op `key.pem` bij boot (manager fatal)** → `HOST_UID`/`HOST_GID`
  in `deploy/local/.env` matchen niet met de eigenaar van de keys. Zet ze met
  `printf 'HOST_UID=%s\nHOST_GID=%s\n' "$(id -u)" "$(id -g)" >> deploy/local/.env` en
  `docker compose -f deploy/local/docker-compose.yaml up -d --force-recreate`.
- **`WARN invalid internal PKI key permissions`** → de keys staan te open. Met de
  UID-match + `0600` blijft deze WARN weg; hij is hoe dan ook niet-fataal.
- **Poort bezet** (443, 8080, 8081, 8090) → stop de conflicterende dienst of pas de
  `ports`/`bind` in `docker-compose.yaml` / `haproxy.cfg` aan.
- **Smoke faalt** → `docker compose -f deploy/local/docker-compose.yaml logs
  manager-directory manager-magazijn-a` voor de mesh-logs.

## Cert-contract (referentie)

De harness mount onze test-CA read-only op `/pki`. Per endpoint twee ketens:

| Pad | Doel | Env |
|-----|------|-----|
| `pki/ca/root.pem` | group-CA root (trust-anchor) | `TLS_GROUP_ROOT_CERT` |
| `pki/internal/<peer>/ca/root.pem` | **per-peer** internal-CA root | `TLS_ROOT_CERT`, `TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT` |
| `pki/out/<peer>/<endpoint>/{cert,key}.pem` | group-identity (hergebruikt voor token+contract) | `TLS_GROUP_CERT/KEY`, `TLS_GROUP_TOKEN_*`, `TLS_GROUP_CONTRACT_*` |
| `pki/internal/<peer>/<endpoint>/{cert,key}.pem` | internal mTLS | `TLS_CERT/KEY`, `TLS_INTERNAL_UNAUTHENTICATED_*` |

`<peer>` ∈ {`directory`, `magazijn-a`}; `<endpoint>` = de component (`manager` voor de
mesh, `directory` voor de directory-component). Internal-root is **per peer**. De mesh
verifieert de hostname niet (auth op OIN), maar houd ze consistent met `SELF_ADDRESS`/SNI.

> Token+contract hergebruiken de group-identity-cert — bevestigd conform OpenFSC
> (`modd.conf:194-199`); geen losse token/contract-certs.
