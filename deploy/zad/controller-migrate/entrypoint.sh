#!/bin/sh
# Wrapper-entrypoint: migreer de DB, start dan de controller. ZAD ondersteunt (nog)
# geen args/init-containers, dus dit gebeurt in de image i.p.v. een init-container.
# STORAGE_POSTGRES_DSN (of POSTGRES_DSN) komt uit de env (gezet in Operations Manager).
set -eu

DSN="${STORAGE_POSTGRES_DSN:-${POSTGRES_DSN:-}}"
if [ -z "$DSN" ]; then
  echo "FATAL: STORAGE_POSTGRES_DSN (of POSTGRES_DSN) niet gezet" >&2
  exit 1
fi
# `serve` leest de DSN uit STORAGE_POSTGRES_DSN; normaliseer zodat de POSTGRES_DSN-
# fallback ook serve bereikt (niet alleen de migrate-stap).
export STORAGE_POSTGRES_DSN="$DSN"

# NB: draait `migrate up` bij elke pod-start (ZAD ondersteunt nog geen args/init-containers).
# golang-migrate is idempotent + lockt; ga uit van 1 controller-replica per peer.
echo "controller-migrate: migraties draaien..."
/usr/local/bin/controller migrate up --postgres-dsn "$DSN"

echo "controller-migrate: serve starten..."
exec /usr/local/bin/controller serve
