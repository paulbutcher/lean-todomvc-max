-- Nothing recorded before this migration has an owner to attribute it to, and no default would
-- be a truthful one, so the rows go rather than being parked under an invented account.
DELETE FROM todos;

ALTER TABLE todos ADD COLUMN IF NOT EXISTS account_id TEXT NOT NULL;

CREATE INDEX IF NOT EXISTS todos_account_id ON todos (account_id);
