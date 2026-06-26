# Dunne wrapper boven de stock OpenFSC-manager: migreer-dan-serve in één image,
# zodat ZAD (geen args/init-containers) toch kan migreren. Geen broncode-fork.
#
# De stock-image is DISTROLESS (geen /bin/sh), dus:
#  - we enten een statische busybox als /bin/sh in, zodat het shell-entrypoint draait;
#  - perms via COPY --chmod (geen RUN — RUN heeft zelf een shell nodig die er niet is).
ARG IMAGE_TAG=v1.43.7
FROM busybox:1.36.1-musl AS busybox

FROM docker.io/federatedserviceconnectivity/manager:${IMAGE_TAG}
COPY --from=busybox /bin/busybox /bin/sh
COPY --chmod=0555 entrypoint.sh /usr/local/bin/migrate-and-serve.sh
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
