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
