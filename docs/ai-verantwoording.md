# Verantwoording inzet van generatieve AI in de FSC-testomgeving

> Verantwoording i.h.k.v. het Overheidsbreed Standpunt Generatieve AI, getoetst aan het stappenplan uit de bijbehorende handreiking.

Dit document verantwoordt het gebruik van generatieve AI bij het opzetten van deze
Proof of Concept (PoC). Voor een beknopte samenvatting, zie
[`DISCLAIMER.md`](../DISCLAIMER.md).

## Beschrijving van de PoC en de rol van AI

Deze repository is een **deploy- en configuratie-repo** voor een gedeelde
FSC-testomgeving (Federated Service Connectivity) binnen MijnOverheid Zakelijk
(MOZa). Het is **geen** fork van FSC-software: ze consumeert de
[OpenFSC](https://gitlab.com/rinis-oss/fsc/open-fsc) reference implementation. Zie
de [`README.md`](../README.md) voor de actuele opzet en onderdelen.

**Rol van AI.** Hier wordt **geen applicatiecode ontwikkeld.** De FSC-software zelf
(OpenFSC) wordt niet door ons gebouwd of geforkt — we draaien er een *instantie* van.
Deze repository bevat uitsluitend configuratie (group-/peer-config, Helm-values),
scripts (PKI, contract-bootstrap), deploy-workflows en documentatie. Die zijn
grotendeels opgesteld met de AI-assistant Claude Code (Anthropic). Architectuur- en
ontwerpbeslissingen zijn vastgelegd in [`docs/ontwerpkeuzes.md`](ontwerpkeuzes.md),
[`docs/topologie.md`](topologie.md) en [`docs/zad-projecten.md`](zad-projecten.md)
en zijn menselijk genomen.

**Menselijke review.** Omdat er geen grote codebase is maar een overzichtelijke set
configuratie/scripts/docs, wordt **alles wat hier staat volledig menselijk bekeken
en gereviewd** — er is geen steekproef of afbakening nodig zoals bij een
applicatie-repo. Review loopt via de pull-request-workflow; de hoofdbranch is
beschermd (review verplicht, geen directe pushes). De mens blijft
eindverantwoordelijk; de AI is een hulpmiddel.

**Gegevens.** De PoC verwerkt geen persoonsgegevens. Er wordt uitsluitend gewerkt
met fictieve en testgegevens; de federatie gebruikt een **eigen test-CA**, geen
PKIoverheid en geen productiegegevens.

**Scope-grens.** Deze verantwoording betreft uitsluitend de PoC/testomgeving.
Aansluiting op de productie-overheidsfederatie of gebruik in productie valt
**buiten de huidige scope** en vereist aanvullende toetsing, waaronder een
beoordeling tegen de BIO (Baseline Informatiebeveiliging Overheid) en, indien van
toepassing, een DPIA (Data Protection Impact Assessment).

## Verantwoording per stappenplan

Hieronder volgen we het globale stappenplan uit hoofdstuk 4 van de
[Overheidsbrede handreiking verantwoorde inzet van generatieve AI](https://open.overheid.nl/documenten/9c273b71-cebb-4e11-b06f-fa20f7b4b90e/file).

### 1) Doel en toepassingsgebied

De PoC heeft een breder doel dan alleen AI: we beproeven het Federatief
Berichtenstelsel (FBS) en de federatieve, beveiligde dienstverlening tussen
MOZa-teams via FSC. Dit document beperkt zich tot het AI-aspect daarvan.

*Doel (AI-aspect):* onderzoeken of we verantwoord met behulp van generatieve AI
een testomgeving kunnen opzetten en configureren, en of het resultaat aantoonbaar
in lijn te brengen is met de standaarden, kaders en richtlijnen van de Nederlandse
overheid (o.a. FSC Core, Digikoppeling, NCSC TLS-richtlijn), mede met behulp van
de [overheidsskills](https://github.com/developer-overheid-nl/skills-marketplace).

*Toepassingsgebied:* het opzetten en beheren van deze experimentele
testomgeving. Niet in scope: gebruik in pilot of productie.

### 2) Zorg voor de juiste mensen en vaardigheden

De betrokken ontwikkelaars zijn niet op voorhand expert van alle betrokken
standaarden. Een onderdeel van de PoC is juist om praktisch kennis van FSC en de
bijbehorende standaarden op te bouwen door iets te bouwen, en om mede met behulp
van de [overheidsskills](https://github.com/developer-overheid-nl/skills-marketplace)
te borgen dat het resultaat eraan voldoet. AI wordt ingezet als gereedschap onder
menselijke regie. We streven ernaar betrokken partijen — waaronder beheerders en
experts van de relevante standaarden — te laten meekijken.

### 3) Creëer een (generatieve) AI-governance structuur

Het werk gebeurt in opdracht van het Ministerie van Binnenlandse Zaken en
Koninkrijksrelaties (BZK). Als beleidsmatige leidraad gelden het
[Overheidsbreed standpunt voor de inzet van generatieve AI](https://open.overheid.nl/documenten/bc03ce31-0cf1-4946-9c94-e934a62ebe73/file)
en de bijbehorende
[handreiking](https://open.overheid.nl/documenten/9c273b71-cebb-4e11-b06f-fa20f7b4b90e/file).

Concrete governance-maatregelen:

- Met AI gegenereerde bijdragen zijn herkenbaar gemarkeerd via de commit-trailer
  `Co-Authored-By`.
- Wijzigingen worden menselijk gereviewd via de pull-request-workflow vóór merge;
  de hoofdbranch is beschermd.
- Voor maximale transparantie is de repository openbaar en onder een open licentie
  ([EUPL-1.2](../LICENSE)); reageren kan via GitHub-issues.

### 4) Risicoanalyse

De gangbare assessment-instrumenten gaan er doorgaans van uit dat een organisatie
zelf een AI-systeem bouwt of structureel inzet. Dat is hier niet het geval: we
gebruiken een AI-assistant als gereedschap, bouwen zelf geen AI-systeem, nemen
niets in productie en verwerken geen persoonsgegevens. Dit beperkt de
gebruikelijke AI-risico's (zoals bias en ethische risico's). De volgende
aandachtspunten blijven relevant.

#### a. Voldoen aan de EU AI-verordening

Wij maken geen AI-systeem maar gebruiken Claude Code als gereedschap. De
verplichtingen vallen primair op de aanbieder (Anthropic). Anthropic is
ondertekenaar van de
[General Purpose AI Code of Practice](https://digital-strategy.ec.europa.eu/en/policies/contents-code-gpai)
van de EU. We houden bij welke AI-assistant en modellen we gebruiken en markeren
de met AI gegenereerde output als zodanig.

#### b. AVG en DPIA

De PoC verwerkt geen persoonsgegevens; er wordt uitsluitend met fictieve/testdata
en een eigen test-CA gewerkt. Organisaties die deze configuratie later in een
pilot of productie zouden gebruiken, dienen op dat moment zelf te beoordelen welke
AVG-verplichtingen van toepassing zijn, waaronder een eventuele DPIA.

#### c. BIO en beveiligingseisen

Voor experimentele PoC-configuratie die niet in productie gaat, gelden geen
BIO-verplichtingen. Wel kent het project basismaatregelen: OpenSSF Scorecard,
CodeQL-analyse van de workflows, secret-scanning met push-protection, het
**nooit committen van secrets** (sleutels/certs blijven buiten git), en
SHA- of versie-gepinde GitHub Actions. Gebruik in pilot of productie vereist een
volledige toetsing aan de geldende beveiligingseisen.

#### d. Datadeling met de AI-aanbieder

Het risico op datadeling wordt beperkt doordat geen vertrouwelijke gegevens of
persoonsgegevens worden gebruikt, en doordat in de instellingen van de
AI-assistant is gekozen voor de opt-out voor modeltraining.

#### e. Risico op "schijnzekerheid"

Het inzetten van AI is geen compliance-garantie. De officiële brondocumenten
(zoals de FSC Core-specificatie en de OpenFSC-documentatie) zijn altijd leidend.
Het team blijft zelf verantwoordelijk voor het voldoen aan standaarden en
richtlijnen. AI is slechts een hulpmiddel.

#### f. Kwaliteitsrisico: onjuiste of onveilige gegenereerde configuratie

De kwaliteit wordt op meerdere niveaus geborgd: **volledige menselijke review van
alles wat hier staat** (geen applicatiecode, dus geen steekproef nodig),
geautomatiseerde CI-controles (markdown-/YAML-/workflow-linting, CodeQL, Scorecard)
en het toetsen van de configuratie tegen de officiële OpenFSC-charts en de
FSC Core-specificatie. De FSC-software zelf is OpenFSC en wordt door RINIS
onderhouden; wij beoordelen onze instantie-configuratie, niet die software.

#### g. Auteursrecht op brondocumenten als input

Per gebruikte standaard of bron wordt gecontroleerd of deze als input voor een
AI-assistant gebruikt mag worden. Brondocumentatie wordt vermeld, met
bijbehorende licentie-informatie waar nodig (OpenFSC is EUPL-1.2).

#### h. Uitlegbaarheid / gevaar op "black box"

De gegenereerde configuratie en de ontwerpkeuzes zijn openbaar en in voor mensen
leesbare vorm gepubliceerd. Ontwerpbeslissingen worden vastgelegd in
[`docs/ontwerpkeuzes.md`](ontwerpkeuzes.md).

#### i. AI-geletterdheid van betrokken medewerkers

Kennis over de inzet van AI-assistants wordt binnen het team gedeeld; deze
verantwoording wordt openbaar gepubliceerd.

### 5) Generatieve AI inkopen of bouwen

#### a. Vendor lock-in

Op dit moment wordt uitsluitend Claude Code gebruikt. Dat is een expliciet
aandachtspunt voor een eventueel vervolg. De opgeleverde configuratie zelf is
leverancier-onafhankelijk (OpenFSC, Helm, GitHub Actions) en kent geen
runtime-afhankelijkheid van een AI-aanbieder; een andere AI-assistant kan in een
vervolg worden ingezet.

#### b. Keuze voor de AI-assistant

In deze PoC is gekozen voor Claude Code (Anthropic), een aanbieder die de EU
General Purpose AI Code of Practice heeft ondertekend.
