# Topologie

```text
                         ┌─────────────────────────┐
                         │   directory (+ manager)  │   group: moza-fbs-test
                         │   trust-anchor: test-CA  │
                         └────────────▲─────────────┘
                       announce       │       announce
              ┌─────────────────┐     │     ┌─────────────────┐
              │ magazijn-a / -b  │    │    │  uitvraag-org    │
              │  manager :8443   │◀───┴───▶│  manager :8443   │   (management-mesh, mTLS)
              │  inway   :443    │         │  outway          │
              │   └▶ berichten-  │         │   └▶ berichten-  │
              │      magazijn    │         │      uitvraag    │
              └──────────────────┘         └──────────────────┘
                       ▲   data (443, mTLS, passthrough op SNI)   │
                       └──────────────────────────────────────────┘
```

- Elke peer = eigen **ZAD-project** (project-isolatie, zoals bestaande FBS-deploy.yml).
- Data-pad: `berichtenuitvraag` → lokale **outway** → **inway** magazijn (A of B) → `berichtenmagazijn`.
- Twee magazijn-peers: **magazijn-a** (OIN `00000001003214345000`) en **magazijn-b** (`00000001823288444000`),
  elk eigen ZAD-project. OIN's overgenomen uit moza-poc-fbs-berichtenbox.
- FBS-integratie is **config-only**: de `Magazijnregister`-URL (`magazijnen."<OIN>".url`) wijst
  naar de lokale outway i.p.v. direct op het magazijn (#726).
- Management-pad (8443): managers wisselen contracten/peers/tokens uit.

## Schaal-aandachtspunt (8443-IP-schaarste, #720/#723)

Houd het aantal 8443-endpoints klein. Voorkeur: één manager per project/peer; deel publieke IP's
waar mogelijk. 443 schaalt wél via gedeeld router-IP + SNI.
