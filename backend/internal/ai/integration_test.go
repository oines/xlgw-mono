package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	core "github.com/oines/astral-core"
	"github.com/oines/xlgw-mono/backend/migrations"
)

// XL_GW_AI_TEST_DATABASE_URL points to a PostgreSQL instance with CREATEDB
// authority. This suite uses a new database per run and drops it on cleanup.
func testDatabase(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("XL_GW_AI_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set XL_GW_AI_TEST_DATABASE_URL to run PostgreSQL integration tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	name := "xlgw_it_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, err := admin.Exec(ctx, "DROP DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
			t.Error(err)
		}
	})
	cfg = cfg.Copy()
	cfg.ConnConfig.Database = name
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	return db
}

func addTestUser(t *testing.T, db *pgxpool.Pool) string {
	t.Helper()
	var id string
	name := "test-" + uuid.NewString()
	if err := db.QueryRow(context.Background(),
		"INSERT INTO app.users(account,nickname,password_hash) VALUES($1,$1,'not-a-real-password') RETURNING id::text", name).
		Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

type testAPI struct {
	t     *testing.T
	url   string
	http  *http.Client
	owner string
}

func (a testAPI) request(method, path string, body any) *http.Response {
	a.t.Helper()
	var b []byte
	if body != nil {
		b, _ = json.Marshal(body)
	}
	req, err := http.NewRequest(method, a.url+"/api/v1"+path, bytes.NewReader(b))
	if err != nil {
		a.t.Fatal(err)
	}
	req.Header.Set("X-Test-User", a.owner)
	req.Header.Set("Content-Type", "application/json")
	res, err := a.http.Do(req)
	if err != nil {
		a.t.Fatal(err)
	}
	return res
}

func (a testAPI) json(method, path string, status int, body, out any) {
	a.t.Helper()
	res := a.request(method, path, body)
	defer res.Body.Close()
	b, err := io.ReadAll(res.Body)
	if err != nil {
		a.t.Fatal(err)
	}
	if res.StatusCode != status {
		a.t.Fatalf("%s %s: got %d want %d: %s", method, path, res.StatusCode, status, b)
	}
	if out != nil {
		if err := json.Unmarshal(b, out); err != nil {
			a.t.Fatalf("%s: %v | %s", path, err, b)
		}
	}
}

func newAPIServer(t *testing.T, s *Service, user string) testAPI {
	t.Helper()
	mux := http.NewServeMux()
	wrap := func(f http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-Test-User") == "" {
				w.WriteHeader(401)
				return
			}
			f(w, r)
		}
	}
	s.Register(mux, wrap, wrap)
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return testAPI{t: t, url: server.URL, http: &http.Client{Timeout: 12 * time.Second}, owner: user}
}

func waitRun(t *testing.T, api testAPI, id string, status string) Run {
	t.Helper()
	deadline := time.Now().Add(7 * time.Second)
	for time.Now().Before(deadline) {
		var r Run
		api.json("GET", "/ai/runs/"+id, 200, nil, &r)
		if terminal(r.Status) {
			if r.Status != status {
				t.Fatalf("expected %s, got %+v", status, r)
			}
			return r
		}
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatal("run did not reach a terminal state")
	return Run{}
}

func closeAI(t *testing.T, s *Service) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.Close(ctx); err != nil {
		t.Error(err)
	}
}

func emitSSE(w http.ResponseWriter, value string) {
	_, _ = fmt.Fprintf(w, "data: %s\n\n", value)
	w.(http.Flusher).Flush()
}

func testProvider(t *testing.T) (string, chan struct{}, chan struct{}, *atomic.Int64, *atomic.Bool) {
	t.Helper()
	seen, release := make(chan struct{}, 1), make(chan struct{})
	calls, fail := &atomic.Int64{}, &atomic.Bool{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer integration-provider-key" {
			http.Error(w, "bad provider request", http.StatusUnauthorized)
			return
		}
		calls.Add(1)
		if fail.Load() {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(503)
			_, _ = io.WriteString(w, `{"error":{"message":"temporary upstream failure","type":"server_error"}}`)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		emitSSE(w, `{"id":"response","object":"chat.completion.chunk","model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":"第一段"},"finish_reason":null}]}`)
		select {
		case seen <- struct{}{}:
		default:
		}
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
		emitSSE(w, `{"id":"response","object":"chat.completion.chunk","model":"test-model","choices":[{"index":0,"delta":{"content":"第二段"},"finish_reason":"stop"}]}`)
		emitSSE(w, `{"id":"response","object":"chat.completion.chunk","model":"test-model","choices":[],"usage":{"prompt_tokens":13,"completion_tokens":7,"total_tokens":20}}`)
		emitSSE(w, "[DONE]")
	}))
	t.Cleanup(server.Close)
	return server.URL + "/v1", seen, release, calls, fail
}

func readSSE(t *testing.T, scan *bufio.Scanner, want func(streamEvent) bool) streamEvent {
	t.Helper()
	for scan.Scan() {
		line := scan.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var e streamEvent
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &e); err != nil {
			t.Fatal(err)
		}
		if want(e) {
			return e
		}
	}
	t.Fatalf("stream closed before expected event: %v", scan.Err())
	return streamEvent{}
}

func TestAIHTTPPostgresStreaming(t *testing.T) {
	db := testDatabase(t)
	owner, other := addTestUser(t, db), addTestUser(t, db)
	base, seen, release, calls, fail := testProvider(t)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	cfg := Config{UserID: func(r *http.Request) string { return r.Header.Get("X-Test-User") },
		AllowLocalProvider: true, EnvironmentAPIKey: "integration-provider-key", EnvironmentBaseURL: base, EnvironmentModel: "test-model"}
	s, err := New(db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, s) })
	first := newAPIServer(t, s, owner)
	second := first
	second.owner = other
	var c, foreign Conversation
	first.json("POST", "/ai/conversations", 201, map[string]string{"title": "压力记录"}, &c)
	second.json("POST", "/ai/conversations", 201, map[string]string{"title": "另一账号"}, &foreign)
	var limit limits
	first.json("PUT", "/admin/ai/limits", 200, limits{Enabled: true, DailyLimit: 2, PerMinute: 6, GlobalConcurrency: 1}, &limit)
	payload := map[string]string{"id": "first-input", "text": "最近感觉压力比较大"}
	var run, duplicate Run
	first.json("POST", "/ai/conversations/"+c.ID+"/inputs", 202, payload, &run)
	select {
	case <-seen:
	case <-time.After(6 * time.Second):
		t.Fatal("provider was not reached")
	}
	first.json("POST", "/ai/conversations/"+c.ID+"/inputs", 202, payload, &duplicate)
	if run.ID != duplicate.ID {
		t.Fatalf("duplicate created a new run: %s != %s", run.ID, duplicate.ID)
	}
	first.json("POST", "/ai/conversations/"+c.ID+"/inputs", 409, map[string]string{"id": "first-input", "text": "不同内容"}, nil)
	second.json("GET", "/ai/conversations/"+c.ID+"/messages", 404, nil, nil)
	second.json("GET", "/ai/runs/"+run.ID+"/events", 404, nil, nil)
	second.json("POST", "/ai/conversations/"+foreign.ID+"/inputs", 503, map[string]string{"id": "another-input", "text": "我也来聊聊"}, nil)
	firstEvent := first.request("GET", "/ai/runs/"+run.ID+"/events", nil)
	t.Cleanup(func() { firstEvent.Body.Close() })
	if firstEvent.StatusCode != 200 {
		t.Fatalf("SSE HTTP %d", firstEvent.StatusCode)
	}
	readSSE(t, bufio.NewScanner(firstEvent.Body), func(e streamEvent) bool { return strings.Contains(e.Text, "第一段") })
	firstEvent.Body.Close()
	reconnected := first.request("GET", "/ai/runs/"+run.ID+"/events", nil)
	t.Cleanup(func() { reconnected.Body.Close() })
	scan := bufio.NewScanner(reconnected.Body)
	e := readSSE(t, scan, func(e streamEvent) bool { return strings.Contains(e.Text, "第一段") })
	if !e.Reset || calls.Load() != 1 {
		t.Fatalf("reconnect snapshot %+v, calls %d", e, calls.Load())
	}
	close(release)
	readSSE(t, scan, func(e streamEvent) bool { return e.Run.Status == "completed" })
	reconnected.Body.Close()
	var history struct{ Items []Message }
	first.json("GET", "/ai/conversations/"+c.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 2 || history.Items[0].Text != payload["text"] || history.Items[1].Text != "第一段第二段" {
		t.Fatalf("incorrect history %+v", history.Items)
	}
	var traced struct{ Items []modelCall }
	first.json("GET", "/admin/ai/calls?purpose=chat", 200, nil, &traced)
	if len(traced.Items) != 1 || traced.Items[0].Input == nil || *traced.Items[0].Input != 13 {
		t.Fatalf("incorrect usage %+v", traced.Items)
	}
	shared, err := s.ShareMessages(context.Background(), owner, c.ID, []string{history.Items[1].ID})
	if err != nil || !strings.Contains(shared, "第一段第二段") {
		t.Fatalf("share=%q %v", shared, err)
	}
	if _, err := s.ShareMessages(context.Background(), other, c.ID, []string{history.Items[1].ID}); err == nil {
		t.Fatal("foreign share allowed")
	}
	summaryPath := "/ai/conversations/" + c.ID + "/share-summary"
	first.json("POST", summaryPath, 200, map[string]any{"message_ids": []string{history.Items[0].ID, history.Items[1].ID}}, nil)
	second.json("POST", summaryPath, 404, map[string]any{"message_ids": []string{history.Items[1].ID}}, nil)
	feedbackPath := "/ai/conversations/" + c.ID + "/messages/" + history.Items[1].ID + "/feedback"
	first.json("PUT", feedbackPath, 200, map[string]any{"helpful": true}, nil)
	first.json("PUT", feedbackPath, 200, map[string]any{"helpful": false, "note": "希望更具体"}, nil)
	second.json("PUT", feedbackPath, 404, map[string]any{"helpful": true}, nil)
	var feedbackRows int
	if err := db.QueryRow(context.Background(), "SELECT count(*) FROM app.ai_feedback WHERE NOT helpful AND note='希望更具体'").Scan(&feedbackRows); err != nil || feedbackRows != 1 {
		t.Fatalf("feedback row was not updated: %d %v", feedbackRows, err)
	}

	closeAI(t, s)
	reopened, err := New(db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, reopened) })
	first = newAPIServer(t, reopened, owner)
	first.json("GET", "/ai/conversations/"+c.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 2 {
		t.Fatalf("reopen lost history %+v", history.Items)
	}
	fail.Store(true)
	first.json("POST", "/ai/conversations/"+c.ID+"/inputs", 202, map[string]string{"id": "second-input", "text": "继续"}, &run)
	waitRun(t, first, run.ID, "failed")
	var quota struct{ Used, Remaining int }
	first.json("GET", "/ai/quota", 200, nil, &quota)
	if quota.Used != 1 || quota.Remaining != 1 {
		t.Fatalf("failure did not restore one use: %+v", quota)
	}
	first.json("GET", "/admin/ai/calls?purpose=chat", 200, nil, &traced)
	if len(traced.Items) != 3 || traced.Items[0].Status != "failed" || traced.Items[1].Status != "failed" {
		t.Fatalf("expected one core retry and no gateway duplicate: %+v", traced.Items)
	}
	fail.Store(false)
	first.json("POST", "/ai/inputs/second-input/retry", 202, map[string]string{"id": "retry-one"}, &run)
	waitRun(t, first, run.ID, "completed")
	first.json("GET", "/ai/conversations/"+c.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 4 || history.Items[2].InputID != "second-input" || history.Items[3].Text != "第一段第二段" {
		t.Fatalf("retry duplicated or lost history %+v", history.Items)
	}
	first.json("GET", "/ai/quota", 200, nil, &quota)
	if quota.Used != 2 || quota.Remaining != 0 {
		t.Fatalf("retry did not use one operation: %+v", quota)
	}
	first.json("DELETE", "/ai/conversations/"+c.ID, 204, nil, nil)
	first.json("GET", "/ai/conversations/"+c.ID+"/messages", 404, nil, nil)
	var remaining int
	if err := db.QueryRow(context.Background(), "SELECT count(*) FROM agent.rollouts").Scan(&remaining); err != nil || remaining != 0 {
		t.Fatalf("delete did not remove retry history: %d %v", remaining, err)
	}
}

func TestHostHelpNeverCallsProvider(t *testing.T) {
	db := testDatabase(t)
	cfg := Config{UserID: func(r *http.Request) string { return r.Header.Get("X-Test-User") }, EnvironmentAPIKey: "", EnvironmentBaseURL: ""}
	t.Setenv("AI_API_KEY", "")
	t.Setenv("DEEPSEEK_API_KEY", "")
	s, err := New(db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, s) })
	api := newAPIServer(t, s, addTestUser(t, db))
	var conv Conversation
	api.json("POST", "/ai/conversations", 201, map[string]string{}, &conv)
	var run Run
	api.json("POST", "/ai/conversations/"+conv.ID+"/inputs", 202, map[string]string{"id": "test-help", "text": "我不想活了"}, &run)
	final := waitRun(t, api, run.ID, "completed")
	if !final.Risk || len(final.Actions) < 1 || final.Actions[0].Kind != "help" {
		t.Fatalf("host did not expose the help action %+v", final)
	}
	var history struct{ Items []Message }
	api.json("GET", "/ai/conversations/"+conv.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 2 || !strings.Contains(history.Items[1].Text, "人工求助") {
		t.Fatalf("host response not persisted: %+v", history.Items)
	}
	var calls int
	if err := db.QueryRow(context.Background(), "SELECT count(*) FROM app.ai_calls").Scan(&calls); err != nil || calls != 0 {
		t.Fatalf("host fallback unexpectedly called model %d %v", calls, err)
	}
	state, err := s.store.LoadState(context.Background(), conv.ID)
	if err != nil || !core.SupportsFormat(state.FormatVersion) || state.PendingInputs[core.InputSteer] != 0 {
		t.Fatalf("host result not properly acknowledged %+v %v", state, err)
	}
}

func TestAIStopAndQuotaSurviveDeletion(t *testing.T) {
	db := testDatabase(t)
	owner := addTestUser(t, db)
	base, seen, release, calls, _ := testProvider(t)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	s, err := New(db, Config{UserID: func(r *http.Request) string { return r.Header.Get("X-Test-User") },
		AllowLocalProvider: true, EnvironmentAPIKey: "integration-provider-key", EnvironmentBaseURL: base, EnvironmentModel: "test-model"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, s) })
	api := newAPIServer(t, s, owner)
	api.json("PUT", "/admin/ai/limits", 200, limits{Enabled: true, DailyLimit: 1, PerMinute: 6, GlobalConcurrency: 1}, nil)
	var c Conversation
	api.json("POST", "/ai/conversations", 201, map[string]string{"title": "停止验证"}, &c)
	var run Run
	api.json("POST", "/ai/conversations/"+c.ID+"/inputs", 202, map[string]string{"id": "stop-input", "text": "我今天有些疲惫"}, &run)
	select {
	case <-seen:
	case <-time.After(6 * time.Second):
		t.Fatal("provider was not reached")
	}
	api.json("POST", "/ai/runs/"+run.ID+"/cancel", 200, nil, nil)
	waitRun(t, api, run.ID, "cancelled")
	var history struct{ Items []Message }
	api.json("GET", "/ai/conversations/"+c.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 1 || history.Items[0].InputID != "stop-input" {
		t.Fatalf("stop committed a partial reply or lost the user input: %+v", history.Items)
	}
	var quota struct{ Used, Remaining int }
	api.json("GET", "/ai/quota", 200, nil, &quota)
	if quota.Used != 1 || quota.Remaining != 0 {
		t.Fatalf("explicit stop must not refund: %+v", quota)
	}
	close(release)
	api.json("POST", "/ai/inputs/stop-input/retry", 202, map[string]string{"id": "stop-retry"}, &run)
	waitRun(t, api, run.ID, "completed")
	api.json("GET", "/ai/conversations/"+c.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 2 || history.Items[1].Text != "第一段第二段" || calls.Load() != 2 {
		t.Fatalf("explicit retry after stop: history=%+v calls=%d", history.Items, calls.Load())
	}
	api.json("DELETE", "/ai/conversations/"+c.ID, 204, nil, nil)
	api.json("GET", "/ai/quota", 200, nil, &quota)
	if quota.Used != 1 || quota.Remaining != 0 {
		t.Fatalf("deleting a conversation refunded quota: %+v", quota)
	}
	api.json("POST", "/ai/conversations", 201, map[string]string{}, &c)
	api.json("POST", "/ai/conversations/"+c.ID+"/inputs", 429, map[string]string{"id": "over-quota", "text": "继续聊天"}, nil)
}

func TestAIRecoversAcceptedInputAfterRestart(t *testing.T) {
	db := testDatabase(t)
	owner := addTestUser(t, db)
	base, _, release, calls, _ := testProvider(t)
	close(release)
	cfg := Config{UserID: func(r *http.Request) string { return r.Header.Get("X-Test-User") },
		AllowLocalProvider: true, EnvironmentAPIKey: "integration-provider-key", EnvironmentBaseURL: base, EnvironmentModel: "test-model"}
	started, err := New(db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	api := newAPIServer(t, started, owner)
	var c Conversation
	api.json("POST", "/ai/conversations", 201, map[string]string{"title": "恢复验证"}, &c)
	closeAI(t, started)
	ctx := context.Background()
	id := uuid.NewString()
	now := time.Now()
	date, _, err := quotaDay(ctx, db, now)
	if err != nil {
		t.Fatal(err)
	}
	// This is the durable state after the Host commits admission and the
	// process exits before handing the input to Core. The replacement
	// process must claim this exact input rather than waiting for a resend.
	tx, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, "INSERT INTO app.ai_inputs(id,conversation_id,digest,body) VALUES($1,$2,$3,$4)",
		"recover-me", c.ID, digestText("刚才断线了"), "刚才断线了")
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO app.ai_runs(id,input_id,conversation_id,user_id,session_id,status,charged,charge_date)
			VALUES($1,'recover-me',$2,$3,$2::uuid::text,'waiting',true,$4::date)`, id, c.ID, owner, date)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO app.ai_admissions(id,user_id,is_retry,charge_date,charged,created_at)
			VALUES($1,$2,false,$3::date,true,$4)`, id, owner, date, now)
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	service, err := New(db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, service) })
	restarted := newAPIServer(t, service, owner)
	waitRun(t, restarted, id, "completed")
	var history struct{ Items []Message }
	restarted.json("GET", "/ai/conversations/"+c.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 2 || history.Items[0].InputID != "recover-me" || calls.Load() != 1 {
		t.Fatalf("incorrect restart recovery: %+v, provider calls=%d", history.Items, calls.Load())
	}
}

func TestAIAdminConfigurationNeverReturnsKey(t *testing.T) {
	db := testDatabase(t)
	base, _, release, _, _ := testProvider(t)
	close(release)
	t.Setenv("AI_API_KEY", "")
	t.Setenv("DEEPSEEK_API_KEY", "")
	cfg := Config{UserID: func(r *http.Request) string { return r.Header.Get("X-Test-User") }, AllowLocalProvider: true,
		EncryptionKey: "integration-test-only-local-encryption-key"}
	s, err := New(db, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, s) })
	owner := addTestUser(t, db)
	api := newAPIServer(t, s, owner)
	payload := map[string]any{"name": "验证连接", "provider": "compatible", "protocol": "openai-completions", "base_url": base,
		"api_key": "integration-provider-key", "models": []string{"test-model"}, "enabled": true, "input_price": 0.12}
	var connection map[string]any
	api.json("POST", "/admin/ai/connections", 201, payload, &connection)
	id := connection["id"].(string)
	if !validUUID(id) || connection["has_key"] != true || connection["api_key"] != nil {
		t.Fatalf("invalid connection response %+v", connection)
	}
	var cipher []byte
	if err := db.QueryRow(context.Background(), "SELECT key_ciphertext FROM app.ai_connections WHERE id=$1", id).Scan(&cipher); err != nil ||
		len(cipher) == 0 || bytes.Contains(cipher, []byte("integration-provider-key")) {
		t.Fatal("key not encrypted in database")
	}
	api.json("POST", "/admin/ai/connections/"+id+"/test", 200, nil, &connection)
	if connection["last_test_status"] != "completed" || connection["api_key"] != nil {
		t.Fatalf("connection test: %+v", connection)
	}
	api.json("PATCH", "/admin/ai/connections/"+id, 400, map[string]any{"base_url": "https://different.example"}, nil)
	api.json("PATCH", "/admin/ai/connections/"+id, 200, map[string]any{"input_price": nil}, &connection)
	if connection["input_price"] != nil {
		t.Fatal("explicit null did not remove optional price")
	}
	var audit int
	if err := db.QueryRow(context.Background(), "SELECT count(*) FROM app.history WHERE object_id=$1 AND kind='operation'", id).Scan(&audit); err != nil || audit != 2 {
		t.Fatalf("expected two successful audited changes, got %d %v", audit, err)
	}
}

func TestAIStaffToolUsesRealObjects(t *testing.T) {
	db := testDatabase(t)
	owner, teacher := addTestUser(t, db), addTestUser(t, db)
	ctx := context.Background()
	if _, err := db.Exec(ctx, "UPDATE app.users SET nickname='陈老师',roles=ARRAY['teacher'] WHERE id=$1", teacher); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, "INSERT INTO app.staff(id,role,bio) VALUES($1,'teacher','学校心理支持教师')", teacher); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int64
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "invalid", 400)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		switch calls.Add(1) {
		case 1:
			if !bytes.Contains(body, []byte(`"name":"school_options"`)) {
				http.Error(w, "missing tool", 400)
				return
			}
			emitSSE(w, `{"id":"tool-turn","model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call-staff","type":"function","function":{"name":"school_options","arguments":"{\"kind\":\"staff\"}"}}]},"finish_reason":"tool_calls"}]}`)
		case 2:
			if !bytes.Contains(body, []byte(teacher)) || !bytes.Contains(body, []byte("陈老师")) {
				http.Error(w, "missing authorized database result", 400)
				return
			}
			emitSSE(w, `{"id":"answer","model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":"你可以查看陈老师的学校支持信息。"},"finish_reason":"stop"}]}`)
		default:
			http.Error(w, "too many provider calls", 500)
			return
		}
		emitSSE(w, "[DONE]")
	}))
	t.Cleanup(provider.Close)
	s, err := New(db, Config{UserID: func(r *http.Request) string { return r.Header.Get("X-Test-User") },
		AllowLocalProvider: true, EnvironmentAPIKey: "integration-provider-key", EnvironmentBaseURL: provider.URL + "/v1", EnvironmentModel: "test-model"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, s) })
	api := newAPIServer(t, s, owner)
	var c Conversation
	api.json("POST", "/ai/conversations", 201, map[string]string{"title": "可以找谁聊聊"}, &c)
	var run Run
	api.json("POST", "/ai/conversations/"+c.ID+"/inputs", 202, map[string]string{"id": "tools-input", "text": "校内有老师可以交流吗"}, &run)
	final := waitRun(t, api, run.ID, "completed")
	if len(final.Actions) != 1 || final.Actions[0].Kind != "staff" || final.Actions[0].ID != teacher || calls.Load() != 2 {
		t.Fatalf("unexpected tool actions %+v; provider calls %d", final, calls.Load())
	}
	var history struct{ Items []Message }
	api.json("GET", "/ai/conversations/"+c.ID+"/messages", 200, nil, &history)
	if len(history.Items) != 2 || !strings.Contains(history.Items[1].Text, "陈老师") {
		t.Fatalf("tool payload leaked or final reply missing %+v", history.Items)
	}
}
