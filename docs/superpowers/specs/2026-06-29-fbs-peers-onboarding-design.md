# Spec B — FBS-peers aansluiten op de federatie (repo `moza-poc-fbs-berichtenbox`)

> Status: ontwerp (#724/#725, FBS-deel). Dit werk hoort thuis in
> **`moza-poc-fbs-berichtenbox`** (de app-repo), niet in `moza-fsc-testnet`.
> Deze spec wordt bij start van dat werk naar repo B verplaatst/gekopieerd.
> Gerelateerd: [Spec A](2026-06-29-fsc-generiek-provider-onboarding-design.md) (generieke
> infra), epic [#737](https://github.com/MinBZK/MijnOverheidZakelijk/issues/737).

## Aanleiding

`moza-fsc-testnet` levert de generieke FSC-infra (directory + group + CA + cert-portal) en
een generieke peer-template (Spec A). De FBS-PoC moet zich als **consument van die infra**
aansluiten: het magazijn als aanbiedende organisatie (provider/inway), de uitvraag als
afnemende organisatie (consumer/outway). Die peers draaien co-located met de FBS-app
(intra-project DNS) in `moza-poc-fbs-berichtenbox`, niet in het infra-repo.

Eerder stond deze FBS-config (echte OINs, `berichtenmagazijn`-upstream) in `moza-fsc-testnet`;
die wordt daar verwijderd (Spec A) en hier opnieuw opgezet volgens de generieke template.

## Gewenst resultaat

1. **Magazijn-provider-peer** draait bij de FBS-app: manager + inway + controller + DB,
   met de echte magazijn-OIN, en publiceert `berichtenmagazijn` als dienst in de directory
   (#724-FBS-deel).
2. **Uitvraag-consumer-peer** draait bij de FBS-app: manager + outway + controller + DB,
   met de uitvraag-OIN (#725-FBS-deel).
3. Beide peers verkrijgen hun group-cert via het cert-portal van de centrale infra.
4. `berichtenuitvraag` routeert magazijn-calls via de lokale outway (config-only:
   `Magazijnregister`-URL → outway), i.p.v. direct (#726).

## Niet in scope (hier)

- De generieke infra zelf (directory/group/CA/cert-portal) → Spec A, repo A.
- De reusable deploy-workflow die repo A levert → #729 (repo A).
- E2e-verantwoording/logging → #728 (deels hier, deels repo A).

## Bekende FBS-parameters (uit het oude repo A)

| Peer | Rol | OIN | Endpoints | Upstream |
|------|-----|-----|-----------|----------|
| magazijn-a | provider | `00000001003214345000` (echt) | manager, inway | `berichtenmagazijn-deployment:8090` |
| magazijn-b | provider | `00000001823288444000` (echt) | manager, inway | `berichtenmagazijn-deployment:8090` |
| uitvraag-org | consumer | `00000000000000000020` (synthetisch) | manager, outway | n.v.t. (outway = egress) |

OIN-provenance magazijn-a: `services/berichtenuitvraag/.../application.properties` in dit
repo (B). OIN = afzender-`magazijnId`, 1:1 met Peer ID.

## Architectuur

Spiegelt OpenFSC `helm/deploy/<org>/`. Per peer een eigen ZAD-project (project-isolatie),
co-located met de app voor intra-project DNS.

### Provider-peer (magazijn)

| Component | Rol |
|-----------|-----|
| manager | announce + ServicePublicationGrant |
| controller | dienst `berichtenmagazijn` aanmaken (Administration-API) + beheer-UI |
| inway | ingress vóór `berichtenmagazijn-deployment` (intra-project DNS, koppelteken) |
| postgres | peer-DB |

### Consumer-peer (uitvraag)

| Component | Rol |
|-----------|-----|
| manager | announce + ServiceConnectionGrant (contract met provider, #727) |
| controller | afnemer-toegang beheren |
| outway | egress; `berichtenuitvraag` roept de outway intern aan |
| postgres | peer-DB |

### Onboarding-flow per peer

1. **Cert** — peer vraagt group-cert aan via cert-portal van repo A (gecontroleerde stap).
2. **Deploy** — peer-componenten naast de app in het ZAD-project (consumeert repo A's
   generieke template/componentlijst; deploy-mechanisme via #729).
3. **Announce** — manager meldt zich bij de directory.
4. **Provider publiceert** — controller `CreateService(berichtenmagazijn, <inway-upstream>)`
   → ServicePublicationGrant → directory auto-signt → dienst vindbaar.
5. **Consumer verbindt** — ServiceConnectionGrant → provider accepteert (contract, #727) →
   token → outway kan de dienst afnemen.

### FBS-app-integratie (#726, config-only)

`berichtenuitvraag` wijst de `Magazijnregister`-URL (`magazijnen."<OIN>".url`) naar de lokale
outway i.p.v. direct naar het magazijn. Geen code-wijziging in de uitwissellogica.

## Afhankelijkheden

- **Repo A af** (Spec A): generieke template + cert-portal beschikbaar, directory draait.
- **#729**: deploy-mechanisme (reusable workflow / componentlijst) om de peer naast de app
  te deployen. Tot die er is: lokaal bewijzen (compose), ZAD volgt.
- **ZAD `attachments`**: cert-mount **beschikbaar sinds 2026-06-29** (niet langer een blocker).
- **#727**: contract-bootstrap voor de consumer↔provider-toegang.

## Testen / acceptatie

- Magazijn-peer announce't + `berichtenmagazijn` vindbaar in directory (#724-FBS).
- Uitvraag-peer announce't (#725-FBS).
- `berichtenuitvraag` → outway → inway → `berichtenmagazijn` end-to-end (#726/#728).
- Bestaande FBS-app-tests blijven groen (config-only-wijziging).

## #737-herziening (titel-prefixes)

De issues #724/#725/#726 krijgen een `[FBS]`/`[FSC][FBS]`-titel-prefix; #727/#728 worden
gesplitst (mechanisme A / FBS-toepassing B). Zie Spec A voor de prefix-aanpak
(`[FSC]`/`[FBS]`/`[PROFIEL]`). Toegepast op 2026-06-29.

## Open punten

- **Branch in repo B** nog te starten; deze spec verhuist daarheen.
- **magazijn-b**: nodig in eerste ronde of pas later? #724 spreekt over "eerste aanbiedende
  organisatie" (één magazijn volstaat voor het bewijs). magazijn-b = uitbreiding.
- **Echte OINs in een publiek repo**: bevestigen dat de magazijn-OINs in `moza-poc-fbs-berichtenbox`
  mogen staan (ze stonden al in dat repo's `application.properties`).
