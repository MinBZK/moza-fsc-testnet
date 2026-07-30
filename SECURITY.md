# Beveiliging / Security

Deze repository maakt deel uit van het [MijnOverheid Zakelijk (MOZa)](https://github.com/MinBZK/MijnOverheidZakelijk) project.

## Kwetsbaarheid melden / Reporting a vulnerability

Meld een (vermoedelijke) kwetsbaarheid **niet** via een openbare issue. Volg het
verantwoorde-disclosurebeleid van de hoofdrepository: zie
[SECURITY.md](https://github.com/MinBZK/MijnOverheidZakelijk/blob/main/SECURITY.md)
in MijnOverheidZakelijk.

## Scope

Dit is een **gesloten testnet** met een eigen test-CA: er draait geen productiedata en er zijn geen
PKIoverheid-certificaten in gebruik. Dat is relevant voor de impactbeoordeling van een melding, niet
een reden om iets niet te melden.

Het operationele secretbeheer (waar keys staan, hoe je ze roteert) staat in
[`docs/sleutelbeheer.md`](docs/sleutelbeheer.md).
