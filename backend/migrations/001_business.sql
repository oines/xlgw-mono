CREATE SCHEMA IF NOT EXISTS app;

CREATE TABLE app.settings (
    id int PRIMARY KEY CHECK(id=1), name text NOT NULL DEFAULT '心灵港湾',
    intro text NOT NULL DEFAULT '', logo_url text NOT NULL DEFAULT '',
    location text NOT NULL DEFAULT '', contact text NOT NULL DEFAULT '',
    service_hours text NOT NULL DEFAULT '', timezone text NOT NULL DEFAULT 'Asia/Shanghai',
    registered_open boolean NOT NULL DEFAULT true, followup_delay_hours int NOT NULL DEFAULT 0,
    teacher_minutes int NOT NULL DEFAULT 50, peer_minutes int NOT NULL DEFAULT 30,
    slot_gap_minutes int NOT NULL DEFAULT 10
);
INSERT INTO app.settings(id) VALUES (1);

CREATE TABLE app.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account text NOT NULL UNIQUE,
    password_hash text NOT NULL, nickname text NOT NULL, avatar_url text NOT NULL DEFAULT '',
    roles text[] NOT NULL DEFAULT ARRAY['student']::text[], active boolean NOT NULL DEFAULT true,
    theme text NOT NULL DEFAULT 'system', motion text NOT NULL DEFAULT 'standard',
    last_seen timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.auth_sessions (
    token_hash text PRIMARY KEY, user_id uuid NOT NULL REFERENCES app.users ON DELETE CASCADE,
    expires_at timestamptz NOT NULL
);
CREATE TABLE app.activity (
    user_id uuid NOT NULL REFERENCES app.users, day date NOT NULL, PRIMARY KEY(user_id,day)
);
CREATE TABLE app.staff (
    id uuid PRIMARY KEY REFERENCES app.users, role text NOT NULL CHECK(role IN ('teacher','peer')),
    bio text NOT NULL DEFAULT '', modes text[] NOT NULL DEFAULT ARRAY['online']::text[],
    location text NOT NULL DEFAULT '', supervisor_id uuid REFERENCES app.staff,
    active boolean NOT NULL DEFAULT true,
    CHECK(role<>'peer' OR supervisor_id IS NOT NULL)
);
CREATE TABLE app.slots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), staff_id uuid NOT NULL REFERENCES app.staff,
    start_at timestamptz NOT NULL, end_at timestamptz NOT NULL,
    mode text NOT NULL CHECK(mode IN ('online','onsite')), canceled boolean NOT NULL DEFAULT false,
    CHECK(end_at>start_at)
);
CREATE INDEX ON app.slots(staff_id,start_at);
CREATE TABLE app.appointments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slot_id uuid NOT NULL REFERENCES app.slots,
    student_id uuid NOT NULL REFERENCES app.users, staff_id uuid NOT NULL REFERENCES app.staff,
    start_at timestamptz NOT NULL, end_at timestamptz NOT NULL,
    mode text NOT NULL, location text NOT NULL DEFAULT '', note text NOT NULL DEFAULT '',
    status text NOT NULL DEFAULT 'pending', reason text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX appointment_slot_active ON app.appointments(slot_id)
    WHERE status IN ('pending','confirmed','in_progress','completed','no_show');
CREATE INDEX ON app.appointments(student_id,start_at);
CREATE INDEX ON app.appointments(staff_id,start_at);

CREATE TABLE app.help_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), student_id uuid NOT NULL REFERENCES app.users,
    staff_id uuid REFERENCES app.staff, contact text NOT NULL, body text NOT NULL,
    preferred_time text NOT NULL DEFAULT '', status text NOT NULL DEFAULT 'submitted',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.services (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), student_id uuid NOT NULL REFERENCES app.users,
    staff_id uuid NOT NULL REFERENCES app.staff, appointment_id uuid UNIQUE REFERENCES app.appointments,
    help_id uuid UNIQUE REFERENCES app.help_requests, status text NOT NULL DEFAULT 'waiting',
    internal_note text NOT NULL DEFAULT '', student_note text NOT NULL DEFAULT '',
    completed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
    CHECK(num_nonnulls(appointment_id,help_id)=1)
);
CREATE TABLE app.conversations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL CHECK(kind IN ('care','peer')),
    service_id uuid UNIQUE REFERENCES app.services, closed boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.conversation_members (
    conversation_id uuid NOT NULL REFERENCES app.conversations, user_id uuid NOT NULL REFERENCES app.users,
    last_read timestamptz NOT NULL DEFAULT '-infinity', PRIMARY KEY(conversation_id,user_id)
);
CREATE TABLE app.messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), conversation_id uuid NOT NULL REFERENCES app.conversations,
    sender_id uuid NOT NULL REFERENCES app.users, body text NOT NULL, hidden boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ON app.messages(conversation_id,created_at);

CREATE TABLE app.followups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), service_id uuid NOT NULL UNIQUE REFERENCES app.services,
    student_id uuid NOT NULL REFERENCES app.users, staff_id uuid NOT NULL REFERENCES app.staff,
    status text NOT NULL DEFAULT 'awaiting', answers jsonb NOT NULL DEFAULT '{}', submitted_at timestamptz,
    available_at timestamptz NOT NULL DEFAULT now(), invited boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.transfers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), service_id uuid NOT NULL REFERENCES app.services,
    from_id uuid NOT NULL REFERENCES app.staff, to_id uuid NOT NULL REFERENCES app.staff,
    note text NOT NULL, status text NOT NULL DEFAULT 'pending', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ON app.transfers(service_id) WHERE status='pending';
CREATE TABLE app.history (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL, object_id uuid NOT NULL, actor_id uuid REFERENCES app.users,
    action text NOT NULL, note text NOT NULL DEFAULT '', student_note text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON app.history(kind,object_id,id);

CREATE TABLE app.blocks (
    owner_id uuid NOT NULL REFERENCES app.users, target_id uuid NOT NULL REFERENCES app.users,
    created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(owner_id,target_id), CHECK(owner_id<>target_id)
);
CREATE TABLE app.chat_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), sender_id uuid NOT NULL REFERENCES app.users,
    recipient_id uuid NOT NULL REFERENCES app.users, note text NOT NULL,
    status text NOT NULL DEFAULT 'pending', conversation_id uuid UNIQUE REFERENCES app.conversations,
    created_at timestamptz NOT NULL DEFAULT now(), CHECK(sender_id<>recipient_id)
);
CREATE UNIQUE INDEX ON app.chat_requests(least(sender_id,recipient_id),greatest(sender_id,recipient_id)) WHERE status='pending';
CREATE TABLE app.posts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), author_id uuid NOT NULL REFERENCES app.users,
    body text NOT NULL, tags text[] NOT NULL, hidden boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.comments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), post_id uuid NOT NULL REFERENCES app.posts,
    parent_id uuid REFERENCES app.comments, author_id uuid NOT NULL REFERENCES app.users,
    body text NOT NULL, hidden boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON app.comments(post_id,created_at);
CREATE TABLE app.resonances (
    post_id uuid NOT NULL REFERENCES app.posts, user_id uuid NOT NULL REFERENCES app.users,
    PRIMARY KEY(post_id,user_id)
);
CREATE TABLE app.reports (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), reporter_id uuid NOT NULL REFERENCES app.users,
    author_id uuid NOT NULL REFERENCES app.users, target_type text NOT NULL, target_id uuid NOT NULL,
    reason text NOT NULL, note text NOT NULL DEFAULT '', evidence text NOT NULL,
    status text NOT NULL DEFAULT 'pending', result text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(reporter_id,target_type,target_id)
);
CREATE TABLE app.notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES app.users,
    work boolean NOT NULL DEFAULT false, kind text NOT NULL, title text NOT NULL, body text NOT NULL DEFAULT '',
    target_type text NOT NULL, target_id uuid, read boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON app.notifications(user_id,work,created_at DESC);
CREATE TABLE app.feedback (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), student_id uuid NOT NULL REFERENCES app.users,
    category text NOT NULL, body text NOT NULL, contact text NOT NULL DEFAULT '',
    status text NOT NULL DEFAULT 'pending', reply text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.resources (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL CHECK(kind IN ('support','article','activity','announcement')),
    title text NOT NULL, body text NOT NULL, url text NOT NULL DEFAULT '',
    published boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE app.avatars (
    user_id uuid PRIMARY KEY REFERENCES app.users, revision int NOT NULL CHECK(revision>0),
    config jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now()
);
