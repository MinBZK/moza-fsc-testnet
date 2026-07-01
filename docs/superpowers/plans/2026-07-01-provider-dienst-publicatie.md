# Plan 2 — Provider dienst-publicatie (inway + stub-upstream + publish) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Voltooi de #724-acceptatie: breid de lokale harness uit met een inway + neutrale stub-upstream en publiceer `example-service` zodat die als geldige (auto-signed) `servicePublication` vindbaar is in de directory.

**Architecture:** Fase 2 van [Spec A](../specs/2026-06-29-fsc-generiek-provider-onboarding-design.md), onboarding-flow stap 3–5. De publicatie is scriptbaar in **twee mTLS-REST-calls, zonder handmatige crypto**: (1) `POST /v1/services` op de controller Administration-API (`:9444`) maakt de dienst; (2) `POST /v1/contracts` op de **eigen** manager Internal-API (`:9443`) met een `servicePublication`-grant — de manager hasht+signt server-side, en de directory (`AUTO_SIGN_GRANTS=servicePublication`, al gezet) auto-accepteert. Een curl-`toolbox`-service in het compose-netwerk voert de calls uit (spiegelt het bestaande `exec postgres psql`-idioom). De inway registreert zich bij de controller Registration-API (`:9443`) en levert de `inway_address` voor stap 1.

**Tech Stack:** cfssl (PKI), docker-compose, haproxy (SNI-passthrough), postgres, OpenFSC `manager`/`controller`/`inway` images `v1.43.7`, `hashicorp/http-echo` (stub-upstream), `curlimages/curl` (toolbox), bash smoke-tests.

## Global Constraints

- **Peers/OINs (ongewijzigd):** directory `00000000000000000010`, example-provider `00000000000000000030`. `GROUP_ID=moza-fbs-test`.
- **Dienstnaam:** `example-service` (identiek in `publish-service.sh`, `smoke-publish.sh`, verwachte output).
- **Publicatie = twee calls, geen handmatige hash/signature.** Manager computeert content-hash + creator-signature server-side; directory auto-signt. Géén eigen sign-tooling.
- **mTLS overal op de interne API's.** `AUTHN_TYPE=none` schakelt alléén de UI-OIDC-login uit, niet de transport-mTLS. Client-cert voor de curl-calls = een internal-PKI-cert (`pki/internal/example-provider/manager/{cert,key}.pem`), geverifieerd tegen `pki/internal/example-provider/ca/root.pem`.
- **Manager-poorten:** `:9443` = internal **authenticated** (contracts + `GET /v1/peers/.../services`), `:9444` = internal **unauthenticated** (inway-verkeer), `:8443` = group-mesh. Controller: `:9443` Registration-API, `:9444` Administration-API, `:8080` UI.
- **Secrets nooit committen:** `pki/ca/`, `pki/out/`, `pki/internal/` zijn gitignored. Alleen `csr.json` + `.example`-templates + scripts committen.
- **Branch:** `feature/peer-magazijn-724`. **Commit-trailer:** elke commit eindigt met `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Taal:** Nederlands; FSC-idiomen (inway, manager, directory, peer, grant, contract) niet vertalen.
- **Out of scope (latere plannen):** outway/`example-consumer` (#725), échte data-call door de inway (#728), reële txlog-api (#728), ca-cfssl/ca-certportal (aparte Spec-A-fase), docs-herschrijven buiten `deploy/local/README.md`, ZAD-deploy (#729).

## File Structure

- `pki/peers/example-provider/controller/csr.json` (**nieuw**) — geeft de controller een eigen internal-identity (CN `controller.example-provider.fsc-test.local`) i.p.v. de manager-cert te lenen; nodig zodat inway→controller en toolbox→controller-admin op een matchende hostnaam TLS-valideren.
- `deploy/local/docker-compose.yaml` (**wijzig**) — voeg `stub-upstream`, `inway-example-provider`, `toolbox` toe; herbedraad `controller` naar eigen cert + netwerk-alias.
- `deploy/local/publish-service.sh` (**nieuw**) — idempotente onboarding: `GET /v1/inways` → `POST /v1/services` → `POST /v1/contracts` (servicePublication).
- `deploy/local/smoke-publish.sh` (**nieuw**) — draait `publish-service.sh`, pollt daarna tot `example-service` als geldige publicatie zichtbaar is via de manager Internal-API.
- `deploy/local/README.md` (**wijzig**) — documenteer inway + stub + publish-flow + smoke.

## Runtime-onzekerheden (verifieer tijdens uitvoering; deze host had geen docker)

Deze zijn met concrete fallbacks in de stappen verwerkt; markeer ze als eerste checkpoints:

1. **inway `serve`-subcommand.** Manager/controller gebruiken `[binary, serve]`. Aangenomen `[/usr/local/bin/inway, serve]`. Als de container direct de daemon draait: laat `command` weg. (Task 2, Step 2.)
2. **inway `TX_LOG_API_ADDRESS`.** De chart eist een niet-lege waarde; onbekend of de inway hem *bij boot dialt*. Plan gebruikt de placeholder `https://txlog.placeholder.invalid:7611` (zoals de manager). **Fallback als de inway hierop crasht:** voeg een reële `open-fsc-txlog-api` + DB toe (chart `helm/charts/open-fsc-txlog-api`) — dat is #728-werk; markeer #724 dan als "publicatie bewezen, txlog volgt". (Task 2, Step 4.)
3. **Interne mTLS hostname-check.** Task 1 geeft de controller een eigen cert zodat hostnamen sowieso matchen. Blijkt de check OIN-gebaseerd (hostname genegeerd), dan is Task 1 onschadelijk-maar-overbodig; niet terugdraaien.
4. **Contract-`iv`-formaat.** Research: UUID v7 (36 tekens). Plan gebruikt `cat /proc/sys/kernel/random/uuid` (UUID v4, óók 36 tekens). Als de manager `400` geeft op het iv-formaat: genereer een v7 (of vraag de manager-API-spec op). (Task 3, Step 1.)
5. **Contract-`group_id`.** Plan stuurt `moza-fbs-test` (= `GROUP_ID`). Als de manager een directory-URI verwacht: gebruik het adres uit `DIRECTORY_MANAGER_ADDRESS`. (Task 3, Step 1.)
6. **`endpoint_url`-validatie bij `POST /v1/services`.** Aangenomen: niet gedialed bij create. Zo niet: zorg dat `stub-upstream` gezond is vóór de call (staat al in `depends_on`).

---

### Task 1: Controller eigen internal-identity (PKI + compose-alias)

De controller leende de manager-internal-cert (CN `manager.example-provider.fsc-test.local`). Voor inway→controller-registratie en toolbox→controller-admin moet de controller op een **matchende hostnaam** bereikbaar zijn. Geef 'm een eigen internal-cert + netwerk-alias.

**Files:**

- Create: `pki/peers/example-provider/controller/csr.json`
- Modify: `deploy/local/docker-compose.yaml` (service `controller`)
- Test (bestaand): `pki/verify.sh`

**Interfaces:**

- Produces: internal-certs `pki/internal/example-provider/controller/{cert,key}.pem` (CN `controller.example-provider.fsc-test.local`, internal-CA `pki/internal/example-provider/ca/root.pem`); netwerk-alias `controller.example-provider.fsc-test.local`. Task 2 (inway `CONTROLLER_REGISTRATION_API_ADDRESS`) en Task 3 (toolbox admin-call) consumeren deze hostnaam.

- [ ] **Step 1: Maak de controller-CSR**

Create `pki/peers/example-provider/controller/csr.json` (OIN in lockstep met de andere example-provider-endpoints):

```json
{
  "CN": "controller.example-provider.fsc-test.local",
  "key": { "algo": "rsa", "size": 4096 },
  "hosts": ["controller.example-provider.fsc-test.local"],
  "serialnumber": "00000000000000000030",
  "names": [{ "O": "example-provider", "C": "NL" }]
}
```

- [ ] **Step 2: (Her)genereer de certs en verifieer**

Run:

```bash
cd /home/claude/projects/moza-fsc-testnet
./pki/issue.sh -f && ./pki/fix-permissions.sh && ./pki/verify.sh
```

Expected: laatste regel `== ALLE ASSERTS GROEN ==`, exit 0. Output toont nieuw `internal/example-provider/controller/cert.pem` (naast group `out/example-provider/controller/cert.pem`; die group-variant blijft ongebruikt — `issue.sh` maakt beide uit dezelfde csr.json, dat is prima).

- [ ] **Step 3: Herbedraad de controller-service in `docker-compose.yaml`**

In `deploy/local/docker-compose.yaml`, service `controller`: wijzig de drie TLS-paden van de manager- naar de controller-internal-cert, en voeg een netwerk-alias toe. Vervang deze regels:

```yaml
      TLS_ROOT_CERT: /pki/internal/example-provider/ca/root.pem
      TLS_CERT: /pki/internal/example-provider/manager/cert.pem
      TLS_KEY: /pki/internal/example-provider/manager/key.pem
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    depends_on:
      migrate-controller:
        condition: service_completed_successfully
      manager-example-provider:
        condition: service_started
```

door:

```yaml
      TLS_ROOT_CERT: /pki/internal/example-provider/ca/root.pem
      TLS_CERT: /pki/internal/example-provider/controller/cert.pem
      TLS_KEY: /pki/internal/example-provider/controller/key.pem
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    networks:
      default:
        aliases:
          - controller.example-provider.fsc-test.local
    depends_on:
      migrate-controller:
        condition: service_completed_successfully
      manager-example-provider:
        condition: service_started
```

(De controller blijft als **client** naar de manager praten via `MANAGER_ADDRESS_INTERNAL` — die cert is nu de controller-internal-cert, door dezelfde internal-CA getekend, dus de manager blijft 'm accepteren.)

- [ ] **Step 4: Commit**

```bash
git add pki/peers/example-provider/controller deploy/local/docker-compose.yaml
git commit -m "$(cat <<'EOF'
feat(local): controller eigen internal-identity + netwerk-alias (#724)

De controller leende de manager-internal-cert; voor inway->controller-registratie
en toolbox->controller-admin moet de controller op een matchende hostnaam
TLS-valideren. Eigen CSR (CN controller.example-provider.fsc-test.local) + alias.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: stub-upstream + inway + toolbox (compose)

Voeg de neutrale upstream, de inway (registreert bij de controller) en een curl-`toolbox` toe. Na deze task verschijnt de inway in `GET /v1/inways`.

**Files:**

- Modify: `deploy/local/docker-compose.yaml` (nieuwe services)
- Test: handmatige assert via `toolbox` (Step 5)

**Interfaces:**

- Consumes: controller-hostnaam + certs uit Task 1; inway-certs `pki/{out,internal}/example-provider/inway/{cert,key}.pem` (bestaan al — CSR aanwezig).
- Produces: service `inway-example-provider` (NAME `example-provider-inway`), `stub-upstream` (HTTP `:8080`), `toolbox` (curl, `/pki` gemount). Task 3 consumeert `toolbox` + de geregistreerde inway-naam.

- [ ] **Step 1: Voeg `stub-upstream` toe**

In `deploy/local/docker-compose.yaml`, onder `services:` (neutrale echo die `berichtenmagazijn` vervangt):

```yaml
  stub-upstream:
    # Neutrale HTTP-echo die de business-app vervangt (Spec A). Wordt de endpoint_url
    # van example-service; in #724 niet gedialed (data-pad = #728).
    image: docker.io/hashicorp/http-echo:1.0
    command: ["-listen=:8080", "-text=hello from example-provider stub-upstream (#724)"]
```

- [ ] **Step 2: Voeg `inway-example-provider` toe**

Direct na `manager-example-provider`. **Verifieer eerst runtime-onzekerheid 1 (`serve`-subcommand) en 2 (txlog).**

```yaml
  inway-example-provider:
    image: docker.io/federatedserviceconnectivity/inway:${IMAGE_TAG:-v1.43.7}
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"   # host-UID -> leest 0600-keys
    restart: on-failure                            # boot-race met controller/manager
    command:
      - /usr/local/bin/inway
      - serve
    environment:
      LOG_TYPE: local
      LOG_LEVEL: debug
      GROUP_ID: moza-fbs-test
      NAME: example-provider-inway                 # = inway_address in CreateService
      SELF_ADDRESS: https://inway.example-provider.fsc-test.local:443
      LISTEN_ADDRESS: 0.0.0.0:8443
      MONITORING_ADDRESS: 0.0.0.0:8081
      DISABLE_CRL_CHECKS: "true"
      # Registreert zich bij de controller (eigen hostnaam uit Task 1):
      CONTROLLER_REGISTRATION_API_ADDRESS: https://controller.example-provider.fsc-test.local:9443
      # Eigen manager, internal-unauthenticated poort:
      MANAGER_INTERNAL_UNAUTHENTICATED_ADDRESS: https://manager.example-provider.fsc-test.local:9444
      # Presence-check (chart eist niet-leeg); zie runtime-onzekerheid 2:
      TX_LOG_API_ADDRESS: https://txlog.placeholder.invalid:7611
      TLS_ROOT_CERT: /pki/internal/example-provider/ca/root.pem
      TLS_CERT: /pki/internal/example-provider/inway/cert.pem
      TLS_KEY: /pki/internal/example-provider/inway/key.pem
      TLS_GROUP_ROOT_CERT: /pki/ca/root.pem
      TLS_GROUP_CERT: /pki/out/example-provider/inway/cert.pem
      TLS_GROUP_KEY: /pki/out/example-provider/inway/key.pem
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    networks:
      default:
        aliases:
          - inway.example-provider.fsc-test.local
    depends_on:
      controller:
        condition: service_started
      manager-example-provider:
        condition: service_started
      stub-upstream:
        condition: service_started
```

- [ ] **Step 3: Voeg `toolbox` toe (curl-client op het netwerk)**

Spiegelt het `exec postgres psql`-idioom: een langdraaiende container met curl + `/pki`, waar de smoke `exec`t.

```yaml
  toolbox:
    # Curl-client BINNEN het netwerk voor de mTLS-onboarding-calls (Task 3).
    # Draait als host-UID zodat het de 0600-internal-key leest.
    image: docker.io/curlimages/curl:8.11.1
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    entrypoint: ["sleep", "infinity"]
    volumes:
      - "${PKI_DIR:?zet PKI_DIR in .env}:/pki:ro"
    depends_on:
      manager-example-provider:
        condition: service_started
      controller:
        condition: service_started
```

- [ ] **Step 4: Breng de stack op en verifieer dat de inway niet crasht (txlog-checkpoint)**

Run:

```bash
cd deploy/local && docker compose up -d --build; cd -
docker compose -f deploy/local/docker-compose.yaml ps
docker compose -f deploy/local/docker-compose.yaml logs --tail=40 inway-example-provider
```

Expected: `inway-example-provider` blijft `running` (niet in restart-loop). Ziet de log herhaald `TX_LOG`/`dial txlog … refused` fatals? → runtime-onzekerheid 2 geraakt: voeg een reële `open-fsc-txlog-api` toe (fallback) of descope publicatie-txlog naar #728.

- [ ] **Step 5: Verifieer dat de inway zich registreerde bij de controller**

Run (via de toolbox; internal client-cert; controller-admin op eigen hostnaam):

```bash
docker compose -f deploy/local/docker-compose.yaml exec -T toolbox \
  curl -s --cert /pki/internal/example-provider/manager/cert.pem \
          --key  /pki/internal/example-provider/manager/key.pem \
          --cacert /pki/internal/example-provider/ca/root.pem \
       https://controller.example-provider.fsc-test.local:9444/v1/inways
```

Expected: JSON met een inway waarvan de naam/adres `example-provider-inway` is. Leeg/`[]` → inway niet geregistreerd: check Step 4-logs (mTLS-fout naar de controller = cert/hostnaam; zie Task 1).

- [ ] **Step 6: Ruim op en commit**

```bash
cd deploy/local && docker compose down -v; cd -
git add deploy/local/docker-compose.yaml
git commit -m "$(cat <<'EOF'
feat(local): inway + stub-upstream + curl-toolbox in de harness (#724)

inway registreert bij de controller Registration-API en krijgt een group- en
internal-cert; stub-upstream = neutrale HTTP-echo als endpoint_url; toolbox =
curl-client op het netwerk voor de mTLS-onboarding-calls (Task 3).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Dienst aanmaken + publiceren + smoke

Twee mTLS-calls maken en publiceren `example-service`; de smoke pollt tot de publicatie geldig-en-vindbaar is via de manager Internal-API.

**Files:**

- Create: `deploy/local/publish-service.sh`
- Create: `deploy/local/smoke-publish.sh`
- Test: `deploy/local/smoke-publish.sh`

**Interfaces:**

- Consumes: `toolbox`, geregistreerde inway (Task 2), controller-hostnaam (Task 1), directory `AUTO_SIGN_GRANTS=servicePublication` (al gezet op `manager-directory`).
- Produces: dienst `example-service` gepubliceerd; smoke-exitcode 0 bij vindbaarheid.

- [ ] **Step 1: Schrijf `publish-service.sh` (idempotente onboarding)**

Create `deploy/local/publish-service.sh`:

```bash
#!/usr/bin/env bash
# Onboarding (#724): maakt example-service aan op de controller Administration-API en
# publiceert 'm via een servicePublication-contract op de eigen manager Internal-API.
# Idempotent: slaat create/publish over als ze er al zijn. Manager hasht+signt het
# contract server-side; de directory (AUTO_SIGN_GRANTS=servicePublication) auto-accept.
set -euo pipefail

COMPOSE=(docker compose -f "$(dirname "$0")/docker-compose.yaml")
SERVICE_NAME="example-service"
PROVIDER_OIN="00000000000000000030"
DIR_OIN="00000000000000000010"
GROUP_ID="moza-fbs-test"                 # zie runtime-onzekerheid 5
STUB_URL="http://stub-upstream:8080"

CERT=/pki/internal/example-provider/manager/cert.pem
KEY=/pki/internal/example-provider/manager/key.pem
CA=/pki/internal/example-provider/ca/root.pem
CONTROLLER=https://controller.example-provider.fsc-test.local:9444
MANAGER=https://manager.example-provider.fsc-test.local:9443

# curl binnen de toolbox, met de internal client-cert.
tb() { "${COMPOSE[@]}" exec -T toolbox curl -s --fail-with-body \
         --cert "$CERT" --key "$KEY" --cacert "$CA" "$@"; }

echo "publish: inway-adres ophalen..."
INWAY_ADDR=$(tb "$CONTROLLER/v1/inways" | grep -o '"[^"]*example-provider-inway[^"]*"' | head -1 | tr -d '"')
[ -n "$INWAY_ADDR" ] || { echo "FAIL: geen geregistreerde inway op de controller." >&2; exit 1; }
echo "  inway_address=$INWAY_ADDR"

echo "publish: example-service aanmaken (idempotent)..."
if tb "$CONTROLLER/v1/services" | grep -q "\"$SERVICE_NAME\""; then
  echo "  bestaat al, skip create."
else
  tb -X POST "$CONTROLLER/v1/services" -H 'Content-Type: application/json' \
     -d "{\"name\":\"$SERVICE_NAME\",\"endpoint_url\":\"$STUB_URL\",\"inway_address\":\"$INWAY_ADDR\"}"
  echo "  aangemaakt."
fi

echo "publish: servicePublication-contract indienen (idempotent)..."
if tb "$MANAGER/v1/services/publications" | grep -q "\"$SERVICE_NAME\""; then
  echo "  al gepubliceerd, skip contract."
else
  IV=$("${COMPOSE[@]}" exec -T toolbox cat /proc/sys/kernel/random/uuid)   # 36 tekens; zie onzekerheid 4
  NBF=$("${COMPOSE[@]}" exec -T toolbox date -u +%s)
  NAF=$((NBF + 315360000))                                                 # +10 jaar
  tb -X POST "$MANAGER/v1/contracts" -H 'Content-Type: application/json' -d "{
    \"contract_content\": {
      \"iv\": \"$IV\",
      \"group_id\": \"$GROUP_ID\",
      \"hash_algorithm\": \"HASH_ALGORITHM_SHA3_512\",
      \"created_at\": $NBF,
      \"validity\": { \"not_before\": $((NBF - 60)), \"not_after\": $NAF },
      \"grants\": [ {
        \"type\": \"GRANT_TYPE_SERVICE_PUBLICATION\",
        \"directory\": { \"peer_id\": \"$DIR_OIN\" },
        \"service\": { \"peer_id\": \"$PROVIDER_OIN\", \"name\": \"$SERVICE_NAME\", \"protocol\": \"PROTOCOL_TCP_HTTP_1.1\" }
      } ]
    }
  }"
  echo "  contract ingediend (manager signt; directory auto-accept)."
fi
echo "publish: klaar."
```

- [ ] **Step 2: Schrijf `smoke-publish.sh` (draait onboarding, pollt vindbaarheid)**

Create `deploy/local/smoke-publish.sh`:

```bash
#!/usr/bin/env bash
# Smoke (#724): bewijst dat example-service gepubliceerd is en als GELDIGE publicatie
# vindbaar is bij de directory. Draait eerst de onboarding, pollt daarna de manager
# Internal-API (GET /v1/peers/{dir}/services) tot example-service verschijnt.
set -euo pipefail

HERE="$(dirname "$0")"
COMPOSE=(docker compose -f "$HERE/docker-compose.yaml")
SERVICE_NAME="example-service"
PROVIDER_OIN="00000000000000000030"
DIR_OIN="00000000000000000010"
TIMEOUT=120; INTERVAL=5

CERT=/pki/internal/example-provider/manager/cert.pem
KEY=/pki/internal/example-provider/manager/key.pem
CA=/pki/internal/example-provider/ca/root.pem
MANAGER=https://manager.example-provider.fsc-test.local:9443

echo "smoke-publish: onboarding draaien..."
bash "$HERE/publish-service.sh"

echo "smoke-publish: pollen tot $SERVICE_NAME vindbaar is bij de directory..."
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  out=$("${COMPOSE[@]}" exec -T toolbox curl -s \
          --cert "$CERT" --key "$KEY" --cacert "$CA" \
          "$MANAGER/v1/peers/$DIR_OIN/services?peer_id=$PROVIDER_OIN" || true)
  if printf '%s' "$out" | grep -q "\"$SERVICE_NAME\""; then
    echo "OK: $SERVICE_NAME is gepubliceerd en vindbaar in de directory."
    printf '%s\n' "$out"
    exit 0
  fi
  sleep "$INTERVAL"; elapsed=$((elapsed + INTERVAL))
  echo "  ...nog niet vindbaar (${elapsed}s)"
done

echo "FAIL: $SERVICE_NAME niet vindbaar binnen ${TIMEOUT}s." >&2
echo "Debug: publicaties (eigen manager) + inways + logs:" >&2
"${COMPOSE[@]}" exec -T toolbox curl -s --cert "$CERT" --key "$KEY" --cacert "$CA" \
   "$MANAGER/v1/services/publications" >&2 || true
"${COMPOSE[@]}" logs --tail=50 manager-example-provider manager-directory inway-example-provider >&2 || true
exit 1
```

- [ ] **Step 3: Maak de scripts uitvoerbaar**

Run:

```bash
chmod +x deploy/local/publish-service.sh deploy/local/smoke-publish.sh
```

- [ ] **Step 4: Draai de volledige flow (announce + publish) groen**

Run:

```bash
cd deploy/local && docker compose down -v && docker compose up -d --build; cd -
./deploy/local/smoke-announce.sh      # bestaand: announce groen
./deploy/local/smoke-publish.sh       # nieuw: dienst gepubliceerd + vindbaar
```

Expected: `smoke-announce.sh` → `OK: example-provider is aangemeld …`, exit 0. `smoke-publish.sh` → `OK: example-service is gepubliceerd en vindbaar …`, exit 0. Bij `400` op het contract: raadpleeg runtime-onzekerheid 4/5 en pas `iv`/`group_id` aan.

- [ ] **Step 5: Ruim op en commit**

```bash
cd deploy/local && docker compose down -v; cd -
git add deploy/local/publish-service.sh deploy/local/smoke-publish.sh
git commit -m "$(cat <<'EOF'
feat(local): example-service aanmaken + publiceren + smoke (#724)

publish-service.sh: idempotente onboarding via twee mTLS-calls (CreateService op
controller-admin :9444, servicePublication-contract op manager-internal :9443).
smoke-publish.sh: pollt de manager Internal-API tot de dienst als geldige
publicatie bij de directory vindbaar is. Manager signt server-side; directory
auto-accept (AUTO_SIGN_GRANTS=servicePublication).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Harness-README bijwerken

Documenteer de nieuwe componenten + publish-flow in `deploy/local/README.md`.

**Files:**

- Modify: `deploy/local/README.md`
- Test: `markdownlint`

- [ ] **Step 1: Voeg een publish-stap toe aan het draaiboek**

In `deploy/local/README.md`, na stap 5 (announce-smoke), voeg toe:

```markdown
# 6. Bewijs de dienst-publicatie (maakt example-service aan + publiceert + pollt
#    tot die geldig vindbaar is bij de directory).
./deploy/local/smoke-publish.sh   # verwacht: "OK: example-service is gepubliceerd en vindbaar" + exit 0
```

- [ ] **Step 2: Beschrijf de nieuwe componenten**

Voeg onder "Beheer-UI"-sectie een korte alinea toe:

```markdown
## Provider-onboarding (Fase D, #724) — inway + dienst publiceren

Na stap 4 draaien ook:

- **inway-example-provider**: registreert zich bij de controller en levert de ingress
  vóór `stub-upstream`. In `GET /v1/inways` verschijnt `example-provider-inway`.
- **stub-upstream**: neutrale HTTP-echo (`hashicorp/http-echo`) die de business-app
  vervangt; wordt de `endpoint_url` van `example-service`. De échte data-call door de
  inway is #728.
- **toolbox**: curl-client op het netwerk voor de twee mTLS-onboarding-calls.

`smoke-publish.sh` maakt `example-service` aan (controller Administration-API `:9444`)
en publiceert 'm met één `servicePublication`-contract (manager Internal-API `:9443`);
de manager signt server-side en de directory auto-accept (`AUTO_SIGN_GRANTS`). De dienst
is daarna zichtbaar in de directory-ui (`http://localhost:8080`).
```

- [ ] **Step 3: Lint + commit**

```bash
npx --yes markdownlint-cli2 deploy/local/README.md
git add deploy/local/README.md
git commit -m "$(cat <<'EOF'
docs(local): documenteer inway + dienst-publicatie in de harness-README (#724)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec-dekking (Spec A → dit plan):** dekt onboarding-flow stap 3 (CreateService, Task 3), stap 4 (ServicePublicationGrant, Task 3), stap 5 (vindbaar, `smoke-publish.sh`), plus de vereiste componenten inway + stub-upstream (Task 2). #724-acceptatie "manager + inway + controller + stub-upstream + DB draaien / announce / CreateService / gepubliceerd / vindbaar / lokaal bewezen" is gedekt. **Bewust uitgesteld:** ca-cfssl/ca-certportal (aparte Spec-A-fase), reële txlog (#728), data-call door de inway (#728), outway/consumer (#725), ZAD (#729), docs buiten de harness-README.

**Placeholder-scan:** geen "TBD"/"later" in stappen. De zes "runtime-onzekerheden" zijn géén plan-gaten maar expliciete verificatie-checkpoints mét concrete fallback (deze host had geen docker; het compose draait op de laptop/CI). Elke stap heeft concreet commando/inhoud.

**Type-/naam-consistentie:** `example-service`, OIN `…030`/`…010`, `example-provider-inway`, hostnamen `controller.example-provider.fsc-test.local` (Task 1 → Task 2/3), cert-paden `pki/internal/example-provider/{manager,controller,inway}/…` en `pki/out/example-provider/inway/…` consistent over Task 1–3. Poorten `:9443` (manager internal-auth + controller registration), `:9444` (manager internal-unauth + controller admin), `:8443` (mesh/inway-data) consistent met `docker-compose.yaml` en de Global Constraints.

**Open punt (genoteerd):** als runtime-onzekerheid 2 (inway-txlog) een reële txlog-api afdwingt, groeit de scope met een txlog-component + DB; splits dat dan af naar #728 en markeer #724 als "publicatie bewezen, txlog volgt".
