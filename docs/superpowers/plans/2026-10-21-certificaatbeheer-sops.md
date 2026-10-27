# Certificaatbeheer testfederatie met SOPS + age — Implementatieplan

**Status:** fase 1 en 2 uitgevoerd in MinBZK/moza-fsc-testnet#78; fase 3 open.

**Issue:** [MinBZK/MijnOverheidZakelijk#992](https://github.com/MinBZK/MijnOverheidZakelijk/issues/992),
raakt ook [#898](https://github.com/MinBZK/MijnOverheidZakelijk/issues/898) (rotatie van CA- en
peer-certmateriaal).

**Goal:** Elke ontwikkelaar met toegang kan het certificaatmateriaal van de testfederatie zelfstandig
ophalen en vernieuwen, zonder de federatie stil te breken. Van elke set in gebruik is zichtbaar waar hij
staat, wie erbij kan en tot wanneer hij geldig is, en een naderend verloop meldt zich vooraf.

**Besluit:** optie A uit het refinement-voorstel: privésleutels versleuteld met SOPS + age in een
private repo, met twee aanvullingen: de openbare helft in git met een wekelijkse verloopcontrole, en een
ankercontrole tegen een zelfgemaakte CA.

## Context

- De group-root en -intermediate komen uit `pki/` in deze repo. `moza-poc-fbs-berichtenbox` heeft per
  peer (`logius`, `magazijn-a`) een kopie in `demo/environment/<peer>/pki/ca/`. Alle drie hebben dezelfde
  root (SHA-256 `EB:EE:D6:0B:…:9B:C0`, geldig tot 2041). De leafs in de berichtenbox lopen tot
  augustus 2029.
- Het materiaal staat nu op één werkplek. In alle drie de `ca/`-mappen staat óók `root-key.pem`.
- `.gitignore` sluit hier alle `*.pem`/`*.crl` uit en de mappen `pki/ca/`, `pki/out/`, `pki/internal/`
  en `pki/zad-upload/` als geheel. Git kan een bestand onder een uitgesloten map niet terug-insluiten,
  dus voor de openbare helft moeten de map-regels naar bestandsniveau.
- `init-ca.sh` hier overschrijft een bestaande CA zonder vragen. De berichtenbox-kopie weigert al
  zonder `-f`.
- Uploaden naar ZAD (bijlagen, publicatie met passthrough-TLS) kan alleen via de UI
  (`docs/spikes/zad-attachments.md`). Daarom is git de plek die bijhoudt wat er live staat.

## Ontwerp

### Openbaar en geheim

| Bestand | Soort | Plek |
|---|---|---|
| `pki/ca/root.pem`, `pki/ca/intermediate.pem`, `pki/ca/intermediate.crl` | openbaar | git (deze repo) |
| `pki/out/<peer>/<endpoint>/cert.pem` | openbaar | git |
| `pki/internal/<peer>/ca/root.pem`, `pki/internal/<peer>/<endpoint>/cert.pem` | openbaar | git |
| `pki/ca/intermediate-key.pem` | geheim, dagelijks | geheime repo, `groep/` |
| `pki/out/<peer>/<endpoint>/key.pem` | geheim, dagelijks | geheime repo, `<peer>/group/` |
| `pki/internal/<peer>/ca/root-key.pem`, `…/<endpoint>/key.pem` | geheim, dagelijks | geheime repo, `<peer>/internal/` |
| `pki/ca/root-key.pem` | geheim, alleen bij vervangen intermediate | geheime repo, `groep/root/`, eigen ontvangers |

`combined.pem` en `zad-upload/` blijven afgeleid en gitignored: ze bevatten sleutels en zijn met de
scripts altijd opnieuw te bouwen.

### De geheime repo

Eén private repo voor de hele federatie, bijvoorbeeld `MinBZK/moza-fsc-testnet-geheimen`. Peers uit
beide repo's (`directory`, `example-*` hier; `logius`, `magazijn-a` in de berichtenbox) krijgen er elk
een map. Opbouw:

```text
groep/intermediate-key.pem
groep/root/root-key.pem  eigen creation_rule: alleen de twee aangewezen personen
<peer>/group/<endpoint>-key.pem
<peer>/internal/ca-key.pem
<peer>/internal/<endpoint>-key.pem
```

Elk bestand is één met `sops --input-type binary` versleutelde PEM. Eén bestand per sleutel spiegelt de
`pki/`-indeling 1:1, maakt ophalen en opslaan een lus zonder yq, en laat group en internal los van elkaar
roteren. Toegang per persoon staat in `pki/.sops.yaml` in déze repo, met de naam bij elke sleutel; de
geschiedenis van dat bestand laat zien wie wanneer toegang kreeg. Het staat niet in de geheime repo:
die valt onder het gratis GitHub-abonnement, zonder branch protection, en een nieuwe ontvanger hoort
via een gereviewde PR te lopen.

De root-sleutel komt in dezelfde repo, maar via een aparte `creation_rule` alleen versleuteld voor twee
aangewezen personen. Dan is hij herleidbaar bewaard zonder dat de dagelijkse ontvangers hem kunnen
openen. (Beslispunt, zie onder.)

### Scripts in `pki/`

- **`geheimen.sh ophalen|opslaan|wis [groep|<peer>…]`**. Leest de checkout van de geheime repo uit
  `FSC_GEHEIMEN_DIR`.
  - `ophalen` ontsleutelt naar de bekende paden onder `pki/`, maakt mappen `700` en bestanden `600`, en
    draait daarna `verify.sh`.
  - `opslaan` versleutelt de sleutels terug. Het weigert zolang `verify.sh` niet groen is, zodat er
    nooit een sleutel wordt opgeslagen die niet bij zijn cert past.
  - `wis` verwijdert alle ontsleutelde sleutels lokaal (runbook-stap 6).
  - `groep/root/` haalt het alleen op als het expliciet gevraagd wordt (`ophalen root`).
- **Ankercontrole**, als functie die `issue.sh`, `verify.sh` en `geheimen.sh` delen:
  - `pki/ca/root.pem` moet gelijk zijn aan de versie in `HEAD` (`git diff --quiet HEAD -- …`). Een
    lokaal vervangen anker valt zo meteen op, met een melding die naar het runbook wijst.
  - De publieke sleutel van `intermediate-key.pem` moet gelijk zijn aan die van `intermediate.pem`, en
    `intermediate.pem` moet ketenen naar `root.pem`.
  - Per peer moet de internal-CA-sleutel passen bij de gecommitte `internal/<peer>/ca/root.pem`. Zo
    geeft `issue.sh -f` niet stil een nieuwe internal-root uit terwijl de draaiende pods de oude
    vertrouwen.
- **`init-ca.sh`** weigert zodra `pki/ca/root.pem` in git staat, en ook als er lokaal een CA staat
  zonder `-f` (zelfde guard als in de berichtenbox).
- **`verify.sh`** assert 5 (geen secrets voor git) kijkt alleen nog naar sleutelbestanden en niet meer
  naar elke `.pem`.

### Verloopcontrole

- Script `.github/scripts/check-cert-verloop.sh [dagen]` loopt over alle gecommitte certificaten
  (`openssl x509 -checkend`) en over de `nextUpdate` van de CRL. Uitvoer: per bestand de einddatum, en
  exit 1 als iets binnen de termijn verloopt. Regressietest ernaast: `check-cert-verloop.test.sh`, met
  certs van één dag en certs van tien jaar die in een tijdelijke map worden gemaakt.
- Workflow `cert-verloop.yml`: elke maandag plus `workflow_dispatch`, `permissions: issues: write`.
  Ziet hij een verloop, dan maakt hij een issue in deze repo, of werkt een bestaand open issue bij,
  zodat een tweede run geen duplicaat oplevert. Geen geheimen nodig.
- Dezelfde check draait in `lint.yml` met termijn 0, zodat er geen verlopen cert in een PR terechtkomt.

### Documentatie

- `docs/sleutelbeheer.md`: de rij "Test-CA-sleutel, peer-cert/key" wordt de nieuwe indeling. Een nieuwe
  sectie "Certificaten vernieuwen" bevat het runbook. Het openstaande punt over #898 vervalt.
- `pki/README.md`: de gebruik-sectie begint met `geheimen.sh ophalen`, niet met `init-ca.sh`.
- Het runbook (criterium 4) staat in `docs/sleutelbeheer.md` ("Certificaten vernieuwen"). Anders dan
  eerst gedacht komen opslaan en de PR vóór het plaatsen in ZAD, en wordt pas na de merge gepusht en
  geplaatst: anders lopen git, de geheime repo en ZAD uit de pas.
- Toegang geven of intrekken: age-sleutel aan `.sops.yaml` toevoegen en `sops updatekeys` over alle
  bestanden. Bij vertrek: verwijderen en `updatekeys`. Opnieuw versleutelen helpt niet tegen een kopie
  die al bestaat; wanneer het anker daarom om moet, staat bij de beslispunten.

## Stappen

### Fase 0 — buiten de repo (team)

- [x] Beslispunten hieronder vastleggen in #992.
- [x] Private repo `MinBZK/moza-fsc-testnet-geheimen` aanmaken (org-rechten).
- [x] Iedere ontvanger maakt een age-sleutelpaar (`age-keygen`) en levert de publieke sleutel aan.
- [x] `pki/.sops.yaml` vullen, via een PR in deze repo.

### Fase 1 — deze repo (PR 1)

- [x] `.gitignore`: de mapregels voor `pki/ca|out|internal` vervangen door negaties per openbaar
      bestand. `*.pem` blijft globaal uitgesloten en vangt zo de sleutels. Controleren met
      `git check-ignore -v` op elk sleutel- en certpad.
- [x] `pki/lib/anker.sh` (gedeelde functie), aanroepen vanuit `issue.sh` en `verify.sh`.
- [x] Guard in `init-ca.sh`.
- [x] `pki/geheimen.sh`.
- [x] `.github/scripts/check-cert-verloop.sh` + `.test.sh`, `cert-verloop.yml`, aanhaken in `lint.yml`.
- [x] Docs: `docs/sleutelbeheer.md`, `pki/README.md`.
- [x] shellcheck, actionlint, yamllint en markdownlint schoon.

### Fase 2 — eerste vulling (vanaf de werkplek met het materiaal)

- [x] Nieuwe CRL uitgeven met `gen-crl.sh`: de huidige verliep op 8 juli 2026 en de lint-guard laat
      een verlopen CRL niet in git.
- [ ] De nieuwe CRL na de merge als bijlage in ZAD plaatsen.
- [x] Openbare helft en `pki/.sops.yaml` committen in PR 1. Eerst, want `opslaan` eist een groene
      `verify.sh`, en die eist het anker in HEAD. PR 1 merget pas mét de openbare helft: zonder anker
      in git is `verify.sh` rood en valt de lokale harness om.
- [x] `geheimen.sh opslaan groep directory example-consumer example-provider`, en `opslaan root`,
      daarna de geheime repo pushen. `example-provider-2` is niet in gebruik en vervalt.
- [x] De eerste root-houder haalt op de eigen laptop op, ook `ophalen root`. Pas dan is bewezen dat
      de root-sleutel uit de geheime repo terugkomt.
- [x] ericwout-overheid als ontvanger en tweede root-houder in `pki/.sops.yaml`; daarna draait de eerste
      root-houder `geheimen.sh ontvangers` en `ontvangers root` en pusht de geheime repo.
- [ ] Een tweede ontwikkelaar haalt op een schone checkout op, draait `verify.sh` en geeft voor één
      endpoint opnieuw uit zonder de koppeling te breken. Dat is criterium 1, en de acceptatietest.
- [ ] `root-key.pem` en `intermediate-key.pem` van de laptop verwijderen, ook uit de kopieën in de
      berichtenbox. `.DS_Store` in `pki/out/` opruimen.
- [x] De Claude-sandbox van de eerste vulling: het materiaal van deze repo, elke kopie van de root- en
      intermediate-sleutel (ook in de tars) en zijn age-sleutel zijn weg.
- [ ] Ook de peer-sleutels van de berichtenbox (`logius`, `magazijn-a`, `uitvraag-org`) uit de sandbox
      halen, zodra ze in de geheime repo staan of op de laptop zijn veiliggesteld.

### Fase 3 — moza-poc-fbs-berichtenbox (PR 2, daar)

- [ ] `geheimen.sh`, de ankercontrole en de verloopcontrole overnemen voor `demo/environment/<peer>/pki/`.
      Het `ca/` van elke peer komt uit `groep/` van dezelfde geheime repo, niet uit een eigen kopie.
- [ ] `.gitignore` (regels 53-56) en `verify.sh` assert 5 aanpassen zoals hier.
- [ ] `logius` en `magazijn-a` in de geheime repo zetten en de openbare helft committen.
- [ ] `deploy/zad/README.md` en `pki/README.md` per peer laten verwijzen naar het runbook hier.
- [ ] `federatie/deel-groep-ca.sh` doorlopen: kopieert hij nog een CA die nu al uit `groep/` komt?

### Afwijkingen bij de uitvoering van fase 1

- `.sops.yaml` staat in deze repo (`pki/.sops.yaml`) en `ONTVANGERS.md` vervalt; zie "De geheime repo".
- `geheimen.sh` heeft een vierde actie, `ontvangers`: die draait `sops updatekeys` met de juiste config
  en paden. `ophalen` overschrijft geen afwijkende lokale sleutel, `wis` gooit geen niet-opgeslagen
  sleutel weg (beide met `-f` wel), en `opslaan` versleutelt een ongewijzigde sleutel niet opnieuw.
- `verify.sh` legt ook elke leaf-sleutel naast zijn cert. Dat maakt de belofte van `opslaan` waar, en
  vangt een vervangen sleutel in de geheime repo.
- `issue.sh` vervangt nooit een gecommitte internal-root, ook niet met `-f`.
- `gen-crl.sh` gaf de CRL twaalf uur in plaats van vijf jaar (cfssl rekent in seconden); hersteld.
- De lokale harness (`deploy/local/`) haalt alleen de sleutels van zijn eigen peers op, in plaats van
  een eigen CA te maken; `--regen-certs` is vervallen.
- `issue.sh` slaat een endpoint met cert over, ook als de sleutel niet is opgehaald: zo raakt het
  vernieuwen van één peer de andere niet.
- `.gitignore` is een allowlist voor `pki/ca|out|internal`, en `verify.sh` zoekt op inhoud (index,
  HEAD en ongetrackte bestanden) en op naam naar sleutels.
- `geheimen.sh` weigert de root-sleutel als de root-regel in `pki/.sops.yaml` niet matcht (sops legt
  `path_regex` op het absolute pad), en `ontvangers` werkt alle bestanden in de geheime repo bij.
- `pki/pki.test.sh` toetst alle guards en draait in `lint.yml`, met cfssl, sops en age gepind op
  sha256.

## Beslispunten (besloten op 27 oktober 2026, vast te leggen in #992)

| Punt | Besluit |
|---|---|
| Naam geheime repo | `MinBZK/moza-fsc-testnet-geheimen`, één repo voor de hele federatie |
| Root-sleutel | in de geheime repo onder een eigen `creation_rule`, alleen voor de twee root-houders: mreuvekamp en ericwout-overheid |
| Ontvangers | mreuvekamp en ericwout-overheid; één age-sleutel per persoon, geen gedeelde sleutel en geen sleutel voor een Claude-sandbox |
| Termijn verloopwaarschuwing | 30 dagen |
| Issue bij verloop | in `moza-fsc-testnet` (de standaard-token kan geen issue in een andere repo maken) |
| Bij vertrek van een ontvanger | ontvanger eruit, `geheimen.sh ontvangers`, GitHub-toegang weg; het restrisico accepteren en vastleggen. Een nieuw anker bij vermoeden van misbruik, een gelekte sleutel, vertrek in onmin of zodra er echte gegevens doorheen gaan. Alleen de intermediate vervangen sluit niet af: de oude blijft naar de root ketenen en de CRL-controle staat uit. |

## Buiten scope

- De sleutelketen van het stelselregister (`demo/environment/stelselregister/pki/` in de berichtenbox):
  een aparte keten voor ondertekening met een eigen rotatieverhaal.
- Automatisch uploaden naar ZAD: de API ondersteunt dat niet.
- De overige punten uit #898 (scoped API-key, pinning van `zad-cli`).

## Verificatie

- `git check-ignore` bevestigt dat elk `*key.pem`-pad uitgesloten is en elk openbaar pad niet.
- `verify.sh` is groen na `ophalen` op een schone checkout, en rood (met een runbook-verwijzing) als
  lokaal materiaal niet op het anker in git aansluit; `init-ca.sh` weigert zodra dat anker er is.
- `check-cert-verloop.test.sh` is groen. Een handmatige `workflow_dispatch` met termijn 2000 dagen maakt
  precies één issue aan, en een tweede run maakt er geen tweede bij.
- De acceptatietest door een tweede ontwikkelaar uit fase 2.
