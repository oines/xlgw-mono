CREATE TABLE app.ai_feedback (
  conversation_id uuid NOT NULL REFERENCES app.ai_conversations(id) ON DELETE CASCADE,
  message_id text NOT NULL,
  user_id uuid NOT NULL REFERENCES app.users(id),
  helpful boolean NOT NULL,
  note text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, message_id, user_id)
);
