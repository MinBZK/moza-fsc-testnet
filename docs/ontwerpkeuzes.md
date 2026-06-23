# Ontwerpkeuzes

## Implementatie: OpenFSC

We gebruiken [OpenFSC](https://gitlab.com/rinis-oss/fsc/open-fsc) (EUPL-1.2), de reference
implementation van de [FSC Core-standaard](https://gitdocumentatie.logius.nl/publicatie/fsc/core/)
(voorheen `fsc-nlx`, nu onderhouden door RINIS). Levert manager, inway, outway, directory,
ca-certportal en sni-proxy als containers + Helm-charts.

Afgewogen alternatieven: Logius `fsc-test-suite` (= conformance-tests, geen draaibaar netwerk —
optioneel later als poort) en zelf bouwen (te veel werk voor een PoC).

### Relevante OpenFSC-implementatiekeuzes (overgenomen)

- **Peer ID = geldige OIN**, afgeleid uit `subject.serialNumber` van het X.509-cert.
- **Peer-naam** uit `subject.organization`.
- Logging-extensie **verplicht**; CRL-ondersteuning ingebouwd.
- TLS conform NCSC-richtlijn TLS 2.1.

> **Aansluiting op FBS:** in FBS ís het `magazijnId` al de afzender-OIN. Dat valt 1:1 samen
> met de FSC Peer ID — de OIN↔PeerID-mapping (#726) is daarmee triviaal.

## Trust-anchor: eigen test-CA, géén PKIoverheid

We draaien een **gesloten testnet**, dus de group zet een **eigen test-CA** als trust-anchor
(zoals OpenFSC lokaal ook doet). PKIoverheid is alleen vereist bij aansluiting op de
**productie-overheidsfederatie** — buiten scope. Zelf-ondertekende certs zijn direct beschikbaar
en vermijden levertijd/IP-schaarste. Besluit bevestigd in #720.

## ZAD / OpenShift (uit #720, GO)

- **mTLS-passthrough bewezen** op het ODCN-prod-cluster, beide poorten, eigen cert.
- Poort **443** (data, Outway→Inway): OpenShift Route met `passthrough`. Schaalt — gedeeld
  router-IP, routering op **SNI**-hostnaam. Elke inway krijgt een eigen, stabiele SNI-hostnaam.
- Poort **8443** (management, Manager-mesh): MetalLB `LoadBalancer` met eigen publiek IP.
  **Schaars** → minimaliseer managers (~1 per project/peer), deel IP's waar mogelijk.
- `edge`/`reencrypt` of client-cert-in-header **breken** de certificate-binding — verboden.

### Openstaande ZAD-dependency

ZAD heeft (nog) geen cert-upload. Er komt een generiek `attachments`-blok (encrypted opslag,
read-only mount in de pod). Nodig vóór #722/#723 live kunnen.
