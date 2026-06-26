# Lokale harness (#723) — directory + announce-proof

Runnable shift-left van de ZAD-deploy: directory + magazijn-a-peer + SNI-router op
:443. Bewijst dat een peer zich aanmeldt (announce) bij de directory. Bouwt voort op
`docs/spikes/manager-443-sni/`.

## Prerequisite (#722) — cert-contract

De harness mount onze test-CA read-only. #722 (PR #5, geleverd in `ba46bcc`/`2880c5b`)
levert per endpoint **twee ketens** onder `pki/`:

| Pad | Doel | Env |
|-----|------|-----|
| `pki/ca/root.pem` | group-CA root (trust-anchor) | `TLS_GROUP_ROOT_CERT` |
| `pki/internal/<peer>/ca/root.pem` | **per-peer** internal-CA root | `TLS_ROOT_CERT`, `TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT` |
| `pki/out/<peer>/<endpoint>/{cert,key}.pem` | group-identity (hergebruikt voor token+contract) | `TLS_GROUP_CERT/KEY`, `TLS_GROUP_TOKEN_*`, `TLS_GROUP_CONTRACT_*` |
| `pki/internal/<peer>/<endpoint>/{cert,key}.pem` | internal mTLS | `TLS_CERT/KEY`, `TLS_INTERNAL_UNAUTHENTICATED_*` |

`<peer>` ∈ {`directory`, `magazijn-a`}; `<endpoint>` = de component (`manager` voor de
mesh, `directory` voor de directory-component). Internal-root is **per peer** — mount voor
elke peer zijn eigen `pki/internal/<peer>/ca/root.pem`. Hostnames in de certs:
`directory.fsc-test.local`, `magazijn-a.fsc-test.local`. De mesh verifieert de hostname
niet (auth op OIN), maar houd ze consistent met `SELF_ADDRESS`/SNI.

> Token+contract hergebruiken de group-identity-cert — bevestigd conform OpenFSC
> (`modd.conf:194-199`); geen losse token/contract-certs.

## Draaien

```bash
cp deploy/local/.env.example deploy/local/.env   # IMAGE_TAG staat al goed
# zorg dat #722 de certs onder pki/ heeft gegenereerd (./pki/issue.sh -f)
docker compose -f deploy/local/docker-compose.yaml up -d
./deploy/local/smoke-announce.sh                 # exit 0 = announce bewezen
```

## Opruimen

```bash
docker compose -f deploy/local/docker-compose.yaml down -v
```
