# Sleutel- en secretbeheer

> Operationele kant van secrets in dit repo: waar ze leven, wie erbij kan, en hoe je ze roteert.
> Een **kwetsbaarheid melden** doe je niet hier — daarvoor geldt het disclosurebeleid uit
> [`SECURITY.md`](../SECURITY.md).

## Wat waar staat

| Wat | Waar | Opmerking |
|-----|------|-----------|
| `ZAD_API_KEY_DIRECTORY` | **Actions**-secretstore van dit repo | Expliciet **niet** in de Dependabot-secretstore: bot-PR's horen niet met deze key te kunnen deployen. |
| `ZAD_PROJECT_ID_DIRECTORY` | Actions-variable (`vars`) | Geen geheim, wel omgevingsspecifiek. |
| Test-CA-sleutel, peer-cert/key | Buiten git, lokaal gegenereerd via `pki/` | Zie `pki/README.md`. Certs komen als ZAD-bijlage in de Operations Manager UI. |
| Env-waarden per component | Operations Manager UI | Git documenteert ze via `peers/directory/*.env.example`, maar handhaaft ze niet. |

Sleutels, certificaten en `.env`-bestanden horen niet in de repository en staan in
[`.gitignore`](../.gitignore). Let op de grens daarvan: secret-scanning met push-protection staat aan,
maar dekt **provider**-patronen (GitHub-, cloudtokens). Een connection string met wachtwoord — precies
wat `STORAGE_POSTGRES_DSN` in de env-templates voordoet — valt daarbuiten, dus `.gitignore` is voor die
klasse de enige barrière. Non-provider-patronen aanzetten vraagt org-rechten en staat nog open.

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
- Rotatie van het test-CA- en peer-certmateriaal is niet beschreven, en `pki/init-ca.sh` zet de CA-key
  op een ontwikkelaarswerkplek ([#898](https://github.com/MinBZK/MijnOverheidZakelijk/issues/898)).
- `dirui` draagt dezelfde cert/key als `dirmgr` en authenticeert dus als de directory-peer zelf
  ([#899](https://github.com/MinBZK/MijnOverheidZakelijk/issues/899)).
- De keten onder `zad-actions` is niet volledig SHA-gepind (`setup-uv`, `zad-cli` via git-tag), en
  juist `zad-cli` krijgt de key te zien — zie [`zad-cleanup.md`](zad-cleanup.md).
