CREATE SCHEMA IF NOT EXISTS app;
CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE agent.rollouts (
  id text PRIMARY KEY,
  sequence bigint NOT NULL DEFAULT 0
);
CREATE TABLE agent.sessions (
  id text PRIMARY KEY,
  rollout_id text NOT NULL REFERENCES agent.rollouts(id) ON DELETE CASCADE,
  version bigint NOT NULL,
  state bytea NOT NULL
);
CREATE INDEX agent_session_rollout ON agent.sessions(rollout_id);
CREATE TABLE agent.entries (
  rollout_id text NOT NULL REFERENCES agent.rollouts(id) ON DELETE CASCADE,
  id text NOT NULL, writer text NOT NULL,
  sequence bigint NOT NULL, parent_id text NOT NULL,
  kind text NOT NULL, reference text NOT NULL,
  entry bytea NOT NULL, projection bytea,
  payload_bytes integer NOT NULL,
  PRIMARY KEY(rollout_id,id), UNIQUE(rollout_id,sequence)
);
CREATE INDEX agent_entry_select ON agent.entries(rollout_id,kind,reference,sequence);
CREATE INDEX agent_entry_children ON agent.entries(rollout_id,parent_id,sequence) WHERE projection IS NOT NULL;
CREATE TABLE agent.receipts (
  session_id text NOT NULL REFERENCES agent.sessions(id) ON DELETE CASCADE,
  id text NOT NULL, receipt bytea NOT NULL, PRIMARY KEY(session_id,id)
);
CREATE TABLE agent.inputs (
  session_id text NOT NULL REFERENCES agent.sessions(id) ON DELETE CASCADE,
  id text NOT NULL, kind text NOT NULL,
  state text NOT NULL, input bytea NOT NULL, accepted_at timestamptz NOT NULL,
  entry_id text NOT NULL DEFAULT '', PRIMARY KEY(session_id,id)
);
CREATE INDEX agent_inputs_state ON agent.inputs(session_id,kind,state);
CREATE TABLE agent.pending (
  session_id text NOT NULL REFERENCES agent.sessions(id) ON DELETE CASCADE,
  bucket text NOT NULL, key text NOT NULL, owner text NOT NULL DEFAULT '',
  input_kind text NOT NULL DEFAULT '', sequence bigint NOT NULL,
  entry bytea NOT NULL, payload_bytes integer NOT NULL, PRIMARY KEY(session_id,bucket,key)
);
CREATE INDEX agent_pending_order ON agent.pending(session_id,sequence);
CREATE TABLE agent.attempts (
  session_id text NOT NULL REFERENCES agent.sessions(id) ON DELETE CASCADE,
  id text NOT NULL, version bigint NOT NULL, purpose text NOT NULL,
  attempt bytea NOT NULL, payload_bytes integer NOT NULL,
  PRIMARY KEY(session_id,id), UNIQUE(session_id,version)
);

CREATE TABLE app.ai_conversations (
  id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  session_id text NOT NULL, deleting boolean NOT NULL DEFAULT false, title text NOT NULL DEFAULT '新对话',
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ai_conversations_owner ON app.ai_conversations(user_id,updated_at DESC);
CREATE TABLE app.ai_inputs (
  id text PRIMARY KEY, conversation_id uuid NOT NULL REFERENCES app.ai_conversations(id) ON DELETE CASCADE,
  digest text NOT NULL, body text,
  core_entry_id text NOT NULL DEFAULT '',
  position bigint GENERATED ALWAYS AS IDENTITY UNIQUE
);
CREATE INDEX ai_inputs_conversation ON app.ai_inputs(conversation_id,position DESC);
CREATE TABLE app.ai_runs (
  id uuid PRIMARY KEY, input_id text NOT NULL REFERENCES app.ai_inputs(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES app.ai_conversations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  session_id text NOT NULL, core_run_id text NOT NULL DEFAULT '',
  retry_id text,
  status text NOT NULL CHECK (status IN ('waiting','streaming','completed','cancelled','failed')),
  error_code text,
  charged boolean NOT NULL,
  charge_date date,
  stop_requested boolean NOT NULL DEFAULT false,
  risk boolean NOT NULL DEFAULT false,
  actions jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(input_id,retry_id)
);
CREATE UNIQUE INDEX ai_run_one_initial ON app.ai_runs(input_id) WHERE retry_id IS NULL;
CREATE INDEX ai_runs_user_time ON app.ai_runs(user_id,created_at DESC);
CREATE INDEX ai_runs_conversation ON app.ai_runs(conversation_id,created_at DESC);
CREATE INDEX ai_runs_active ON app.ai_runs(status) WHERE status IN ('waiting','streaming');
-- Retain only quota metadata when a conversation and its content are deleted.
CREATE TABLE app.ai_admissions (
  id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
  is_retry boolean NOT NULL, charge_date date NOT NULL, charged boolean NOT NULL,
  created_at timestamptz NOT NULL
);
CREATE INDEX ai_admissions_user_time ON app.ai_admissions(user_id,created_at DESC);
CREATE INDEX ai_admissions_quota ON app.ai_admissions(user_id,charge_date) WHERE charged;
CREATE TABLE app.ai_limits (
  id integer PRIMARY KEY CHECK (id=1), enabled boolean NOT NULL DEFAULT true,
  daily_limit integer NOT NULL DEFAULT 40 CHECK (daily_limit>=0),
  per_minute integer NOT NULL DEFAULT 6 CHECK (per_minute>=0),
  global_concurrency integer NOT NULL DEFAULT 10 CHECK (global_concurrency>0)
);
INSERT INTO app.ai_limits(id) VALUES (1);
CREATE TABLE app.ai_user_limits (
  user_id uuid PRIMARY KEY REFERENCES app.users(id) ON DELETE CASCADE,
  enabled boolean, daily_limit integer CHECK (daily_limit>=0),
  per_minute integer CHECK (per_minute>=0)
);
CREATE TABLE app.ai_connections (
  id uuid PRIMARY KEY, name text NOT NULL, provider text NOT NULL, protocol text NOT NULL,
  base_url text NOT NULL, key_ciphertext bytea,
  use_environment_key boolean NOT NULL DEFAULT false,
  models text[] NOT NULL, enabled boolean NOT NULL,
  input_price numeric CHECK (input_price>=0), output_price numeric CHECK (output_price>=0),
  last_test_status text, last_test_at timestamptz, last_test_error text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.ai_routes (
  purpose text PRIMARY KEY CHECK (purpose IN ('chat','summary','title')),
  connection_id uuid NOT NULL REFERENCES app.ai_connections(id), model text NOT NULL,
  fallback_connection_id uuid REFERENCES app.ai_connections(id), fallback_model text,
  temperature double precision NOT NULL,
  max_output_tokens integer NOT NULL CHECK (max_output_tokens>0),
  context_window integer NOT NULL CHECK (context_window>0)
);
CREATE TABLE app.ai_calls (
  id uuid PRIMARY KEY, connection_id uuid REFERENCES app.ai_connections(id),
  user_id uuid REFERENCES app.users(id) ON DELETE SET NULL, run_id uuid REFERENCES app.ai_runs(id) ON DELETE SET NULL,
  purpose text NOT NULL, model text NOT NULL, status text NOT NULL,
  latency_ms bigint NOT NULL DEFAULT 0, input_tokens integer, output_tokens integer,
  cost_estimate numeric, error_code text, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ai_calls_recent ON app.ai_calls(created_at DESC);
