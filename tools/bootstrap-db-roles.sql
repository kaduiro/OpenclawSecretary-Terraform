\set ON_ERROR_STOP on
\if :{?runtime_user}
\else
  \error 'runtime_user psql variable is required'
\endif
\if :{?migration_user}
\else
  \error 'migration_user psql variable is required'
\endif

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'runtime_user') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'migration_user') \gexec
SELECT format('GRANT USAGE, CREATE ON SCHEMA public TO %I', :'migration_user') \gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'runtime_user') \gexec
