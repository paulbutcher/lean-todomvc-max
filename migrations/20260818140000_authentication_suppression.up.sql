CREATE TABLE IF NOT EXISTS auth.delivery_records (
  tenant text NOT NULL,
  identity_local text NOT NULL,
  identity_domain text NOT NULL,
  suppressed_by text,
  failures bigint NOT NULL,
  first_failure_at bigint NOT NULL,
  last_failure_at bigint NOT NULL,
  detail text NOT NULL,
  PRIMARY KEY (tenant, identity_local, identity_domain)
);
