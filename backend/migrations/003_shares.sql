CREATE TABLE app.ai_shares (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), service_id uuid NOT NULL REFERENCES app.services,
    student_id uuid NOT NULL REFERENCES app.users, staff_id uuid NOT NULL REFERENCES app.staff,
    conversation_id uuid NOT NULL REFERENCES app.ai_conversations(id) ON DELETE CASCADE,
    body text NOT NULL, revoked_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON app.ai_shares(service_id,staff_id);
