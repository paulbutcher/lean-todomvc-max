CREATE TABLE IF NOT EXISTS auth.credentials (
  tenant text NOT NULL,
  id text NOT NULL,
  account_id text NOT NULL,
  kind text NOT NULL,
  issuer text,
  subject text,
  local text,
  domain text,
  created_at bigint NOT NULL,
  PRIMARY KEY (tenant, id)
);
CREATE UNIQUE INDEX IF NOT EXISTS credentials_identity
  ON auth.credentials (tenant, issuer, subject) WHERE kind = 'federated';
CREATE INDEX IF NOT EXISTS credentials_account ON auth.credentials (tenant, account_id);
CREATE UNIQUE INDEX IF NOT EXISTS account_emails_address
  ON auth.account_emails (tenant, local, domain);
CREATE TABLE IF NOT EXISTS auth.federation_states (
  tenant text NOT NULL,
  id text NOT NULL,
  provider text NOT NULL,
  digest_key text NOT NULL,
  digest_bytes text NOT NULL,
  verifier text NOT NULL,
  nonce text NOT NULL,
  return_to text,
  created_at bigint NOT NULL,
  expires_at bigint NOT NULL,
  consumed_at bigint,
  PRIMARY KEY (tenant, id)
);
CREATE INDEX IF NOT EXISTS federation_states_digest
  ON auth.federation_states (tenant, digest_key, digest_bytes);
