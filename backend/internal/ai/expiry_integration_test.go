package ai

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestAIConversationExpiryPreservesActiveRunsAndSharedCopies(t *testing.T) {
	db := testDatabase(t)
	ctx := context.Background()
	owner, staff := addTestUser(t, db), addTestUser(t, db)
	base, seen, release, _, _ := testProvider(t)
	s, err := New(db, Config{
		UserID:             func(r *http.Request) string { return r.Header.Get("X-Test-User") },
		AllowLocalProvider: true, EnvironmentAPIKey: "integration-provider-key",
		EnvironmentBaseURL: base, EnvironmentModel: "test-model",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, s) })
	api := newAPIServer(t, s, owner)
	var expiring, legacy, future Conversation
	api.json("POST", "/ai/conversations", 201, map[string]string{"title": "到期验证"}, &expiring)
	api.json("POST", "/ai/conversations", 201, nil, &legacy)
	api.json("POST", "/ai/conversations", 201, nil, &future)
	if expiring.ExpiresAt == nil || expiring.ExpiresAt.Sub(expiring.CreatedAt) != 7*24*time.Hour {
		t.Fatalf("expected seven-day expiry: %+v", expiring)
	}
	if _, err := db.Exec(ctx, `UPDATE app.ai_conversations SET expires_at=NULL,
		created_at=now()-interval '30 days',updated_at=now()-interval '30 days' WHERE id=$1`, legacy.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, "INSERT INTO app.staff(id,role) VALUES($1,'teacher')", staff); err != nil {
		t.Fatal(err)
	}
	var share string
	if err := db.QueryRow(ctx, `WITH request AS (
		INSERT INTO app.help_requests(student_id,contact,body) VALUES($1,'','') RETURNING id
	), service AS (
		INSERT INTO app.services(student_id,staff_id,help_id) SELECT $1,$2,id FROM request RETURNING id
	) INSERT INTO app.ai_shares(service_id,student_id,staff_id,conversation_id,body)
		SELECT id,$1,$2,$3,'已分享副本' FROM service RETURNING id`, owner, staff, expiring.ID).Scan(&share); err != nil {
		t.Fatal(err)
	}

	var run Run
	path := "/ai/conversations/" + expiring.ID
	api.json("POST", path+"/inputs", 202, map[string]string{"id": "expiry-input", "text": "想聊今天的作息"}, &run)
	select {
	case <-seen:
	case <-time.After(6 * time.Second):
		t.Fatal("provider was not reached")
	}
	if _, err := db.Exec(ctx, "UPDATE app.ai_conversations SET expires_at=now()-interval '1 minute' WHERE id=$1", expiring.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.expireDueConversations(ctx); err != nil {
		t.Fatal(err)
	}
	api.json("GET", path, 200, nil, nil)
	api.json("POST", path+"/inputs", 404, map[string]string{"id": "new-input", "text": "继续聊天"}, nil)

	close(release)
	waitRun(t, api, run.ID, "completed")
	s.mu.Lock()
	activation := s.active[expiring.ID]
	s.mu.Unlock()
	if activation != nil {
		select {
		case <-activation.ready:
		case <-time.After(6 * time.Second):
			t.Fatal("Core session did not close")
		}
	}
	state, err := s.store.LoadState(ctx, expiring.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.expireDueConversations(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.expireDueConversations(ctx); err != nil {
		t.Fatal(err)
	}
	api.json("GET", path, 404, nil, nil)
	api.json("GET", "/ai/runs/"+run.ID, 404, nil, nil)
	api.json("GET", "/ai/conversations/"+legacy.ID, 200, nil, &legacy)
	api.json("GET", "/ai/conversations/"+future.ID, 200, nil, nil)
	var exists bool
	if err := db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM agent.rollouts WHERE id=$1)", state.RolloutID).Scan(&exists); err != nil || exists {
		t.Fatalf("expired conversation retained its Core rollout: %v, %v", exists, err)
	}
	var body string
	var source *string
	if err := db.QueryRow(ctx, "SELECT body,conversation_id::text FROM app.ai_shares WHERE id=$1", share).Scan(&body, &source); err != nil || body != "已分享副本" || source != nil {
		t.Fatalf("care share was altered beyond its origin link: body=%q source=%v err=%v", body, source, err)
	}
}
