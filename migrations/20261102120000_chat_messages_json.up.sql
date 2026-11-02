-- Each row becomes one `LLMClient.Msg` in the library's own JSON encoding, which keeps what the
-- separate columns could not: thinking blocks, and the order of a turn's blocks. JSON rather than
-- JSONB throughout, so that a tool's input keeps the exact text the model sent.
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS message TEXT;

-- Guarded because the columns it reads are dropped below. Rows are converted as the application
-- read them: an unknown role is a user turn, and a tool call without a string `id` and `name`,
-- or `tool_calls` that is not a JSON array, is no call at all.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'chat_messages'
               AND column_name = 'role') THEN
    UPDATE chat_messages SET message = (CASE role
      WHEN 'assistant' THEN json_build_object('role', 'assistant', 'content',
        (SELECT coalesce(json_agg(block ORDER BY position), '[]'::json) FROM (
          SELECT 0 AS position, json_build_object('type', 'text', 'text', body) AS block
          WHERE body <> ''
          UNION ALL
          SELECT position, json_build_object('type', 'tool_call', 'id', call->'id',
                                             'name', call->'name',
                                             'input', coalesce(call->'input', '{}'::json))
          FROM json_array_elements(
                 CASE WHEN pg_input_is_valid(tool_calls, 'json')
                        AND json_typeof(tool_calls::json) = 'array'
                      THEN tool_calls::json ELSE '[]'::json END)
               WITH ORDINALITY AS calls (call, position)
          WHERE json_typeof(call->'id') = 'string' AND json_typeof(call->'name') = 'string'
        ) AS blocks))
      WHEN 'tool' THEN json_build_object('role', 'tool_result', 'id', tool_call_id,
                                         'output', body, 'is_error', is_error)
      ELSE json_build_object('role', 'user', 'text', body)
    END)::text
    WHERE message IS NULL;
  END IF;
END $$;

ALTER TABLE chat_messages ALTER COLUMN message SET NOT NULL;

ALTER TABLE chat_messages
  DROP COLUMN IF EXISTS role,
  DROP COLUMN IF EXISTS body,
  DROP COLUMN IF EXISTS tool_calls,
  DROP COLUMN IF EXISTS tool_call_id,
  DROP COLUMN IF EXISTS is_error;
