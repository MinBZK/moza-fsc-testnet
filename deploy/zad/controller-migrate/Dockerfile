# Dunne wrapper boven de stock OpenFSC-controller: migreer-dan-serve in één image,
# zodat ZAD (nog geen args/init-containers) toch kan migreren. Geen broncode-fork.
#
# De stock-image is DISTROLESS (geen /bin/sh), dus:
#  - we enten een statische busybox als /bin/sh in, zodat het shell-entrypoint draait;
#  - perms via COPY --chmod (geen RUN — RUN heeft zelf een shell nodig die er niet is).
# Base-image digest-gepind (Scorecard Pinned-Dependencies): bij `repo:tag@digest` resolvet
# Docker op de digest en wordt de tag niet gevalideerd, dus een los ARG IMAGE_TAG zou hier
# feitelijk niets doen. Alle OpenFSC-componenten releasen in lockstep en moeten óók in lockstep
# draaien; de tag hieronder hoort dus gelijk te zijn aan die van de andere wrappers, de
# workflow-defaults en de lokale compose. `.github/scripts/check-openfsc-version.sh` (lint-workflow)
# faalt als dat uiteenloopt — een halve bump wordt niet groen.
FROM busybox:1.36.1-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213 AS busybox

FROM docker.io/federatedserviceconnectivity/controller:v2.5.2@sha256:e03e07e6e6afbdea386b1210cd6ffb678c46fcda89897b9b0f5b0814db5b01bc
COPY --from=busybox /bin/busybox /bin/sh
COPY --chmod=0555 entrypoint.sh /usr/local/bin/migrate-and-serve.sh
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
