#!/bin/sh
# The replica: copy the primary once (pg_basebackup), then follow it by streaming its write-ahead log.
# APPLY_DELAY (e.g. 500ms) makes the replica apply each change that much later, to make replication lag visible.
set -e
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  until pg_isready -h db -U postgres; do sleep 1; done
  PGPASSWORD=lab pg_basebackup -h db -U replicator -D "$PGDATA" -X stream -R
  chmod 0700 "$PGDATA"
  echo "recovery_min_apply_delay = '${APPLY_DELAY:-0}'" >> "$PGDATA/postgresql.auto.conf"
fi
exec postgres
