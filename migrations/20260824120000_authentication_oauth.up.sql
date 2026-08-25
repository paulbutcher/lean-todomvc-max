CREATE TABLE IF NOT EXISTS auth.oauth_clients (
  tenant text NOT NULL,
  id text NOT NULL,
  metadata text NOT NULL,
  registered_at bigint NOT NULL,
  last_used_at bigint NOT NULL,
  PRIMARY KEY (tenant, id)
);
CREATE INDEX IF NOT EXISTS oauth_clients_idle ON auth.oauth_clients (tenant, last_used_at);
CREATE TABLE IF NOT EXISTS auth.oauth_documents (
  tenant text NOT NULL,
  client_id text NOT NULL,
  metadata text NOT NULL,
  fetched_at bigint NOT NULL,
  fresh_until bigint NOT NULL,
  PRIMARY KEY (tenant, client_id)
);
CREATE TABLE IF NOT EXISTS auth.oauth_codes (
  tenant text NOT NULL,
  digest_key text NOT NULL,
  digest_bytes text NOT NULL,
  grant_id text NOT NULL,
  account_id text NOT NULL,
  client_id text NOT NULL,
  redirect_uri text NOT NULL,
  redirect_uri_given smallint NOT NULL,
  code_challenge text NOT NULL,
  resource text NOT NULL,
  scopes text NOT NULL,
  issued_at bigint NOT NULL,
  expires_at bigint NOT NULL,
  redeemed_at bigint,
  PRIMARY KEY (tenant, digest_key, digest_bytes)
);
CREATE INDEX IF NOT EXISTS oauth_codes_grant ON auth.oauth_codes (tenant, grant_id);
CREATE TABLE IF NOT EXISTS auth.oauth_access_tokens (
  tenant text NOT NULL,
  digest_key text NOT NULL,
  digest_bytes text NOT NULL,
  grant_id text NOT NULL,
  account_id text NOT NULL,
  client_id text NOT NULL,
  resource text NOT NULL,
  scopes text NOT NULL,
  issued_at bigint NOT NULL,
  expires_at bigint NOT NULL,
  revoked_at bigint,
  PRIMARY KEY (tenant, digest_key, digest_bytes)
);
CREATE INDEX IF NOT EXISTS oauth_access_tokens_grant ON auth.oauth_access_tokens (tenant, grant_id);
CREATE INDEX IF NOT EXISTS oauth_access_tokens_holder
  ON auth.oauth_access_tokens (tenant, account_id, client_id);
CREATE TABLE IF NOT EXISTS auth.oauth_refresh_tokens (
  tenant text NOT NULL,
  digest_key text NOT NULL,
  digest_bytes text NOT NULL,
  grant_id text NOT NULL,
  account_id text NOT NULL,
  client_id text NOT NULL,
  resource text NOT NULL,
  scopes text NOT NULL,
  issued_at bigint NOT NULL,
  expires_at bigint NOT NULL,
  replaced_at bigint,
  revoked_at bigint,
  PRIMARY KEY (tenant, digest_key, digest_bytes)
);
CREATE INDEX IF NOT EXISTS oauth_refresh_tokens_grant
  ON auth.oauth_refresh_tokens (tenant, grant_id);
CREATE INDEX IF NOT EXISTS oauth_refresh_tokens_holder
  ON auth.oauth_refresh_tokens (tenant, account_id, client_id);
