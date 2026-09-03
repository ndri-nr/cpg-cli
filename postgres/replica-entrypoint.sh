#!/bin/sh
# Bootstraps this container as a streaming-replication standby of $POSTGRES_MASTER_HOST.
# Only runs pg_basebackup once (when PGDATA is empty) - safe to restart/recreate the
# container after that, it just resumes streaming from where it left off.
set -e

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  echo "PGDATA empty - cloning from master ($POSTGRES_MASTER_HOST)..."

  until PGPASSWORD="$POSTGRES_REPLICATION_PASSWORD" pg_basebackup \
      -h "$POSTGRES_MASTER_HOST" \
      -p 5432 \
      -D "$PGDATA" \
      -U "$POSTGRES_REPLICATION_USER" \
      -Fp -Xs -P -R; do
    echo "Master not ready yet, retrying in 2s..."
    sleep 2
  done

  chmod 700 "$PGDATA"
  echo "Base backup done, standby.signal + primary_conninfo written by -R."
fi

exec docker-entrypoint.sh postgres
