# Dunne wrapper boven de stock OpenFSC-txlog-api: migreer-dan-serve in één image,
# zodat ZAD (nog geen args/init-containers) toch kan migreren. Geen broncode-fork.
#
# De stock-image is DISTROLESS (geen /bin/sh), dus:
#  - we enten een statische busybox als /bin/sh in, zodat het shell-entrypoint draait;
#  - perms via COPY --chmod (geen RUN — RUN heeft zelf een shell nodig die er niet is).
# Base-images digest-gepind (Scorecard Pinned-Dependencies). De digest fixeert de inhoud;
# IMAGE_TAG (default v1.43.7) blijft de zichtbare + output-tag. Bij een versie-bump:
# IMAGE_TAG én de txlog-api-digest hieronder samen updaten.
ARG IMAGE_TAG=v1.43.7
FROM busybox:1.36.1-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213 AS busybox

FROM docker.io/federatedserviceconnectivity/txlog-api:${IMAGE_TAG}@sha256:5faca432973c37a4e9a890c1dd0f03a888fa9305abcafb59e9e7b57ca2140ad5
COPY --from=busybox /bin/busybox /bin/sh
COPY --chmod=0555 entrypoint.sh /usr/local/bin/migrate-and-serve.sh
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
