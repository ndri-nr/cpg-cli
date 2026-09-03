#!/bin/sh
# MongoDB's --keyFile has strict permission requirements (must not be group/world
# readable) that a Windows bind-mount can't preserve directly, so this copies it into
# the container to a real Linux path and fixes ownership/permissions first - same
# trick as postgres/replica-entrypoint.sh for pg_hba.conf.
#
# Runs via `entrypoint: ["sh", ...]`, which ignores this file's shebang and always
# uses plain POSIX sh - so no bashisms (no `set -o pipefail`, no arrays) here.
set -e

cp /keyfile-src/mongo-keyfile /etc/mongo-keyfile
chmod 400 /etc/mongo-keyfile
chown mongodb:mongodb /etc/mongo-keyfile

exec docker-entrypoint.sh "$@"
