-- IF NOT EXISTS so that a database predating this migration adopts it by recording the id
-- rather than by failing on a table it already has.
CREATE TABLE IF NOT EXISTS todos (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title TEXT NOT NULL,
  completed BOOLEAN NOT NULL DEFAULT FALSE
);
