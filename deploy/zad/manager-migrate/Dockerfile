# Dunne wrapper boven de stock OpenFSC-manager: migreer-dan-serve in één image,
# zodat ZAD (nog geen args/init-containers) toch kan migreren. Geen broncode-fork.
#
# De stock-image is DISTROLESS (geen /bin/sh), dus:
#  - we enten een statische busybox als /bin/sh in, zodat het shell-entrypoint draait;
#  - perms via COPY --chmod (geen RUN — RUN heeft zelf een shell nodig die er niet is).
# Base-image digest-gepind (Scorecard Pinned-Dependencies): bij `repo:tag@digest` resolvet
# Docker op de digest en wordt de tag niet gevalideerd, dus een los ARG IMAGE_TAG zou hier
# feitelijk niets doen. Bij een versie-bump: deze regel én de workflow-default IMAGE_TAG
# (voor de output-tag) samen updaten.
FROM busybox:1.38.0-musl@sha256:8635836765b0c4c43970660219739baa58b0883c2e429e4b8918f7dd1519455c AS busybox

FROM docker.io/federatedserviceconnectivity/manager:v2.5.2@sha256:e18baa9adca0225df87e32c355ea61241b376b3df5cea669311797eafac7a23b
COPY --from=busybox /bin/busybox /bin/sh
COPY --chmod=0555 entrypoint.sh /usr/local/bin/migrate-and-serve.sh
ENTRYPOINT ["/usr/local/bin/migrate-and-serve.sh"]
