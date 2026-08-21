CREATE TABLE IF NOT EXISTS auth.rate_counters (
  scope_key text NOT NULL,
  action text NOT NULL,
  bucket bigint NOT NULL,
  uses bigint NOT NULL,
  PRIMARY KEY (scope_key, action, bucket)
);
