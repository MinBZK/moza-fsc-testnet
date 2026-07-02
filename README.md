# moza-fsc-testnet

Gedeelde **FSC-testomgeving** (Federated Service Connectivity) op ZAD, waarmee MijnOverheid-Zakelijk-teams federatieve, beveiligde dienstverlening kunnen beproeven. Begonnen voor de FBS-Berichtenbox-PoC, maar **generiek**: elk team sluit aan als eigen *peer*.

> Story: [MinBZK/MijnOverheidZakelijk#661](https://github.com/MinBZK/MijnOverheidZakelijk/issues/661)

## Wat dit wel/niet is

- **Geen** fork van de FSC-software. Dit is een **deploy- en configuratie-repo** die de
  [OpenFSC](https://gitlab.com/rinis-oss/fsc/open-fsc) reference implementation (manager, inway,
  outway, directory) consumeert via haar container-images en Helm-charts.
- **Wel**: onze test-CA, group-/peer-configuratie, ZAD-deploy-workflows en contract-bootstrap.

## Topologie

Eén **group** + één **directory** + N **peers** (organisaties). Voor de PoC:

| Peer | Rol | FSC-componenten | OIN (PeerID) |
|------|-----|-----------------|--------------|
| directory | groep-anker | directory + manager | `00000000000000000010` (synth.) |
| magazijn-a | provider | manager + inway → `berichtenmagazijn` | `00000001003214345000` |
| magazijn-b | provider | manager + inway → `berichtenmagazijn` | `00000001823288444000` |
| uitvraag-org | consumer | manager + outway → `berichtenuitvraag` | `00000000000000000020` (synth.) |
| profiel-org | (later) | manager + inway → `moza-profiel-service` | `<OIN>` |

Zie [`docs/topologie.md`](docs/topologie.md), [`docs/ontwerpkeuzes.md`](docs/ontwerpkeuzes.md)
en [`docs/zad-projecten.md`](docs/zad-projecten.md) (projectverdeling + deploymodel).

## Mappenstructuur

```text
docs/        ontwerp: topologie + keuzes
pki/         test-CA als trust-anchor + cert-generatie
group/       group-id, trust-anchor, group rules (TLS)
peers/       per peer: Helm-values + OIN + adressen
contracts/   grant → sign → accept bootstrap
.github/     ZAD deploy/cleanup workflows
```

## Bijdragen & verantwoording

- **Bijdragen:** nooit direct naar `main`; werk via een `feature/`-, `fix/`- of
  `chore/`-branch en een pull request. De hoofdbranch is beschermd (review + CI verplicht).
- **Disclaimer:** dit is een experimentele PoC, grotendeels met AI opgesteld — zie
  [`DISCLAIMER.md`](DISCLAIMER.md) en de volledige
  [AI-verantwoording](docs/ai-verantwoording.md).
- **Governance / support / security:** [`GOVERNANCE.md`](GOVERNANCE.md) ·
  [`SUPPORT.md`](SUPPORT.md) · [`SECURITY.md`](SECURITY.md) (delegeren naar de MOZa-hoofdrepo).
- **Metadata:** [`publiccode.yml`](publiccode.yml). **Licentie:** [EUPL-1.2](LICENSE).
- **CI:** lint (markdown/YAML/workflows), CodeQL en OpenSSF Scorecard draaien op elke PR.

## Status

Skelet (#721). Volgende stappen: #722 PKI · #723 directory+group · #724/#725 peers
· #726 FBS-integratie · #727 contracten · #728 e2e · #729 CI · #730 profiel-peer.
