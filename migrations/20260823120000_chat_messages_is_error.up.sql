-- Whether a tool result records a call that failed. Both the Anthropic and Bedrock APIs carry
-- this alongside the result's text, and the transcript is replayed to the model in full, so a
-- column is what keeps a failure a failure across turns rather than prose the model has to read
-- it out of.
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS is_error BOOLEAN NOT NULL DEFAULT FALSE;
