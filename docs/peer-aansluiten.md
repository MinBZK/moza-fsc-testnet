# Runbook: een peer aansluiten op het testnet

> Voor een team dat een eigen dienst via FSC wil aanbieden (of afnemen) op dit testnet — met een
> eigen **peer** in een eigen ZAD-project. Nieuw met FSC? Begin bij [fsc-standaard.nl](https://fsc-standaard.nl/)
> (de standaard) en [docs.open-fsc.nl](https://docs.open-fsc.nl) (OpenFSC, de implementatie die we
> draaien).
>
> **Wat bewezen is.** Aanmelden, publiceren, contract en de echte aanroep zijn lokaal bewezen in
> [`deploy/local/`](../deploy/local/README.md). Op ZAD draaien de FBS-peers `logius` en `magazijn-a`
> volgens dit patroon; hun uitgewerkte runbooks staan in
> [moza-poc-fbs-berichtenbox](https://github.com/MinBZK/moza-poc-fbs-berichtenbox/tree/main/demo/environment)
> (`<peer>/deploy/zad/` en `federatie/contracts/zad-runbook.md`). Dit runbook maakt dat generiek.

## Het idee in één alinea

Een dienst aanbieden is geen config-bestand: je draait een eigen FSC-peer naast je applicatie. De
**manager** meldt je peer aan bij de centrale directory, de **inway** laat verkeer van andere peers
binnen, de **controller** is je beheerkant (dienst aanmelden, toegang goedkeuren) en de
**txlog-api** legt elke transactie vast. Je meldt de dienst aan in de controller, die publiceert
'm in de directory. Een afnemer vraagt toegang aan met een contract; jij tekent dat. Daarna roept de
afnemer je dienst aan via zijn **outway**.

## Wie doet wat

| Stap | Team (aansluiter) | Beheerder testnet |
|------|-------------------|-------------------|
| 1. Lokaal proberen | draait `deploy/local` met een wegwerp-CA | — |
| 2. Afstemmen | levert OIN, organisatienaam, ZAD-project + deployment | controleert OIN op botsing, levert group-gegevens |
| 3. Certificaten | maakt sleutels + CSR's, eigen internal-CA | tekent de CSR's met de test-CA en commit de certs |
| 4. ZAD inrichten | componenten, env, bijlagen, publicatie | — |
| 5. Aanmelden | controleert boot-logs | ziet de peer in de directory |
| 6. Dienst publiceren | in de eigen controller | — (directory tekent automatisch) |
| 7. Toegang | tekent contracten van afnemers | — |
| 8. Aanroepen | afnemer: app → outway | — |

Je hebt een **eigen ZAD-project** nodig (of een bestaand project van je app). Toegang tot het
directory-project `mft-tp9` is daarvoor niet nodig.

## Voorbeeldnamen in dit runbook

Vervang overal:

| Placeholder | Voorbeeld | Betekenis |
|-------------|-----------|-----------|
| `mijnpeer` | `mijnpeer` | peer-naam: paden, componentnamen (kleine letters) |
| `abcd-123` | `abcd-123` | je ZAD-project-id |
| `fsc-mijnpeer` | `fsc-mijnpeer` | de deployment waarin de peer draait |
| `<OIN>` | `00000000000000000040` | Peer ID, zie stap 2 |
| `<tag>` | — | OpenFSC-versie = `openfsc_min_version` in [`group/group-config.yaml`](../group/group-config.yaml) |

Hostnamen volgen daaruit (ZAD `domain_format = component-deployment-project`):

- **extern** (mesh, `:443`): `<component>-fsc-mijnpeer-abcd-123.rig.prd1.gn2.quattro.rijksapps.nl`
- **intern** (cluster-Service): `fsc-mijnpeer-<component>`, voluit
  `fsc-mijnpeer-<component>.rig-prd-abcd-123.svc.cluster.local`

## 1. Lokaal proberen

Draai de lokale harness: directory, een voorbeeld-aanbieder en een voorbeeld-afnemer, met de hele
keten van aanmelden tot aanroep. Eén commando vanuit de repo-root (vereist Docker, `cfssl`, `jq`):

```bash
./deploy/local/run-smokes.sh --wegwerp-ca
```

`--wegwerp-ca` maakt een eigen test-CA met certs in een tijdelijke map. De sleutels van het testnet
heb je daarvoor niet nodig, en `pki/` van je checkout blijft onaangeroerd.

`deploy/local/publish-service.sh` laat zien welke twee API-calls een dienst publiceren,
`contracts/bootstrap.sh` hoe een contract tot stand komt. Zie
[`deploy/local/README.md`](../deploy/local/README.md).

## 2. Afstemmen met de beheerder

**Team levert:**

- **OIN** — wordt je Peer ID (`subject.serialNumber` in elk cert). Gebruik de echte OIN van je
  organisatie, of een synthetische test-OIN volgens de conventie in
  [`pki/README.md`](../pki/README.md). Een OIN mag in de group maar één keer voorkomen.
- **Organisatienaam** — `subject.organization`; zo verschijnt je peer in de directory.
- **ZAD-project-id + deploymentnaam** — die bepalen je hostnamen en dus de SAN's in je certs.

**Beheerder controleert** de OIN tegen de aangemelde peers in de
[directory-ui](https://dirui-test-mft-tp9.rig.prd1.gn2.quattro.rijksapps.nl) en **levert**:

| Wat | Waarde |
|-----|--------|
| `GROUP_ID` | `moza-fbs-test` |
| `DIRECTORY_PEER_ID` | `00000000000000000010` |
| `DIRECTORY_MANAGER_ADDRESS` | `https://dirmgr-test-mft-tp9.rig.prd1.gn2.quattro.rijksapps.nl:443` |
| OpenFSC-versie | `openfsc_min_version` uit `group/group-config.yaml` |
| group-root, intermediate-cert, CRL | staan in git: `pki/ca/root.pem`, `pki/ca/intermediate.pem`, `pki/ca/intermediate.crl` |

> **Draai precies die OpenFSC-versie.** Een peer op een andere versie rekent andere contract-hashes
> en valt zonder foutmelding uit de group (zie `group/group-config.yaml`).

## 3. Certificaten

Elke peer heeft twee ketens (achtergrond: [`pki/README.md`](../pki/README.md)):

- **group** — getekend door de test-CA van het testnet; je identiteit in de mesh. Nodig voor de
  componenten die met andere peers praten: `manager`, `inway` (aanbieder), `outway` (afnemer).
- **internal** — getekend door je **eigen** internal-CA; alleen voor verkeer binnen je peer. Nodig
  voor elk component: ook `controller` en `txlog`.

> **Privésleutels verlaten je team niet, de CA-sleutel verlaat de beheerder niet.** Je stuurt alleen
> CSR's en openbare certs; de beheerder tekent en zet de openbare bestanden in git. Wie de
> intermediate-sleutel van de test-CA heeft, kan certs uitgeven voor elke OIN en zich zo voordoen als
> elke peer in de group.
>
> Bewaar je eigen sleutels versleuteld bij je eigen team, bijvoorbeeld met SOPS + age in een eigen
> private repo met een eigen `.sops.yaml`. Gebruik daarvoor níet `pki/geheimen.sh` en zet je sleutel
> niet in `pki/.sops.yaml`: die versleutelen voor de beheerders van het testnet en geven toegang tot
> de CA-sleutel.

### 3a. CSR-templates (team)

Werk in `pki/` van een checkout van deze repo. Maak per endpoint
`peers/mijnpeer/<endpoint>/csr.json`. De `hosts` zijn de SAN's: de interne Service-namen (daarop
verbinden de componenten onderling, met hostnaamverificatie) en voor `manager`/`inway`/`outway` ook
de externe hostnaam. Voorbeeld `manager`:

```json
{
  "CN": "mijnpeer-fscmgr-fsc-mijnpeer-abcd-123.rig.prd1.gn2.quattro.rijksapps.nl",
  "key": { "algo": "rsa", "size": 4096 },
  "hosts": [
    "mijnpeer-fscmgr-fsc-mijnpeer-abcd-123.rig.prd1.gn2.quattro.rijksapps.nl",
    "fsc-mijnpeer-mijnpeer-fscmgr",
    "fsc-mijnpeer-mijnpeer-fscmgr.rig-prd-abcd-123.svc.cluster.local"
  ],
  "serialnumber": "<OIN>",
  "names": [{ "O": "<Organisatienaam>", "C": "NL" }]
}
```

Deze templates blijven in je eigen checkout. Stonden ze in `main`, dan zou `issue.sh` er bij de
beheerder zelf certs voor uitgeven.

Draai **niet** `issue.sh` of `init-ca.sh`: `issue.sh` tekent met de CA-sleutel van het testnet, die je
niet hebt, en `init-ca.sh` maakt een nieuwe CA die niet op het testnet aansluit.

### 3b. Sleutels, internal-certs en CSR's (team)

```bash
cd pki
PEER=mijnpeer

# Eigen internal-CA (eenmalig).
mkdir -p "internal/$PEER/ca"
cfssl genkey -initca internal-ca.json | cfssljson -bare "internal/$PEER/ca/root"
rm "internal/$PEER/ca/root.csr"

# Internal-cert per endpoint (aanbieder: manager controller inway txlog; afnemer: outway i.p.v. inway).
for e in manager controller inway txlog; do
  mkdir -p "internal/$PEER/$e"
  cfssl gencert -config config.json -profile peer \
    -ca "internal/$PEER/ca/root.pem" -ca-key "internal/$PEER/ca/root-key.pem" \
    "peers/$PEER/$e/csr.json" | cfssljson -bare "internal/$PEER/$e/cert"
  mv "internal/$PEER/$e/cert-key.pem" "internal/$PEER/$e/key.pem"
  rm "internal/$PEER/$e/cert.csr"
done

# Group: alleen sleutel + CSR, voor de mesh-endpoints (afnemer: manager outway).
for e in manager inway; do
  mkdir -p "out/$PEER/$e"
  cfssl genkey "peers/$PEER/$e/csr.json" | cfssljson -bare "out/$PEER/$e/cert"
  mv "out/$PEER/$e/cert-key.pem" "out/$PEER/$e/key.pem"
done
```

Stuur de beheerder je CSR's (`out/mijnpeer/<endpoint>/cert.csr`) en de openbare helft van je
internal-keten: `internal/mijnpeer/ca/root.pem` en `internal/mijnpeer/<endpoint>/cert.pem`. Nooit een
`key.pem` of `root-key.pem`.

### 3c. CSR's tekenen (beheerder)

Zet de ontvangen CSR's als `<endpoint>.csr` in `pki/`, en de internal-bestanden op hun pad onder
`pki/internal/mijnpeer/`. Controleer eerst wat je tekent — `cfssl sign` neemt OIN, organisatie en
SAN's over uit de CSR:

```bash
cd pki
for e in manager inway; do   # afnemer: manager outway
  openssl req -in "$e.csr" -noout -verify -subject    # serialNumber = afgesproken OIN? O klopt?
  openssl req -in "$e.csr" -noout -text | grep -A1 'Subject Alternative Name'
done
```

Tekenen doe je met de intermediate-sleutel uit de geheime repo; haal die alleen daarvoor op
([`sleutelbeheer.md`](sleutelbeheer.md)):

```bash
./geheimen.sh ophalen groep
PEER=mijnpeer
for e in manager inway; do   # afnemer: manager outway
  cfssl sign -config config.json -profile peer \
    -ca ca/intermediate.pem -ca-key ca/intermediate-key.pem "$e.csr" | cfssljson -bare "$e"
  [ -s "$e.pem" ] || { echo "FOUT: $e niet getekend; $e.csr blijft staan" >&2; break; }
  mkdir -p "out/$PEER/$e"
  cat "$e.pem" ca/intermediate.pem > "out/$PEER/$e/cert.pem"   # keten: leaf + intermediate
  rm "$e.pem" "$e.csr"
done
./geheimen.sh wis groep
./verify.sh
```

Zet `pki/out/mijnpeer/` en `pki/internal/mijnpeer/` via een PR in git. `verify.sh` eist bij elk
group-cert een internal-cert, dus beide horen erin. Dan laat git zien wat er bij deze peer live staat,
en meldt de wekelijkse verloopcontrole ook deze certs. Niets hiervan is geheim.

### 3d. Afronden en controleren (team)

Na de merge van die PR staan je certs in `main`. Je eigen kopieën van de internal-bestanden staan
nog ongevolgd in je checkout, en daarop weigert `git pull`; haal ze eerst weg:

```bash
cd pki
PEER=mijnpeer
rm "internal/$PEER/ca/root.pem" "internal/$PEER"/*/cert.pem
git pull
./fix-permissions.sh
./verify.sh                  # verwacht: == ALLE ASSERTS GROEN ==
./zad-bundle.sh "$PEER"      # upload-set + MANIFEST.md in zad-upload/mijnpeer/
```

`verify.sh` controleert de ketens, dat elk cert een OIN heeft, dat elke sleutel bij zijn cert past (een
verkeerd getekende of verwisselde CSR valt zo op), de scheiding tussen group en internal, en dat er
geen sleutels zichtbaar zijn voor git.

**Vernieuwen.** De verloopcontrole meldt 30 dagen vooraf welke certs verlopen, met een issue in deze
repo; de beheerder seint je in. Maak de nieuwe group-sleutel náást de oude, zodat de live sleutel
blijft tot het nieuwe cert in `main` staat:

```bash
cd pki
PEER=mijnpeer
for e in manager inway; do   # afnemer: manager outway
  cfssl genkey "peers/$PEER/$e/csr.json" | cfssljson -bare "out/$PEER/$e/nieuw"
done
```

Stuur `out/mijnpeer/<endpoint>/nieuw.csr`; de beheerder tekent volgens 3c. Na de merge: `git pull`,
per endpoint `mv "out/$PEER/$e/nieuw-key.pem" "out/$PEER/$e/key.pem"`, dan `verify.sh`, `zad-bundle.sh`
en de bijlagen vervangen (4d). Vernieuw je je internal-keten, stuur dan ook die openbare bestanden: ze
staan in git.

Vervangt de beheerder de intermediate van het testnet, dan gaan ook jouw group-certs opnieuw via een
CSR. Stop je met je peer, laat de beheerder dan `pki/out/mijnpeer/` en `pki/internal/mijnpeer/`
weghalen: een verlopen cert in git laat de controles van elke PR falen.

## 4. ZAD inrichten

### 4a. Eigen deployment

Maak in de Operations Manager UI een **lege** deployment `fsc-mijnpeer`, zonder clone-from. Zet de
peer niet in `test`: PR-previews klonen uit `test`, en een gekloonde manager meldt zich met
dezelfde OIN nog eens aan bij de directory.

### 4b. Componenten

| Component | Image | Poorten | Publicatie op het web | Wanneer |
|-----------|-------|---------|-----------------------|---------|
| `mijnpeer-fscpg` | `docker.io/library/postgres:17` | `5432` | geen | altijd |
| `mijnpeer-fscmgr` | `ghcr.io/minbzk/moza-fsc-testnet-manager-migrate:<tag>` | `8443,9443,9444` | **modus 2 (passthrough)** | altijd |
| `mijnpeer-fscctl` | `ghcr.io/minbzk/moza-fsc-testnet-controller-migrate:<tag>` | `8080,9443,9444` | zie stap 6 | altijd |
| `mijnpeer-fsctxlog` | `ghcr.io/minbzk/moza-fsc-testnet-txlog-migrate:<tag>` | `8443` | geen | altijd |
| `mijnpeer-fscinway` | `docker.io/federatedserviceconnectivity/inway:<tag>` | `8443` | **modus 2 (passthrough)** | aanbieder |
| `mijnpeer-fscoutway` | `docker.io/federatedserviceconnectivity/outway:<tag>` | `8443` | geen | afnemer |

- De eerste poort is die van de ingress; de overige worden alleen als interne Service-poort
  gepubliceerd.
- De `*-migrate`-images draaien `migrate up` en daarna `serve`. Houd ze op **één replica**: twee
  gelijktijdige migraties op dezelfde database kunnen de migratiestand beschadigen.
- **Modus 2** laat TLS door naar de pod. Edge- of reencrypt-publicatie breekt de
  certificate-binding van FSC.

### 4c. Env per component

Zet de env in de Operations Manager UI. De API past `env_vars` alleen toe bij het **aanmaken** van
een component; wijzigen daarna gaat via de UI (of `zadctl env`).

> **Zet het databasewachtwoord alleen in de UI.** Het staat in de DSN's hieronder als
> `<wachtwoord>`; commit het nooit.

**`mijnpeer-fscpg`**, plus een bijlage `/docker-entrypoint-initdb.d/10-schemas.sql` met
`CREATE SCHEMA IF NOT EXISTS manager; CREATE SCHEMA IF NOT EXISTS txlog;`:

```dotenv
POSTGRES_USER=fsc
POSTGRES_PASSWORD=<wachtwoord>
POSTGRES_DB=fsc
PGDATA=/var/lib/postgresql/data/pgdata
```

Manager en txlog krijgen elk een eigen `search_path` zodat hun migratietellers niet botsen. De
controller **niet**: die maakt z'n eigen schema aan en loopt met een `search_path` vast op migratie 1.
Koppel een persistent volume op `PGDATA`, anders ben je bij elke nieuwe pod je contracten kwijt.

**`mijnpeer-fscmgr`**:

```dotenv
LOG_TYPE=live
LOG_LEVEL=info
AUDITLOG_TYPE=stdout
GROUP_ID=moza-fbs-test
DIRECTORY_PEER_ID=00000000000000000010
DIRECTORY_MANAGER_ADDRESS=https://dirmgr-test-mft-tp9.rig.prd1.gn2.quattro.rijksapps.nl:443
SELF_ADDRESS=https://mijnpeer-fscmgr-fsc-mijnpeer-abcd-123.rig.prd1.gn2.quattro.rijksapps.nl:443
CONTROLLER_REGISTRATION_API_ADDRESS=https://fsc-mijnpeer-mijnpeer-fscctl:9443
TX_LOG_API_ADDRESS=https://fsc-mijnpeer-mijnpeer-fsctxlog:8443
AUTO_SIGN_GRANTS=
LISTEN_ADDRESS_EXTERNAL=0.0.0.0:8443
LISTEN_ADDRESS_INTERNAL=0.0.0.0:9443
LISTEN_ADDRESS_INTERNAL_UNAUTHENTICATED=0.0.0.0:9444
MONITORING_ADDRESS=0.0.0.0:8080
STORAGE_POSTGRES_DSN=postgres://fsc:<wachtwoord>@fsc-mijnpeer-mijnpeer-fscpg:5432/fsc?sslmode=disable&search_path=manager
DISABLE_CRL_CHECKS=true
TLS_GROUP_ROOT_CERT=/etc/fsc/ca/root.pem
TLS_GROUP_CERT=/etc/fsc/out/mijnpeer/manager/cert.pem
TLS_GROUP_KEY=/etc/fsc/out/mijnpeer/manager/key.pem
TLS_GROUP_TOKEN_CERT=/etc/fsc/out/mijnpeer/manager/cert.pem
TLS_GROUP_TOKEN_KEY=/etc/fsc/out/mijnpeer/manager/key.pem
TLS_GROUP_CONTRACT_CERT=/etc/fsc/out/mijnpeer/manager/cert.pem
TLS_GROUP_CONTRACT_KEY=/etc/fsc/out/mijnpeer/manager/key.pem
TLS_ROOT_CERT=/etc/fsc/internal/mijnpeer/ca/root.pem
TLS_CERT=/etc/fsc/internal/mijnpeer/manager/cert.pem
TLS_KEY=/etc/fsc/internal/mijnpeer/manager/key.pem
TLS_INTERNAL_UNAUTHENTICATED_ROOT_CERT=/etc/fsc/internal/mijnpeer/ca/root.pem
TLS_INTERNAL_UNAUTHENTICATED_CERT=/etc/fsc/internal/mijnpeer/manager/cert.pem
TLS_INTERNAL_UNAUTHENTICATED_KEY=/etc/fsc/internal/mijnpeer/manager/key.pem
```

De `:443` in beide manager-adressen is verplicht; zonder poort stopt de manager bij het opstarten
met `missing port in manager address`.

**`mijnpeer-fscctl`**:

```dotenv
LOG_TYPE=live
LOG_LEVEL=info
AUDITLOG_TYPE=stdout
GROUP_ID=moza-fbs-test
DIRECTORY_PEER_ID=00000000000000000010
MANAGER_ADDRESS_INTERNAL=https://fsc-mijnpeer-mijnpeer-fscmgr:9443
AUTHN_TYPE=none
AUTHZ_TYPE=rbac
CSRF_PROTECTION_ENABLED=false
LISTEN_ADDRESS_UI=0.0.0.0:8080
LISTEN_ADDRESS_REGISTRATION_API=0.0.0.0:9443
LISTEN_ADDRESS_ADMINISTRATION_API=0.0.0.0:9444
MONITORING_ADDRESS=0.0.0.0:8081
STORAGE_POSTGRES_DSN=postgres://fsc:<wachtwoord>@fsc-mijnpeer-mijnpeer-fscpg:5432/fsc?sslmode=disable
TLS_ROOT_CERT=/etc/fsc/internal/mijnpeer/ca/root.pem
TLS_CERT=/etc/fsc/internal/mijnpeer/controller/cert.pem
TLS_KEY=/etc/fsc/internal/mijnpeer/controller/key.pem
```

**`mijnpeer-fsctxlog`**:

```dotenv
LOG_TYPE=live
LOG_LEVEL=info
LISTEN_ADDRESS=0.0.0.0:8443
MONITORING_ADDRESS=0.0.0.0:8081
STORAGE_POSTGRES_DSN=postgres://fsc:<wachtwoord>@fsc-mijnpeer-mijnpeer-fscpg:5432/fsc?sslmode=disable&search_path=txlog
TLS_ROOT_CERT=/etc/fsc/internal/mijnpeer/ca/root.pem
TLS_CERT=/etc/fsc/internal/mijnpeer/txlog/cert.pem
TLS_KEY=/etc/fsc/internal/mijnpeer/txlog/key.pem
```

**`mijnpeer-fscinway`** (aanbieder):

```dotenv
LOG_TYPE=live
LOG_LEVEL=info
NAME=mijnpeer-inway
GROUP_ID=moza-fbs-test
SELF_ADDRESS=https://mijnpeer-fscinway-fsc-mijnpeer-abcd-123.rig.prd1.gn2.quattro.rijksapps.nl:443
LISTEN_ADDRESS=0.0.0.0:8443
MONITORING_ADDRESS=0.0.0.0:8081
CONTROLLER_REGISTRATION_API_ADDRESS=https://fsc-mijnpeer-mijnpeer-fscctl:9443
MANAGER_INTERNAL_UNAUTHENTICATED_ADDRESS=https://fsc-mijnpeer-mijnpeer-fscmgr:9444
TX_LOG_API_ADDRESS=https://fsc-mijnpeer-mijnpeer-fsctxlog:8443
DISABLE_CRL_CHECKS=true
TLS_GROUP_ROOT_CERT=/etc/fsc/ca/root.pem
TLS_GROUP_CERT=/etc/fsc/out/mijnpeer/inway/cert.pem
TLS_GROUP_KEY=/etc/fsc/out/mijnpeer/inway/key.pem
TLS_ROOT_CERT=/etc/fsc/internal/mijnpeer/ca/root.pem
TLS_CERT=/etc/fsc/internal/mijnpeer/inway/cert.pem
TLS_KEY=/etc/fsc/internal/mijnpeer/inway/key.pem
```

**`mijnpeer-fscoutway`** (afnemer). De app roept de outway aan op zijn interne Service, over TLS met
het internal-cert:

```dotenv
LOG_TYPE=live
LOG_LEVEL=info
NAME=mijnpeer-outway
GROUP_ID=moza-fbs-test
SELF_ADDRESS=https://mijnpeer-fscoutway-fsc-mijnpeer-abcd-123.rig.prd1.gn2.quattro.rijksapps.nl:443
LISTEN_ADDRESS=0.0.0.0:8443
MONITORING_ADDRESS=0.0.0.0:8081
LISTEN_HTTPS=true
MANAGER_INTERNAL_ADDRESS=https://fsc-mijnpeer-mijnpeer-fscmgr:9443
CONTROLLER_REGISTRATION_API_ADDRESS=https://fsc-mijnpeer-mijnpeer-fscctl:9443
TX_LOG_API_ADDRESS=https://fsc-mijnpeer-mijnpeer-fsctxlog:8443
DISABLE_CRL_CHECKS=true
TLS_GROUP_ROOT_CERT=/etc/fsc/ca/root.pem
TLS_GROUP_CERT=/etc/fsc/out/mijnpeer/outway/cert.pem
TLS_GROUP_KEY=/etc/fsc/out/mijnpeer/outway/key.pem
TLS_ROOT_CERT=/etc/fsc/internal/mijnpeer/ca/root.pem
TLS_CERT=/etc/fsc/internal/mijnpeer/outway/cert.pem
TLS_KEY=/etc/fsc/internal/mijnpeer/outway/key.pem
TLS_SERVER_CERT=/etc/fsc/internal/mijnpeer/outway/cert.pem
TLS_SERVER_KEY=/etc/fsc/internal/mijnpeer/outway/key.pem
```

### 4d. Bijlagen (certs)

Voeg per component elk bestand uit `pki/zad-upload/mijnpeer/` als **bestand** toe op zijn pad onder
`/etc/fsc/` (`MANIFEST.md` noemt pad en env-var per bestand):

| Component | Bijlagen |
|-----------|----------|
| manager, inway, outway | `ca/root.pem`, `out/mijnpeer/<endpoint>/{cert,key}.pem`, `internal/mijnpeer/ca/root.pem`, `internal/mijnpeer/<endpoint>/{cert,key}.pem` |
| controller, txlog | `internal/mijnpeer/ca/root.pem`, `internal/mijnpeer/<endpoint>/{cert,key}.pem` |

Twee valkuilen, allebei zichtbaar als `certificate signed by unknown authority` of een ketenfout bij
het opstarten:

- `out/.../cert.pem` moet **twee** PEM-blokken bevatten (leaf + intermediate).
- Het group-cert hoort onder `out/`, het internal-cert onder `internal/`. Niet verwisselen.

## 5. Aanmelden controleren

- Boot-logs zonder TLS- of ketenfouten. Twee meldingen zijn onschuldig: `TLS handshake error … EOF`
  (de TCP-health-probe) en `invalid PKI key permissions` (bijlagen worden read-only gemount).
- De inway staat als geregistreerde inway in je controller.
- Je peer staat met je OIN in de [directory-ui](https://dirui-test-mft-tp9.rig.prd1.gn2.quattro.rijksapps.nl),
  met een manager-adres dat eindigt op `:443`.

## 6. Dienst publiceren (aanbieder)

Maak in je controller een dienst aan met:

- **naam** — hoe afnemers de dienst vinden;
- **endpoint-URL** — waar de inway je applicatie bereikt. In dezelfde deployment de interne
  Service-naam; in een andere deployment de ingress-URL van de app (of een interne route met
  `cross-domain-access`, zie stap 8);
- **inway-adres** — de `SELF_ADDRESS` van je inway.

De controller laat de manager een publicatie-contract tekenen; de directory tekent automatisch mee.
Daarna staat de dienst in de directory-ui.

> **Publiceer de controller-UI niet op het web zolang `AUTHN_TYPE=none`.** Dan kan iedereen met de
> URL diensten aanmelden en contracten tekenen namens jouw peer. Veilige toegang op ZAD (OIDC) is nog
> niet uitgewerkt. Tot die tijd: doe de calls vanuit een pod in je eigen deployment, zoals
> `deploy/local/publish-service.sh` ze doet (Administration-API `:9444`, manager `:9443`, met het
> internal-cert). Publiceer je de UI tóch tijdelijk, haal de publicatie dan direct na gebruik weg.

## 7. Toegang verlenen (contract)

Een afnemer vraagt toegang aan met een `ServiceConnectionGrant`: hij dient het contract in bij zijn
eigen manager, dat synct het via de mesh naar jou. **Jij tekent expliciet** (`PUT
/v1/contracts/{hash}/accept` op je manager, of accepteren in de controller). De directory tekent
alleen publicaties automatisch, geen toegang.

De interne manager-API is alleen binnen je deployment bereikbaar. Wie dit wil automatiseren: de FBS-peers
draaien per peer een klein contract-bootstrap-component; zie
[`federatie/contracts/zad-runbook.md`](https://github.com/MinBZK/moza-poc-fbs-berichtenbox/blob/main/demo/environment/federatie/contracts/zad-runbook.md),
inclusief wat te doen als een accept-handtekening onderweg strandt.

## 8. Aanroepen (afnemer)

- De app roept de outway aan op `https://fsc-mijnpeer-mijnpeer-fscoutway.rig-prd-abcd-123.svc.cluster.local:8443`
  met de header `Fsc-Grant-Hash: <grant-hash>`. Dat is de hash van de grant, niet die van het
  contract. Met `ENABLE_GRANT_HASH_SUGGESTION=true` op de outway geeft een call zonder geldige hash
  de bruikbare hash terug.
- De app vertrouwt je internal-CA: mount `internal/mijnpeer/ca/root.pem` ook op het app-component.
- Draait de app in een andere deployment, dan blokkeert de NetworkPolicy het verkeer tot je
  `cross-domain-access` instelt: een `outbound`-regel bij de app én een `inbound`-regel bij de
  outway. Uitgewerkt in
  [`cutover-interne-outway.md`](https://github.com/MinBZK/moza-poc-fbs-berichtenbox/blob/main/demo/environment/logius/deploy/zad/cutover-interne-outway.md).
- Het bewijs dat het verkeer door FSC liep: dezelfde `Fsc-Transaction-Id` in de txlog van beide peers.

## Problemen oplossen

| Symptoom | Oorzaak |
|----------|---------|
| `missing port in manager address` | `:443` ontbreekt in `SELF_ADDRESS` of `DIRECTORY_MANAGER_ADDRESS` |
| `required flag(s) "controller-registration-api-address" not set` | `CONTROLLER_REGISTRATION_API_ADDRESS` ontbreekt; verplicht voor elke manager |
| `certificate signed by unknown authority` | group/internal verwisseld, of `out/.../cert.pem` zonder intermediate |
| hostnaamfout op `fsc-mijnpeer-…:9443` | interne Service-naam ontbreekt in de SAN's; nieuwe CSR, opnieuw tekenen |
| `Dirty database version N` | migratie brak af (vaak twee pods tegelijk); schoon de migratiestand van dat component op en herstart met één replica |
| peer staat niet in de directory, geen fout in de logs | andere OpenFSC-versie dan de group, of een cert dat niet naar de test-CA ketent |
| env-wijziging heeft geen effect | ingesteld via de API op een bestaand component; zet 'm in de UI |
| contract blijft bij de afnemer `proposed` | accept-handtekening niet aangekomen; opnieuw distribueren vanaf de aanbieder |

## Nog niet uitgewerkt

- **CRL-controle staat uit** (`DISABLE_CRL_CHECKS=true`) zolang de testnet-CRL geen distributiepunt
  heeft.
- **Controller-authenticatie op ZAD** (OIDC) — zie stap 6.
- **Organisaties zonder OIN.** Dit runbook gaat uit van een OIN als Peer ID; een route voor
  organisaties zonder OIN is hier nog niet beschreven.
