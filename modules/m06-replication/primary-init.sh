#!/bin/sh
# Runs once when the primary is created: a user the replica connects as, and permission to connect for replication.
set -e
psql -v ON_ERROR_STOP=1 -U postgres -d shortener -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'lab'"
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
