# Contract-bootstrap (#727)

Idempotent script dat na deploy een geldig contract opzet tussen consumer en provider.

Stappen (FSC Manager API, OpenFSC):

1. Consumer maakt een **ServiceConnectionGrant** en ondertekent → `POST /contracts` naar de
   manager van de provider.
2. Provider accepteert → `PUT /contracts/{hash}/accept`.
3. Verifieer: token verkrijgbaar (`POST /token`, client_credentials, scope=GrantHash).

> Te implementeren als `bootstrap.sh`. Moet her-draaibaar zijn (bestaand geldig contract = no-op).
