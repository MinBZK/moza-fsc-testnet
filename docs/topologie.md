# Topologie

```text
                         ┌─────────────────────────┐
                         │   directory (+ manager)  │   group: moza-fbs-test
                         │   trust-anchor: test-CA  │
                         └────────────▲─────────────┘
                       announce       │       announce
              ┌─────────────────┐     │     ┌─────────────────┐
              │  magazijn-org    │    │    │  uitvraag-org    │
              │  manager :8443   │◀───┴───▶│  manager :8443   │   (management-mesh, mTLS)
              │  inway   :443    │         │  outway          │
              │   └▶ berichten-  │         │   └▶ berichten-  │
              │      magazijn    │         │      uitvraag    │
              └──────────────────┘         └──────────────────┘
                       ▲   data (443, mTLS, passthrough op SNI)   │
                       └──────────────────────────────────────────┘
```

- Elke peer = eigen **ZAD-project** (project-isolatie, zoals bestaande FBS-deploy.yml).
- Data-pad: `berichtenuitvraag` → lokale **outway** → **inway** magazijn-org → `berichtenmagazijn`.
- FBS-integratie is **config-only**: de `Magazijnregister`-URL (`magazijnen."<OIN>".url`) wijst
  naar de lokale outway i.p.v. direct op het magazijn (#726).
- Management-pad (8443): managers wisselen contracten/peers/tokens uit.
- Beheer-pad (HTTP-UI): elke peer draait een **controller** (dienst publiceren, afnemer-toegang
  aanvragen, contracten beheren); de directory host **directory-ui** (gedeelde dienstencatalogus).
  Via edge-Route, geen 8443-mesh — zie `docs/ontwerpkeuzes.md` (#723/#727).

## Schaal-aandachtspunt (8443-IP-schaarste, #720/#723)

Houd het aantal 8443-endpoints klein. Voorkeur: één manager per project/peer; deel publieke IP's
waar mogelijk. 443 schaalt wél via gedeeld router-IP + SNI.
