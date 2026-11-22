ALTER TABLE app.settings ADD COLUMN registration_mode text NOT NULL DEFAULT 'open' CHECK(registration_mode IN ('open','invite'));
ALTER TABLE app.settings ADD COLUMN invite_hash text;
ALTER TABLE app.users ADD COLUMN ai_consented_at timestamptz;
