# Dunne wrapper boven de stock OpenFSC-controller: migreer-dan-serve in één image,
# zodat ZAD (nog geen args/init-containers) toch kan migreren. Geen broncode-fork.
#
# De stock-image is DISTROLESS (geen /bin/sh), dus:
#  - we enten een statische busybox als /bin/sh in, zodat het shell-entrypoint draait;
#  - perms via COPY --chmod (geen RUN — RUN heeft zelf een shell nodig die er niet is).
# Base-images digest-gepind (Scorecard Pinned-Dependencies). De digest fixeert de inhoud;
# IMAGE_TAG (default v1.43.7) blijft de zichtbare + output-tag. Bij een versie-bump:
# IMAGE_TAG én de controller-digest hieronder samen updaten.
ARG IMAGE_TAG=v1.43.7
FROM busybox:1.36.1-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213 AS busybox

FROM docker.io/federatedserviceconnectivity/controller:${IMAGE_TAG}@sha256:d51af2347bffb4a0d028de41ef50fd2dbf3b5fa7ebfe698cada75ea4a21dfb99
COPY --from=busybox /bin/busybox /bin/sh
COPY --chmod=0555 entrypoint.sh /usr/local/bin/migrate-and-serve.sh
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
