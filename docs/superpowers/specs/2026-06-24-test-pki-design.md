# Ontwerp: test-PKI inrichten (#722)

> Status: vastgesteld in brainstorm 2026-06-24. Branch: `feature/test-pki-722` (op PR #4).
> Issue: [MinBZK/MijnOverheidZakelijk#722](https://github.com/MinBZK/MijnOverheidZakelijk/issues/722).
>
> **Update (na FBS-OIN-inventarisatie):** de `magazijn-org`-peer is gesplitst in twee
> provider-peers `magazijn-a`/`magazijn-b` met echte OIN's uit moza-poc-fbs-berichtenbox;
> `uitvraag-org` en `directory` kregen synthetische test-OIN's. Actuele toewijzing:
> `pki/README.md` → "Peers & OIN's". De `magazijn-org`/dummy-OIN-voorbeelden hieronder tonen
> het oorspronkelijke skelet.

## 1. Doel & scope

Een werkende **test-PKI** waarmee elke peer een eigen identiteit (X.509-cert) krijgt, en de
groep een eigen test-CA als trust-anchor heeft. Spiegelt de cfssl-tooling van de OpenFSC
reference implementation (`open-fsc/pki/` + `open-fsc/ca/`).

**In scope (#722):**

- Groep-trust-anchor: root-CA → intermediate-CA (eigen test-CA, géén PKIoverheid).
- Per-peer **external** certs per FSC-endpoint (manager / inway / outway), met
  `subject.serialNumber` = OIN en `subject.organization` = peer-naam.
- Lege, getekende CRL + bekabeling naar de group rules.
- Secret-handling: genereren naar gitignored output + het ZAD-`attachments`-mountcontract
  documenteren.

**Out of scope:**

- ~~**Internal-component PKI** (inter-component mTLS manager↔inway↔outway↔txlog binnen één peer)
  → hoort bij de deploy, #723.~~ **Herzien (2026-06-25):** tijdens #723-grounding bleek de
  manager-cert-set onvolledig (`moza-fsc-testnet#5`-comment) — een werkende manager wil náást de
  group-identity óók internal-certs (`TLS_CERT`, `TLS_INTERNAL_UNAUTHENTICATED_*`). Omdat dit
  cert-*generatie* is (≠ deploy), is het alsnog in #722 belegd: per-peer self-signed internal-CA +
  internal-leaf per endpoint (`pki/internal/<peer>/…`). #723 *consumeert* ze. Zie `pki/README.md`
  → "Twee cert-ketens per endpoint".
- **Daadwerkelijk mounten/uploaden** van certs via ZAD `attachments` → geblokkeerd door de
  openstaande ZAD cert-upload-feature (zie `CLAUDE.md` → "Openstaande ZAD-dependency"). #722
  stopt bij *genereren + mountcontract documenteren*.

## 2. Achtergrond / besluiten

- Gesloten testnet → eigen test-CA als trust-anchor, geen PKIoverheid (besluit #720, zie
  `docs/ontwerpkeuzes.md`).
- OpenFSC-keuzes overgenomen: Peer ID = OIN uit `subject.serialNumber`; Peer-naam uit
  `subject.organization`; mTLS verplicht (client + server); contract-signing via JWS (RS512/ES256)
  met dezelfde sleutel → cert heeft `signing`-usage nodig.
- Brainstorm-keuzes (2026-06-24):
  - Tooling = **OpenFSC cfssl-pattern** (`init.sh` / `issue.sh` + json-profielen), niet een eigen
    openssl-script en niet step-ca.
  - CA-keten = **root → intermediate → leaf** (spiegelt OpenFSC; root-key kan offline).
  - Cert-scope = groep/external PKI **+ per-peer internal-component PKI** (herzien 2026-06-25,
    zie "Out of scope").

## 3. Architectuur

```text
root CA (RSA-4096, key offline-houdbaar)
  └─ intermediate CA            (tekent peers; usages: digital signature, cert sign, crl sign, signing)
       ├─ magazijn-org : manager-cert + inway-cert    (serialNumber=OIN_magazijn, O="magazijn-org")
       ├─ uitvraag-org : manager-cert + outway-cert   (serialNumber=OIN_uitvraag,  O="uitvraag-org")
       └─ directory    : directory-cert + manager-cert (serialNumber=OIN_directory, O="directory")
trust_anchor (group rules) = root.pem      CRL = intermediate.crl
```

Per peer delen alle endpoints dezelfde `serialNumber` (OIN) en `O` (naam); CN/SAN verschilt per
endpoint-hostname. Dit is exact het OpenFSC-`external`-PKI-model (per-endpoint certs, gedeelde OIN).

### cfssl-profielen (1:1 uit OpenFSC)

- `intermediate`: `is_ca`, `max_path_len_zero`; usages `digital signature, cert sign, crl sign, signing`.
- `peer`: usages `signing, key encipherment, server auth, client auth`.
  - `server auth` → inway (provider, poort 443) en manager (8443) als server.
  - `client auth` → outway (consumer) en manager-mesh als client.
  - `signing` → contract-JWS-ondertekening.

## 4. Repo-layout

```text
pki/
  config.json                       cfssl signing-profielen (intermediate + peer)
  ca.json                           root-CA CSR (CN, O, C=NL, key rsa-4096)
  intermediate.json                 intermediate-CA CSR
  init-ca.sh                        genkey -initca root -> intermediate -> sign     (← open-fsc/pki/init.sh)
  issue.sh                          per-endpoint cert uit csr.json                  (← open-fsc/pki/issue.sh)
  gen-crl.sh                        lege CRL (cfssl gencrl) -> ca/intermediate.crl
  fix-permissions.sh                chmod o-rw op *key.pem                          (← open-fsc/pki/fix-permissions.sh)
  verify.sh                         openssl-asserts (zie §7)
  peers/<peer>/<endpoint>/csr.json  committed template (CN/OIN/O/hosts — géén secret)
  ca/                               GITIGNORED: root+intermediate keys/pems, intermediate.crl
  out/<peer>/<endpoint>/            GITIGNORED: key.pem + cert.pem(chain)
  README.md                         run-instructies + cfssl-install + checklist
```

`csr.json` per endpoint = OpenFSC-getrouw. OIN/naam/hostnames zijn **niet-geheim** → wel committen
als template. Keys/certs → gitignored (al gedekt door `.gitignore`: `*.pem *.key *.crt *.crl secrets/`).

Endpoints per peer:

| peer | endpoints |
|---|---|
| `magazijn-org` (provider) | manager, inway |
| `uitvraag-org` (consumer) | manager, outway |
| `directory` | directory, manager |

## 5. Data-flow (operator-run, lokaal — nooit CI)

```text
1. init-ca.sh          -> ca/root.{key,pem} + ca/intermediate.{key,pem}; root.pem = trust-anchor
2. issue.sh [-f]       -> loop peers/*/*/csr.json -> cfssl gencert -profile peer
                          -> out/<peer>/<endpoint>/{key.pem, cert.pem(+intermediate aangehecht)}
3. gen-crl.sh          -> ca/intermediate.crl (leeg, getekend)
4. fix-permissions.sh  -> chmod o-rw *key.pem
5. operator -> ZAD attachments (encrypted, read-only mount)        [GEBLOKKEERD: #723-dep]
```

cfssl + cfssljson draaien **alleen lokaal** bij de operator. Geen secrets in de repo, geen
cert-generatie in CI of in een container-image.

## 6. Cert-profiel (per peer-endpoint)

| Veld | Waarde | Betekenis |
|---|---|---|
| `subject.serialNumber` | OIN | wordt Peer ID |
| `subject.O` | peer-naam | wordt Peer-naam |
| `subject.C` | `NL` | vast |
| `CN` + `hosts` (SAN) | endpoint-hostname (inway-SNI / manager-addr) | TLS-hostname |
| EKU | serverAuth + clientAuth | profiel `peer` |
| KU | digitalSignature, keyEncipherment | profiel `peer` |
| key | RSA-4096 | spiegelt OpenFSC |

Placeholders nu, definitief later:

- **OIN's:** `00000000000000000000` per peer → echte test-OIN's invullen. `peers/*/values.example.yaml`
  bevat al `TODO(#722)` op `peer.oin`.
- **Hostnames:** placeholder tot de ZAD-routes (inway-SNI op 443, manager-addr op 8443) vaststaan (#723).
  Regenereren met `issue.sh -f` zodra bekend.

## 7. Verificatie & acceptatie

`verify.sh` (of README-sectie) draait openssl-asserts — geen test-framework (shell/PKI):

```bash
openssl verify -CAfile pki/ca/root.pem pki/out/<peer>/<endpoint>/cert.pem   # keten geldig
openssl x509  -in pki/out/<peer>/<endpoint>/cert.pem -noout -subject        # serialNumber=OIN, O=naam
openssl crl   -in pki/ca/intermediate.crl -noout -text                      # CRL parseert
git status --porcelain pki/ | grep -E '\.(pem|key|crt|crl)$' && exit 1      # géén secrets gestaged
```

Acceptatiecriteria-mapping (#722):

| Criterium | Bewijs |
|---|---|
| Eigen test-CA als trust-anchor | `init-ca.sh` levert `root.pem`; bekabeld in `group-config` |
| Per peer key+cert via script | `issue.sh` levert per-endpoint `key.pem`+`cert.pem` |
| Secrets via ZAD-mechanisme, nooit in image | gitignored output + gedocumenteerd `attachments`-mountcontract; cfssl alleen lokaal |

## 8. Wiring naar bestaande config

- `group/group-config.example.yaml`: `trust_anchor.ca_cert` → `…/root.pem`, `crl` → `…/intermediate.crl`
  (paden al aanwezig; bevestigen).
- `pki/README.md`: checklist afvinken, run-volgorde, cfssl-install (`go install
  github.com/cloudflare/cfssl/cmd/...@latest` of via mise).
- `.env.example`: `TLS_NLX_ROOT_CERT` / `TLS_ORG_CERT` / `TLS_ORG_KEY` paden consistent met `out/`-layout.

## 9. Risico's & open punten

- **cfssl-dependency:** operator + (eventuele) lokale verificatie hebben `cfssl`/`cfssljson` nodig.
  Niet in CI gebruikt (geen secrets daar). Install documenteren.
- **ZAD attachments geblokkeerd:** mount-stap (5) kan pas live na de ZAD cert-upload-feature.
  Tot dan: genereren + documenteren. Markeren met `TODO(#723)`.
- **Echte OIN's/hostnames:** placeholders tot toewijzing; regenereren met `-f`.
- **Root-key-bewaring:** voor de PoC lokaal/gitignored; geen HSM. Documenteren als test-only.

## 10. Niet-doen (YAGNI)

- Geen renewal-automatisering / cert-manager (statische test-certs).
- Geen step-ca/cfssl-serve runtime (offline genereren volstaat).
- Internal-component PKI = **wél** (per-peer internal-CA, herzien 2026-06-25 — zie §1).
  Géén intermediate voor de internal-keten (één self-signed root per peer volstaat).
- **Eén group-trust-anchor (single-TA), géén intermediate op de internal-keten** — bewuste
  versimpeling t.o.v. OpenFSC. OpenFSC's dev-harness draait twee parallelle group-CA's
  (`AMOUNT_OF_CAS=2`, round-robin) om de **Trust-Anchor-List** (FSC-Core §4.1.5) te oefenen, en
  geeft de internal-keten een intermediate. Dat test OpenFSC's *eigen* keten-/TA-afhandeling —
  code die wij niet wijzigen en die OpenFSC's harness al bewijst → bewezen techniek, niet door
  ons aan te tonen. Voor een gesloten testnet met één eigen CA is single-TA de natuurlijke
  minimale config. `TODO(#723)`: tweede trust-anchor + internal-intermediate toevoegen áls
  productie-federatie-fidelity (multi-TA-rotatie) ooit binnen scope komt.
- Geen OCSP (CRL volstaat voor de PoC).
