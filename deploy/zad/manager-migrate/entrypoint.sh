#!/bin/sh
# Wrapper-entrypoint: migreer de DB, start dan de manager. ZAD verbiedt args/
# init-containers, dus dit gebeurt in de image i.p.v. een init-container.
# STORAGE_POSTGRES_DSN (of POSTGRES_DSN) komt uit de env (gezet in Operations Manager).
set -eu

DSN="${STORAGE_POSTGRES_DSN:-${POSTGRES_DSN:-}}"
if [ -z "$DSN" ]; then
  echo "FATAL: STORAGE_POSTGRES_DSN (of POSTGRES_DSN) niet gezet" >&2
  exit 1
fi

echo "manager-migrate: migraties draaien..."
/usr/local/bin/manager migrate up --postgres-dsn "$DSN"

echo "manager-migrate: serve starten..."
exec /usr/local/bin/manager serve
