#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
  CREATE ROLE folio LOGIN PASSWORD '${APP_DB_PW}';
  CREATE DATABASE folio OWNER folio;
EOSQL