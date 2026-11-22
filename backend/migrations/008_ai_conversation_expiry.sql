ALTER TABLE app.ai_conversations ADD COLUMN expires_at timestamptz;
ALTER TABLE app.ai_conversations ALTER COLUMN expires_at SET DEFAULT (now() + interval '168 hours');
CREATE INDEX ai_conversations_expiry ON app.ai_conversations(expires_at) WHERE expires_at IS NOT NULL;

ALTER TABLE app.ai_shares ALTER COLUMN conversation_id DROP NOT NULL;
CREATE INDEX ai_shares_conversation ON app.ai_shares(conversation_id) WHERE conversation_id IS NOT NULL;
