ALTER TABLE app.posts ADD COLUMN mode text NOT NULL DEFAULT 'named'
    CHECK(mode IN ('named','anonymous','resonance'));
ALTER TABLE app.posts ADD CONSTRAINT resonance_post_body_length
    CHECK(mode<>'resonance' OR char_length(body) BETWEEN 1 AND 60);

CREATE TABLE app.community_post_blocks (
    viewer_id uuid NOT NULL REFERENCES app.users(id) ON DELETE CASCADE,
    post_id uuid NOT NULL REFERENCES app.posts(id) ON DELETE CASCADE,
    PRIMARY KEY(viewer_id,post_id)
);

ALTER TABLE app.reports ALTER COLUMN reporter_id DROP NOT NULL;
ALTER TABLE app.reports ADD CONSTRAINT reports_system_target
    CHECK(reporter_id IS NOT NULL OR target_type IN ('post','comment'));
CREATE UNIQUE INDEX reports_system_target_unique ON app.reports(target_type,target_id) WHERE reporter_id IS NULL;
