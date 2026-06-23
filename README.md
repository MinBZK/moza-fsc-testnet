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
| directory | groep-anker | directory + manager | n.v.t. |
| magazijn-org | provider | manager + inway → `berichtenmagazijn` | `<afzender-OIN>` |
| uitvraag-org | consumer | manager + outway → `berichtenuitvraag` | `<OIN>` |
| profiel-org | (later) | manager + inway → `moza-profiel-service` | `<OIN>` |

Zie [`docs/topologie.md`](docs/topologie.md) en [`docs/ontwerpkeuzes.md`](docs/ontwerpkeuzes.md).

## Mappenstructuur

```
docs/        ontwerp: topologie + keuzes
pki/         test-CA als trust-anchor + cert-generatie
group/       group-id, trust-anchor, group rules (TLS)
peers/       per peer: Helm-values + OIN + adressen
contracts/   grant → sign → accept bootstrap
.github/     ZAD deploy/cleanup workflows
```

## Status

Skelet (#721). Volgende stappen: #722 PKI · #723 directory+group · #724/#725 peers ·
#726 FBS-integratie · #727 contracten · #728 e2e · #729 CI · #730 profiel-peer.
