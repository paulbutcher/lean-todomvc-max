-- One row per `LLMClient.Msg`, in the order the conversation had them: `id` is what orders a
-- transcript, so nothing here records a time the application would have to agree with.
--
-- `tool_calls` holds what the model asked for, as the JSON `Json.compress` writes. TEXT rather
-- than JSONB because nothing queries inside it; it is read back whole and handed to the model.
CREATE TABLE IF NOT EXISTS chat_messages (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id TEXT NOT NULL,
  role TEXT NOT NULL,
  body TEXT NOT NULL DEFAULT '',
  tool_calls TEXT NOT NULL DEFAULT '[]',
  tool_call_id TEXT NOT NULL DEFAULT ''
);

-- Every read is one account's conversation in order, which is exactly this index.
CREATE INDEX IF NOT EXISTS chat_messages_account_id ON chat_messages (account_id, id);
