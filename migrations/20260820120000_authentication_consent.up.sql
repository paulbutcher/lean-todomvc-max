CREATE TABLE IF NOT EXISTS auth.consents (
  seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant text NOT NULL,
  account text NOT NULL,
  subject text NOT NULL,
  version text NOT NULL,
  act text NOT NULL,
  recorded_at bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS consents_account ON auth.consents (tenant, account, seq);
CREATE INDEX IF NOT EXISTS consents_subject ON auth.consents (tenant, subject, seq);
