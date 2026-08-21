DROP INDEX IF EXISTS todos_account_id;

ALTER TABLE todos DROP COLUMN IF EXISTS account_id;
