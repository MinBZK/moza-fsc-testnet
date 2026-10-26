# Sleutel- en secretbeheer

> Operationele kant van secrets in dit repo: waar ze leven, wie erbij kan, en hoe je ze roteert.
> Een **kwetsbaarheid melden** doe je niet hier: daarvoor geldt het org-brede
> [responsible-disclosurebeleid van MinBZK](https://github.com/MinBZK/.github/blob/main/SECURITY.md)
> (melden via [GOV-CERT/NCSC](https://www.ncsc.nl/contact/kwetsbaarheid-melden)). Deze repo heeft
> daarom geen eigen `SECURITY.md`.
>
> Voor de impactbeoordeling van zo'n melding is dit relevant: dit is een **gesloten testnet** met een
> eigen test-CA — geen productiedata, geen PKIoverheid-certificaten.

## Wat waar staat

| Wat | Waar | Opmerking |
|-----|------|-----------|
| `ZAD_API_KEY_DIRECTORY` | **Actions**-secretstore van dit repo | Expliciet **niet** in de Dependabot-secretstore: bot-PR's horen niet met deze key te kunnen deployen. |
| `ZAD_PROJECT_ID_DIRECTORY` | Actions-variable (`vars`) | Geen geheim, wel omgevingsspecifiek. |
| Certificaten, ketens en CRL van de test-PKI | Git, onder `pki/` | Openbaar. Laat zien wat er op ZAD staat; zie [Certificaten van de test-PKI](#certificaten-van-de-test-pki). |
| Privésleutels van de test-PKI | Private repo `MinBZK/moza-fsc-testnet-geheimen`, versleuteld met SOPS + age | Wie kan ontsleutelen: `pki/.sops.yaml`. Op ZAD als bijlage via de Operations Manager UI. |
| Env-waarden per component | Operations Manager UI | Git documenteert ze via `peers/directory/*.env.example`, maar handhaaft ze niet. |

Sleutels en `.env`-bestanden horen niet in de repository en staan in [`.gitignore`](../.gitignore);
de certificaten van de test-PKI wel. Let op de grens daarvan: secret-scanning met push-protection staat aan,
maar dekt **provider**-patronen (GitHub-, cloudtokens). Een connection string met wachtwoord — precies
wat `STORAGE_POSTGRES_DSN` in de env-templates voordoet — valt daarbuiten, dus `.gitignore` is voor die
klasse de enige barrière. Non-provider-patronen aanzetten vraagt org-rechten en staat nog open.

## Certificaten van de test-PKI

De test-PKI heeft een openbare en een geheime helft.

- **Openbaar, in git:** `pki/ca/{root,intermediate}.pem`, `pki/ca/intermediate.crl`,
  `pki/out/<peer>/<endpoint>/cert.pem`, `pki/internal/<peer>/ca/root.pem` en
  `pki/internal/<peer>/<endpoint>/cert.pem`. ZAD-bijlagen zijn niet terug te lezen, dus git is de plek
  die laat zien wat er live staat. `cert-verloop.yml` meldt elke maandag met een issue wat binnen
  30 dagen verloopt.
- **Geheim, in [`MinBZK/moza-fsc-testnet-geheimen`](https://github.com/MinBZK/moza-fsc-testnet-geheimen):**
  elke privésleutel als eigen bestand, versleuteld met SOPS + age.

  | In de geheime repo | Lokaal |
  |---|---|
  | `groep/intermediate-key.pem` | `pki/ca/intermediate-key.pem` |
  | `groep/root/root-key.pem` | `pki/ca/root-key.pem` |
  | `<peer>/group/<endpoint>-key.pem` | `pki/out/<peer>/<endpoint>/key.pem` |
  | `<peer>/internal/ca-key.pem` | `pki/internal/<peer>/ca/root-key.pem` |
  | `<peer>/internal/<endpoint>-key.pem` | `pki/internal/<peer>/<endpoint>/key.pem` |

Wie wat kan ontsleutelen staat in `pki/.sops.yaml`: één age-sleutel per persoon, met de naam erbij.
De root-sleutel heeft een eigen regel met alleen de twee root-houders; voor het dagelijkse werk is hij
niet nodig. `.sops.yaml` staat in déze repo en niet in de geheime: die valt onder het gratis
GitHub-abonnement en heeft dus geen branch protection. Een nieuwe ontvanger loopt zo via een
gereviewde PR. Wie de geheime repo kan wijzigen, kan ook geen sleutel ongemerkt vervangen:
`pki/geheimen.sh ophalen` draait `verify.sh`, en die legt elke sleutel naast zijn certificaat in git.

`pki/.sops.yaml` heeft deze vorm. De root-regel staat bovenaan: sops kiest de eerste regel die past, en
legt `path_regex` op het absolute pad, dus `(^|/)groep/root/` en niet `^groep/root/`. `geheimen.sh`
weigert de root-sleutel op te slaan als die regel niet matcht.

```yaml
keys:
  - &persoon1 age1…  # Voornaam Achternaam (root-houder)
  - &persoon2 age1…  # Voornaam Achternaam (root-houder)
  - &persoon3 age1…  # Voornaam Achternaam
creation_rules:
  - path_regex: (^|/)groep/root/
    key_groups:
      - age:
          - *persoon1
          - *persoon2
  - path_regex: .*
    key_groups:
      - age:
          - *persoon1
          - *persoon2
          - *persoon3
```

### Eenmalig: toegang krijgen

1. Installeer `sops` en `age` (`brew install sops age`, of de releases op GitHub).
2. Maak een sleutelpaar en zet het pad vast. Zonder `SOPS_AGE_KEY_FILE` zoekt sops op macOS in
   `~/Library/Application Support/sops/age/`.

   ```bash
   mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # ook in je shell-profiel
   ```

   Bewaar een kopie van `keys.txt` in je wachtwoordkluis. Kwijt betekent geen toegang, tot iemand je
   opnieuw toevoegt.
3. Open een PR die je publieke sleutel (de `age1…` achter `# public key:` in `keys.txt`) met je naam
   aan `pki/.sops.yaml` toevoegt: onder `keys:` en in de regel `.*`.
4. Na de merge draait iemand met toegang `pki/geheimen.sh ontvangers` en pusht de geheime repo.
   Voor een nieuwe root-houder draait een root-houder ook `pki/geheimen.sh ontvangers root`.
5. Clone de geheime repo naast deze (`../moza-fsc-testnet-geheimen`), of zet `FSC_GEHEIMEN_DIR`.

### Certificaten vernieuwen

1. Werk de geheime repo bij (`git pull` in `../moza-fsc-testnet-geheimen`) en haal op:
   `pki/geheimen.sh ophalen groep <peer>`. Dat draait `verify.sh`.
2. Geef opnieuw uit. Group-keten: verwijder `pki/out/<peer>/` en draai `pki/issue.sh`. Eén
   internal-cert: verwijder `pki/internal/<peer>/<endpoint>/` en draai `pki/issue.sh`. `issue.sh -f`
   geeft álle leafs opnieuw uit, maar vervangt nooit een gecommitte internal-root.
3. `pki/verify.sh` moet groen zijn, inclusief de ankercontrole.
4. `pki/geheimen.sh opslaan <peer>` en commit in de geheime repo, maar push nog niet. Open hier een
   PR met de nieuwe `cert.pem`'s.
5. Na de merge, in één keer: push de geheime repo, draai `pki/zad-bundle.sh <peer>` en plaats de
   bestanden in de Operations Manager UI (zie [`spikes/zad-attachments.md`](spikes/zad-attachments.md)).
   Zo lopen git, de geheime repo en ZAD niet uit de pas: vóór de merge passen de nieuwe sleutels niet
   bij de certs op `main`.
6. `pki/geheimen.sh wis`. Dat weigert zolang een sleutel niet in de geheime repo staat.

Verloopt de CRL: `pki/geheimen.sh ophalen groep`, `pki/gen-crl.sh`, en dezelfde stappen 4 tot en met 6
voor `pki/ca/intermediate.crl`, dat bij elke peer als bijlage staat.

### Een set vervangen

Een nieuwe CA sluit niet aan op wat er draait. Vervangen vraagt daarom een commit, zodat het in een PR
zichtbaar is.

- **Internal-CA van een peer:** `git rm -r pki/internal/<peer>/` en commit. `issue.sh` maakt daarna
  een nieuwe CA met nieuwe leafs; plaats de hele internal-set van die peer opnieuw in ZAD.
- **Group-intermediate:** alleen een root-houder. Daarna gelden stap 4 tot en met 6 hierboven voor
  `pki/ca/intermediate.pem`, de CRL en alle group-certs, bij elke peer, ook die in
  `moza-poc-fbs-berichtenbox`.

  ```bash
  pki/geheimen.sh ophalen root groep
  cfssl genkey -initca pki/intermediate.json | cfssljson -bare pki/ca/intermediate
  cfssl sign -config pki/config.json -ca pki/ca/root.pem -ca-key pki/ca/root-key.pem \
    -profile intermediate pki/ca/intermediate.csr | cfssljson -bare pki/ca/intermediate
  rm pki/ca/intermediate.csr
  pki/gen-crl.sh
  rm -rf pki/out/*/        # alle group-leafs; de internal-keten blijft staan
  pki/issue.sh && pki/verify.sh
  ```

- **Root (het anker):** `init-ca.sh` weigert zolang `pki/ca/root.pem` in git staat. Een nieuw anker is
  een nieuwe federatie: elke peer moet om, ook die in `moza-poc-fbs-berichtenbox`.

### Toegang intrekken

1. Haal de sleutel uit `pki/.sops.yaml` (PR). Draai na de merge `pki/geheimen.sh ontvangers`; was het
   een root-houder, dan draait een andere root-houder ook `ontvangers root`. Push de geheime repo.
2. Opnieuw versleutelen helpt niet tegen een kopie die al bestaat. Een dagelijkse ontvanger kon de
   groepssleutel en elke internal-CA-sleutel openen. Volledig afsluiten betekent daarom: de
   group-intermediate vervangen, per peer de internal-CA vervangen, en alle certs opnieuw plaatsen in
   ZAD, ook bij de peers in `moza-poc-fbs-berichtenbox`. Voor een vertrokken root-houder komt daar een
   nieuw anker bij.
3. Kiest het team voor dit gesloten testnet om dat niet te doen, leg die keuze dan vast in het issue
   van het vertrek.

## Rotatie `ZAD_API_KEY_DIRECTORY`

Roteer periodiek, bij een vermoeden van lekkage, of wanneer een teamlid met toegang vertrekt.

Verifieer een nieuwe key **read-only**. Draai daarvoor níet `zad-deploy-directory` handmatig: die
deployt standaard `test` op het productiecluster. Doe in plaats daarvan één API-call (zie ook
[`zad-directory-deploy.md`](zad-directory-deploy.md), stap 6):

```bash
read -rs ZAD_API_KEY; export ZAD_API_KEY     # plak de key niet inline
curl -sS -o /dev/null -w '%{http_code}\n' -H "X-API-Key: $ZAD_API_KEY" \
  https://zad.rijksapp.nl/api/v2/projects/mft-tp9/deployments
```

Dit print alléén de statuscode: `200` = de nieuwe key werkt, `401` = niet. Wil je ook de namen zien
(`| jq -r '.deployments[]?.name'`), gebruik dan die `?` — `deployments` mag legitiem ontbreken omdat het
endpoint alleen deployments van het huidige cluster teruggeeft (zie [`zad-cleanup.md`](zad-cleanup.md),
"Verificatie = drie calls"). Een lege namenlijst is dus géén bewijs dat de key stuk is; de statuscode is
dat wel — vandaar dat de check hierboven op de code kijkt.

Zet de nieuwe key daarna in **Settings → Secrets and variables → Actions** bij
`ZAD_API_KEY_DIRECTORY` (overschrijft de oude waarde). Trek de oude key **pas ná die stap** in bij de
ZAD Operations Manager — anders revoke je een key die CI nog gebruikt.

## Openstaand

- Eén key doet lezen, deployen én verwijderen. Een read-only key voor de verificatiestappen zou het
  lek-oppervlak verkleinen; of ZAD scoped keys ondersteunt is nog niet uitgezocht.
- `dirui` draagt dezelfde cert/key als `dirmgr` en authenticeert dus als de directory-peer zelf
  ([#899](https://github.com/MinBZK/MijnOverheidZakelijk/issues/899)).
- De keten onder `zad-actions` is niet volledig SHA-gepind (`setup-uv`, `zad-cli` via git-tag), en
  juist `zad-cli` krijgt de key te zien — zie [`zad-cleanup.md`](zad-cleanup.md).
