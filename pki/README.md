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
./pki/init-ca.sh          # 1. group root + intermediate test-CA -> pki/ca/
./pki/issue.sh -f         # 2. per peer: group- + internal-certs (zie onder)
./pki/gen-crl.sh          # 3. lege CRL                          -> pki/ca/intermediate.crl
./pki/fix-permissions.sh  # 4. world-rw van keys halen
./pki/verify.sh           # 5. acceptatie-asserts (exit 0 = groen)
./pki/combine-pem.sh      # 6. (ZAD) cert+key -> combined.pem voor de passthrough-upload
./pki/zad-bundle.sh directory   # 7. (ZAD) upload-set + manifest per peer -> pki/zad-upload/
```

`pki/ca/root.pem` = trust-anchor voor de group rules (`group/group-config.example.yaml`).

Voor ZAD (zie `docs/spikes/zad-attachments.md`):

- `combine-pem.sh` voegt per group-endpoint `cert.pem` + `key.pem` samen tot `combined.pem`
  voor "Publicatie op het web" modus 2 (eigen certificaat op de pod / passthrough), die één PEM
  met cert + key wil.
- `zad-bundle.sh <peer>` verzamelt de hele upload-set (group-root, per-endpoint cert/key +
  combined, internal-CA + internal cert/key) in `pki/zad-upload/<peer>/` met een `MANIFEST.md`
  dat per bestand het beoogde pod-pad (attachment) + de `TLS_*`-env-var noemt.

Beide outputs zijn gitignored (bevatten privésleutels).

## Twee cert-ketens per endpoint

Een werkende manager wil méér dan één cert (gegrond op open-fsc `modd.conf` +
`helm/charts/open-fsc-manager/templates/deployment.yaml`). `issue.sh` levert per
endpoint twee certs uit twee losse ketens:

| Keten | Issuer | Pad | Env-vars (manager) |
|-------|--------|-----|--------------------|
| **group** (extern) | group-intermediate (`pki/ca/`) | `pki/out/<peer>/<endpoint>/` | `TLS_GROUP_CERT/KEY` + hergebruikt voor `TLS_GROUP_TOKEN_*` en `TLS_GROUP_CONTRACT_*` |
| **internal** | per-peer internal-CA (`pki/internal/<peer>/ca/`) | `pki/internal/<peer>/<endpoint>/` | `TLS_CERT/KEY` + hergebruikt voor `TLS_INTERNAL_UNAUTHENTICATED_*` |
| **internal-root** | self-signed root (zie boven) | `pki/internal/<peer>/ca/root.pem` | `TLS_ROOT_CERT` + `TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT` |

Token + contract **hergebruiken** de group-identity-cert — zoals open-fsc dat zelf
doet (`modd.conf:194-199`), geen losse certs. De internal-CA is een eigen,
self-signed root **per peer** (spiegelt open-fsc `pki/internal/<org>/ca/`), staat
los van de group-trust-anchor en wordt door `issue.sh` automatisch aangemaakt.

## Een peer toevoegen

Maak `pki/peers/<peer>/<endpoint>/csr.json` met `serialnumber` = de OIN (wordt Peer ID),
`names[].O` = peer-naam, `CN`/`hosts` = de endpoint-hostname. Draai `./pki/issue.sh -f`.
Dezelfde `csr.json` voedt beide ketens (group + internal); de internal-CA voor een
nieuwe peer wordt automatisch aangemaakt.

## Te leveren (#722)

- [x] Genereer-script test-CA (root + intermediate) — `init-ca.sh`.
- [x] Per-peer leaf-certs via script — `issue.sh` (group- én internal-keten).
- [x] Per-peer internal-CA + internal-certs (manager-cert-set compleet) — `issue.sh`.
- [x] CRL-distributie — `gen-crl.sh` (lege CRL, intermediate als issuer).
- [ ] Secrets via ZAD `attachments` (encrypted, read-only mount) — feature **beschikbaar sinds
      2026-06-29** (eerder geblokkeerd). `TODO(#723)`: mount group-trust (`pki/ca/root.pem`,
      `pki/ca/intermediate.crl`), per-peer `out/<peer>/<endpoint>/{cert,key}.pem` (group) plus
      `internal/<peer>/ca/root.pem` + `internal/<peer>/<endpoint>/{cert,key}.pem` (internal).
      Nooit in image bakken.

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
