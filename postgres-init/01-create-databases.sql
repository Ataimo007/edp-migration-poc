-- Runs once, only when tyk-postgres's data volume is freshly initialized
-- (Postgres's official image only executes docker-entrypoint-initdb.d/ on an
-- empty data directory — it will NOT re-run this against an existing
-- volume). POSTGRES_DB in docker-compose.yml only creates tyk_analytics
-- (the Dashboard's own database); the Portal and Keycloak each need their
-- own separate database, matching confs/tyk_portal.env's
-- PORTAL_DATABASE_CONNECTIONSTRING (database=tyk_portal) and the keycloak
-- service's KC_DB_URL_DATABASE (keycloak).
CREATE DATABASE tyk_portal;
CREATE DATABASE keycloak;
