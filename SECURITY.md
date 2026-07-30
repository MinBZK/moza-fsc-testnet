# Beveiliging / Security

Deze repository maakt deel uit van het [MijnOverheid Zakelijk (MOZa)](https://github.com/MinBZK/MijnOverheidZakelijk) project.

## Kwetsbaarheid melden / Reporting a vulnerability

Meld een (vermoedelijke) kwetsbaarheid **niet** via een openbare issue. Volg het
verantwoorde-disclosurebeleid van de hoofdrepository: zie
[SECURITY.md](https://github.com/MinBZK/MijnOverheidZakelijk/blob/main/SECURITY.md)
in MijnOverheidZakelijk.

## Secrets

Dit is een **gesloten testnet** met een eigen test-CA. Sleutels, certificaten en
`.env`-bestanden horen **niet** in deze repository en staan in
[`.gitignore`](.gitignore). Alleen scripts en `.example`-templates worden
ingecheckt. Secret-scanning met push-protection staat aan op de repository.

### Sleutelrotatie `ZAD_API_KEY_DIRECTORY`

Roteer periodiek, bij een vermoeden van lekkage, of wanneer een teamlid met toegang vertrekt.

Deze key staat in de **Actions**-secretstore van dit repo — expliciet **niet** (meer) in de
Dependabot-secretstore. Verifieer een nieuwe key **read-only**, niet door `zad-deploy-directory`
handmatig te draaien — dat deployt standaard `test` op het productiecluster. Doe in plaats daarvan
een read-only API-call met de nieuwe key (zie `docs/zad-directory-deploy.md`, stap 6):

```bash
read -rs ZAD_API_KEY; export ZAD_API_KEY     # plak de key niet inline
curl -sS -o /dev/null -w '%{http_code}\n' -H "X-API-Key: $ZAD_API_KEY" \
  https://zad.rijksapp.nl/api/v2/projects/mft-tp9/deployments
```

Dit print alléén de statuscode: `200` = de nieuwe key werkt, `401` = niet. Wil je ook de namen zien
(`| jq -r '.deployments[]?.name'`), gebruik dan die `?` — `deployments` mag legitiem ontbreken omdat
het endpoint alleen deployments van het huidige cluster teruggeeft (zie `docs/zad-cleanup.md`,
"Verificatie = drie calls"). Een lege namenlijst is dus géén bewijs dat de key stuk is; de
statuscode is dat wel — vandaar dat de check hierboven op de code kijkt. Zet de nieuwe key daarna in
**Settings → Secrets and variables → Actions** bij `ZAD_API_KEY_DIRECTORY` (overschrijft de oude
waarde). Trek de oude key **pas ná die stap** in bij de ZAD Operations Manager — anders revoke je
een key die CI nog gebruikt.
