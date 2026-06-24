# PKI — test-CA als trust-anchor

Gesloten testnet → **eigen test-CA**, geen PKIoverheid (zie `docs/ontwerpkeuzes.md`).
Spiegelt OpenFSC's cfssl-tooling (`open-fsc/pki/`). Ontwerp:
`docs/superpowers/specs/2026-06-24-test-pki-design.md`.

> **Niet voor productie.** Sleutels/certs horen **niet** in deze repo: `pki/ca/` en `pki/out/`
> zijn gitignored. Alleen scripts, CA-configs en `csr.json`-templates staan in git.

## Benodigdheden

- `cfssl` + `cfssljson` (CloudFlare PKI-toolkit), `openssl`.

```bash
go install github.com/cloudflare/cfssl/cmd/cfssl@latest
go install github.com/cloudflare/cfssl/cmd/cfssljson@latest
```

## Gebruik

```bash
./pki/init-ca.sh          # 1. root + intermediate test-CA  -> pki/ca/
./pki/issue.sh -f         # 2. per-peer endpoint-certs       -> pki/out/<peer>/<endpoint>/
./pki/gen-crl.sh          # 3. lege CRL                       -> pki/ca/intermediate.crl
./pki/fix-permissions.sh  # 4. world-rw van keys halen
./pki/verify.sh           # 5. acceptatie-asserts (exit 0 = groen)
```

`pki/ca/root.pem` = trust-anchor voor de group rules (`group/group-config.example.yaml`).

## Een peer toevoegen

Maak `pki/peers/<peer>/<endpoint>/csr.json` met `serialnumber` = de OIN (wordt Peer ID),
`names[].O` = peer-naam, `CN`/`hosts` = de endpoint-hostname. Draai `./pki/issue.sh -f`.

## Te leveren (#722)

- [x] Genereer-script test-CA (root + intermediate) — `init-ca.sh`.
- [x] Per-peer leaf-certs via script — `issue.sh`.
- [x] CRL-distributie — `gen-crl.sh` (lege CRL, intermediate als issuer).
- [ ] Secrets via ZAD `attachments` (encrypted, read-only mount) — **geblokkeerd**, wacht op
      ZAD cert-upload-feature. `TODO(#723)`: mount `pki/ca/root.pem`, `pki/ca/intermediate.crl`
      en per-peer `out/<peer>/<endpoint>/{cert,key}.pem`. Nooit in image bakken.

## Peers & OIN's

OIN = `subject.serialNumber` = Peer ID (1:1). Toegewezen (#722):

| Peer | Endpoints | OIN | Herkomst |
|------|-----------|-----|----------|
| `magazijn-a` | manager, inway | `00000001003214345000` | echt — Magazijn A (moza-poc-fbs-berichtenbox) |
| `magazijn-b` | manager, inway | `00000001823288444000` | echt — Magazijn B (moza-poc-fbs-berichtenbox) |
| `uitvraag-org` | manager, outway | `00000000000000000020` | synthetisch — geen org-OIN in FBS |
| `directory` | directory, manager | `00000000000000000010` | synthetisch — infra-peer |

**Synthetische conventie:** 20 cijfers (`^[0-9]{20}$`), alles-nul met laag volgnummer →
herkenbaar niet-echt, botst niet met de `00000001…`-org-OIN's. Mag in dit gesloten testnet
(eigen test-CA als anchor, géén PKIoverheid-validatie).

> **OIN wijzigen = op TWEE plekken lockstep** (drift = kapotte Peer ID):
>
> 1. `pki/peers/<peer>/<endpoint>/csr.json` → veld `serialnumber`
> 2. `peers/<peer>/values.example.yaml` → veld `peer.oin`

## Placeholders

- **Hostnames** zijn placeholder (`*.fsc-test.local`). `TODO(#723)`: echte ZAD inway-SNI /
  manager-adressen; daarna `./pki/issue.sh -f`.
