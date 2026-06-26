# Dunne wrapper boven de stock OpenFSC-manager: migreer-dan-serve in één image,
# zodat ZAD (geen args/init-containers) toch kan migreren. Geen broncode-fork.
ARG IMAGE_TAG=v1.43.7
FROM docker.io/federatedserviceconnectivity/manager:${IMAGE_TAG}
COPY entrypoint.sh /usr/local/bin/migrate-and-serve.sh
# Stock-image draait als non-root; entrypoint moet leesbaar+executable zijn.
USER root
RUN chmod 0555 /usr/local/bin/migrate-and-serve.sh
USER 1000
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
