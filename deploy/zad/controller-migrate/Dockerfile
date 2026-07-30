# Dunne wrapper boven de stock OpenFSC-controller: migreer-dan-serve in één image,
# zodat ZAD (nog geen args/init-containers) toch kan migreren. Geen broncode-fork.
#
# De stock-image is DISTROLESS (geen /bin/sh), dus:
#  - we enten een statische busybox als /bin/sh in, zodat het shell-entrypoint draait;
#  - perms via COPY --chmod (geen RUN — RUN heeft zelf een shell nodig die er niet is).
# Base-image digest-gepind (Scorecard Pinned-Dependencies): bij `repo:tag@digest` resolvet
# Docker op de digest en wordt de tag niet gevalideerd, dus een los ARG IMAGE_TAG zou hier
# feitelijk niets doen. Bij een versie-bump: deze regel én de workflow-default IMAGE_TAG
# (voor de output-tag) samen updaten.
FROM busybox:1.36.1-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213 AS busybox

FROM docker.io/federatedserviceconnectivity/controller:v1.43.7@sha256:d51af2347bffb4a0d028de41ef50fd2dbf3b5fa7ebfe698cada75ea4a21dfb99
COPY --from=busybox /bin/busybox /bin/sh
COPY --chmod=0555 entrypoint.sh /usr/local/bin/migrate-and-serve.sh
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
