-- Back to one column per field. Thinking blocks have nowhere to go and are dropped, and a turn's
-- text blocks are joined, as the application did before it kept whole messages.
ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS role TEXT,
  ADD COLUMN IF NOT EXISTS body TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS tool_calls TEXT NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS tool_call_id TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS is_error BOOLEAN NOT NULL DEFAULT FALSE;

-- Guarded because the column it reads is dropped below.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'chat_messages'
               AND column_name = 'message') THEN
    UPDATE chat_messages AS row SET
      role = CASE source.msg->>'role'
        WHEN 'assistant' THEN 'assistant' WHEN 'tool_result' THEN 'tool' ELSE 'user' END,
      body = CASE source.msg->>'role'
        WHEN 'assistant' THEN
          (SELECT coalesce(string_agg(block->>'text', '' ORDER BY position), '')
           FROM json_array_elements(source.msg->'content') WITH ORDINALITY AS b (block, position)
           WHERE block->>'type' = 'text')
        WHEN 'tool_result' THEN source.msg->>'output'
        ELSE source.msg->>'text' END,
      tool_calls = CASE source.msg->>'role'
        WHEN 'assistant' THEN
          (SELECT coalesce(json_agg(json_build_object('id', block->'id', 'name', block->'name',
                                                      'input', block->'input')
                                    ORDER BY position), '[]'::json)
           FROM json_array_elements(source.msg->'content') WITH ORDINALITY AS b (block, position)
           WHERE block->>'type' = 'tool_call')::text
        ELSE '[]' END,
      tool_call_id = CASE source.msg->>'role' WHEN 'tool_result' THEN source.msg->>'id' ELSE '' END,
      is_error = coalesce((source.msg->>'is_error')::boolean, FALSE)
    FROM (SELECT id, message::json AS msg FROM chat_messages) AS source
    WHERE source.id = row.id AND row.role IS NULL;
  END IF;
END $$;

ALTER TABLE chat_messages ALTER COLUMN role SET NOT NULL;

ALTER TABLE chat_messages DROP COLUMN IF EXISTS message;
