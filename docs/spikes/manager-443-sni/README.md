# Spike: manager-mesh op poort 443 (plug-and-play, Docker Compose)

Bewijst dat de FSC-manager-mesh werkt op **poort 443 achter een
SNI-passthrough-router** (HAProxy, `mode tcp`) — dus **zonder** de 8443 +
MetalLB-`LoadBalancer` + schaarse publieke IPv4. Zie de redenering +
source-bewijs in [`../manager-443-sni.md`](../manager-443-sni.md).

De router hier is **HAProxy in `mode tcp`** = exact het mechanisme van de
OpenShift-router op ODCN (passthrough, routeert op SNI, termineert TLS niet).

> **Gedraaid + groen op 2026-06-25** (image `v1.43.7`): peers registreren zich bij
> de directory met `manager_address` op `:443`. De *risk-toggles* onderaan waren
> de hobbels onderweg en staan opgelost in de compose.

## Wat het opzet

- 1× PostgreSQL (3 databases), 3× `manager migrate up` (one-shot).
- 3× manager: **directory** + peer **org-a** + peer **org-b**.
- 1× HAProxy-router op 443 (SNI-passthrough).
- **Elke manager adverteert z'n mesh-endpoint op `:443`** (`SELF_ADDRESS` +
  `DIRECTORY_MANAGER_ADDRESS`). Geen 8443 in zicht.

Geen UI, geen contract nodig: de peers **dialen de directory op :443 bij
startup** (announce + sync). Lukt dat, dan is de mesh-op-443 bewezen.

## Vereisten

- Docker + Docker Compose v2.
- Een lokale **open-fsc**-checkout voor de test-PKI (keys staan niet in deze repo):

  ```bash
  git clone https://gitlab.com/rinis-oss/fsc/open-fsc
  ```

## Draaien

```bash
cd docs/spikes/manager-443-sni
cp .env.example .env
#   zet PKI_DIR=/absoluut/pad/naar/open-fsc/pki   in .env
docker compose up -d
```

## Verifiëren (groen = mesh werkt op 443)

```bash
# Peers moeten de directory op :443 bereiken en synchroniseren:
docker compose logs -f manager-org-a manager-org-b
```

**Groen:** org-a en org-b loggen succesvolle announce/synchronisatie met de
directory; geen TLS-handshake- of verbindingsfouten. Eventueel de router:

```bash
docker compose logs router    # toont TCP-sessies naar de juiste backend op SNI
```

**Extra bewijs (optioneel, peer↔peer):** open de controller-UI en maak een
contract `grant → sign → accept` tussen org-a en org-b. Dan dialt org-b de
manager van org-a op **:443**. (Controllers staan niet in deze minimale opzet —
zie risk-toggle 4.)

## Opruimen

```bash
docker compose down -v
```

Verder niets: de PKI is read-only gemount, niet gewijzigd.

---

## Troubleshooting / risk-toggles

Dingen die de auteur niet kon testen, met de fix als ze opduiken:

1. **`*.open-fsc.localhost` resolved naar 127.0.0.1.**
   Sommige libc's behandelen `.localhost` speciaal. Zien de managers daardoor de
   router niet, voeg dan aan elke manager-service een expliciete mapping toe:

   ```yaml
   extra_hosts:
     - "directory.shared.open-fsc.localhost:<router-container-ip>"
   ```

   of geef de router een vast IP via een `ipam`-config en wijs ernaar.

2. **`migrate`/`serve` not found in $PATH.** (Opgelost in de compose.)
   De image heeft geen ENTRYPOINT (`CMD ["/usr/local/bin/manager","serve"]`),
   dus elk `command` start met `/usr/local/bin/manager`. Wijkt het pad in een
   andere image-versie af, pas het aan.

3. **txlog.** Niet-directory managers eisen `TX_LOG_API_ADDRESS` (presence-check,
   `serve.go:236`). We zetten een **placeholder** — txlog wordt pas gedialed bij
   een echte data-transactie (inway/outway), niet bij announce/sync, dus de
   mesh-proof werkt zonder echte txlog. Wil je het contract-/data-pad echt
   testen, voeg dan per peer een `txlog-api`-container toe
   (`federatedserviceconnectivity/txlog-api:${IMAGE_TAG}`, eigen DB + migratie)
   en wijs `TX_LOG_API_ADDRESS` daarheen.

4. **`controller-registration-api-address` is verplicht.**
   We laten 'm weg (geen controllers in deze minimale mesh). Klaagt de manager
   over een verplichte flag, zet dan een (dummy) `CONTROLLER_REGISTRATION_API_ADDRESS`
   of voeg een controller-container per peer toe.

5. **CRL-fouten.** `DISABLE_CRL_CHECKS=true` staat al aan. Zo niet gehonoreerd
   via env, dan host je lokaal een leeg CRL-distributiepunt.

6. **Andere env-naam dan verwacht.** De env-namen komen uit
   `helm/charts/open-fsc-manager/templates/deployment.yaml` (release 1.43.7).
   Wijkt jouw image af, vergelijk met die chart-versie.
