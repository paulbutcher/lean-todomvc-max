-- The library owns the whole schema, so undoing its one migration removes the schema itself.
DROP SCHEMA IF EXISTS auth CASCADE;
