# PKI — test-CA als trust-anchor

Gesloten testnet → **eigen test-CA**, geen PKIoverheid (zie `docs/ontwerpkeuzes.md`).

OpenFSC levert hiervoor `ca` + `ca-certportal`. Per peer is een cert nodig waarin:

- `subject.serialNumber` = de **OIN** van de peer (wordt de Peer ID);
- `subject.organization` = de **naam** van de peer.

## Te leveren (#722)

- [ ] Genereer-script voor test-CA (root) + per-peer leaf-certs (`generate-certs.sh`).
- [ ] Secrets via ZAD `attachments` (encrypted, read-only mount) — **nooit** in image bakken.
- [ ] CRL-distributie inrichten (OpenFSC heeft CRL-support).

> Sleutels/certs horen **niet** in deze repo. Alleen scripts en `.example`-templates.
