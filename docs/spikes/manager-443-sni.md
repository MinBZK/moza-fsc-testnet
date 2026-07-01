# Spike: manager-mesh op poort 443 (SNI-passthrough) i.p.v. 8443/MetalLB

> Status: **bewezen, runtime groen (2026-06-25, image `v1.43.7`).** Eerst via
> source-inspectie geretireerd (zie *Source-bewijs*), daarna end-to-end bevestigd
> met de plug-and-play compose in [`manager-443-sni/`](manager-443-sni/) (zie
> *Runtime-resultaat*).

## Runtime-resultaat (2026-06-25)

Gedraaid met `manager-443-sni/docker-compose.yml`: directory + 2 peer-managers,
alle mesh-endpoints op **:443**, HAProxy `mode tcp` als SNI-passthrough-router.

- **HAProxy routeerde op SNI**, passthrough (geen terminatie): sessies
  `mesh dir/s` voor SNI `directory.shared.open-fsc.localhost` → backend op
  `manager-directory:7501`. Bronnen = de peer-containers.
- **mTLS intact:** de directory verwerkte inkomende client-cert-handshakes van de
  peers ("skipping client certificate revocation check").
- **Announce gepersisteerd:** `peers.peers` in de directory-DB bevat alle drie
  peers, elk met `manager_address` op `:443`:

  | OIN | naam | manager_address |
  |-----|------|-----------------|
  | `…7899` | FSC (directory) | `https://directory.shared.open-fsc.localhost:443` |
  | `…7891` | RvRD (org-b) | `https://manager.organization-b.open-fsc.localhost:443` |
  | `…7890` | Gemeente Stijns (org-a) | `https://manager.organization-a.open-fsc.localhost:443` |

Conclusie: de manager-mesh draait volledig over **443 via SNI-passthrough** —
geen 8443/MetalLB-IP nodig. De drie hobbels onderweg (image-tag `v`-prefix,
`/usr/local/bin/manager` als command, verplichte `TX_LOG_API_ADDRESS`) staan
opgelost in de compose + README-toggles.

## Waarom

ZAD-vraag: de manager wil op 8443, wat een MetalLB-`LoadBalancer` met een eigen
publiek IPv4 vereist (schaarste, groeit lineair met elke nieuwe peer). Kan de
manager-mesh net als de inway via de gedeelde router op **443 met
`passthrough` + SNI**, zodat er géén dedicated IP nodig is?

## Source-bewijs (al beslist, zónder runtime)

De manager-mesh authenticeert op **OIN, niet op hostname** — dus 443 + een
willekeurige routeerhostname werkt, en de cert hoeft de hostname niet in z'n SAN
te hebben:

| Bevinding | Locatie (open-fsc) |
|-----------|--------------------|
| 443 expliciet geldig manager-poort | `manager/domain/peer/peer_new.go:71` → `validPorts := []string{"443","8443"}` |
| `SelfAddress` mag 443 of 8443 | `manager/cmd/serve.go:109` (doc-string) |
| Uitgaande mesh-dial zet `InsecureSkipVerify` | `manager/cmd/serve.go:724,753,783` |
| Enige peer-check = OIN (`Subject.SerialNumber`) | `common/tls/option.go:43` `VerifyConnStatePeerID` + `manager/adapters/manager/rest/manager.go:73,78` |
| Domeinnaam bewust niet in cert | `outway/cmd/serve.go:371` comment |
| SNI komt uit URL-hostname (Go http-client) | `outway/adapters/managerexternal/rest/manager_external.go:74-86` |
| Manager draait z'n *internal* API nu al op 443 via sni-proxy | `modd.conf:48`, `sni-proxy/sniproxy.conf` (443 → 7613) |

Conclusie: alleen het *externe* mesh-endpoint moet van 8443 naar 443; geen
PKI-wijziging nodig. De runtime-spike bevestigt enkel dat de
SNI-passthrough-router de bytes draagt (generiek, al bewezen in #720).

## Recipe (op een open-fsc dev-checkout met `go`+`docker`+`modd`+`postgres`)

Doel: één manager (org-a) adverteert z'n mesh op **443** via een eigen
SNI-hostname; bewijs dat een contract met een andere peer rondkomt.

### 1. `sni-proxy/sniproxy.conf` — voeg toe aan `table https_hosts` (listener 443)

```diff
 table https_hosts {
     directory.shared.open-fsc.localhost HOST_IP:7500
+    # spike #723: mesh-endpoint org-a op 443 (eigen SNI-host → externe listener 7614)
+    manager-mesh.organization-a.open-fsc.localhost HOST_IP:7614
```

Laat de bestaande `manager.organization-a … HOST_IP:7613` (internal, 443) en de
`8443`-tabel intact — geen collision, want andere hostname.

### 2. `modd.conf` — org-a manager (`# [A] manager`), wijzig self-address

```diff
-      --self-address https://manager.organization-a.open-fsc.localhost:8443 \
+      --self-address https://manager-mesh.organization-a.open-fsc.localhost:443 \
```

Listen-poorten (`--listen-address-external 0.0.0.0:7614`) blijven ongewijzigd —
alleen het *geadverteerde* adres verandert. Cert blijft de bestaande org-a
group-cert (hostname niet geverifieerd → SAN-mismatch maakt niet uit).

### 3. Draai de stack en verifieer

1. Start de dev-stack (sni-proxy + managers + db) zoals gebruikelijk (`modd`).
2. Laat org-a announce'n naar de directory.
3. Vanaf een andere peer: doorloop een contract `grant → sign → accept` met een
   org-a-dienst (of bevestig dat de andere manager org-a's peer/diensten uit de
   directory synct en het contract de status **accepted** bereikt).
4. **Groen** = contract komt rond + data-call (outway → inway) werkt, terwijl
   org-a's manager **uitsluitend op :443** bereikbaar is.

### Opruimen

Revert de twee diffs. Geen PKI/DB-state om op te ruimen.

## Wat dit NIET dekt (→ cluster-spike, #723)

De echte HAProxy-`passthrough`-Route op ODCN (i.p.v. de lokale sni-proxy) +
gemounte certs. Gegeven het source-bewijs + #720 (passthrough op beide poorten
bewezen) is dit laag-risico; bundel het met de directory/group-deploy. ZAD
`attachments` (cert-mount) is sinds 2026-06-29 beschikbaar.
