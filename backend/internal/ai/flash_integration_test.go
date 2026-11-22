package ai

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestDeepSeekFlashShortRequestsProduceVisibleText(t *testing.T) {
	db := testDatabase(t)
	owner := addTestUser(t, db)
	const flash = "deepseek-v4-flash"
	const probeBudget, titleBudget, summaryBudget, chatBudget = 1024, 1280, 1536, 2048
	const title, summary, chatReply = "备考压力", "最近备考压力较大，希望得到支持。", "我愿意听你说。"
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer integration-provider-key" {
			http.Error(w, "unexpected provider request", http.StatusBadRequest)
			return
		}
		var req struct {
			Model     string          `json:"model"`
			MaxTokens int             `json:"max_tokens"`
			Thinking  json.RawMessage `json:"thinking"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid provider request", http.StatusBadRequest)
			return
		}
		if req.Model != flash {
			t.Errorf("unexpected model %q", req.Model)
			http.Error(w, "unexpected model", http.StatusBadRequest)
			return
		}
		finish := "stop"
		delta := map[string]string{"role": "assistant", "reasoning_content": "先思考该如何回答"}
		var thinking struct{ Type string }
		if json.Unmarshal(req.Thinking, &thinking) != nil || thinking.Type != "enabled" || req.MaxTokens < probeBudget {
			// A budget that only covers the reasoning leaves no visible answer.
			t.Errorf("Flash request thinking = %s, max_tokens = %d", req.Thinking, req.MaxTokens)
			finish = "length"
		} else {
			switch req.MaxTokens {
			case probeBudget:
				delta["content"] = "OK"
			case titleBudget:
				delta["content"] = title
			case summaryBudget:
				delta["content"] = summary
			case chatBudget:
				delta["content"] = chatReply
			default:
				t.Errorf("unexpected Flash token budget %d", req.MaxTokens)
				http.Error(w, "unexpected Flash token budget", http.StatusBadRequest)
				return
			}
		}
		chunk, err := json.Marshal(delta)
		if err != nil {
			t.Error(err)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		emitSSE(w, fmt.Sprintf(`{"id":"response","object":"chat.completion.chunk","model":%q,"choices":[{"index":0,"delta":%s,"finish_reason":%q}]}`, req.Model, chunk, finish))
		emitSSE(w, `{"id":"response","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":13,"completion_tokens":7,"total_tokens":20}}`)
		emitSSE(w, "[DONE]")
	}))
	t.Cleanup(provider.Close)
	t.Setenv("AI_API_KEY", "")
	t.Setenv("DEEPSEEK_API_KEY", "")
	s, err := New(db, Config{
		UserID:             func(r *http.Request) string { return r.Header.Get("X-Test-User") },
		AllowLocalProvider: true,
		EncryptionKey:      "integration-test-only-local-encryption-key",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeAI(t, s) })
	api := newAPIServer(t, s, owner)
	var conn connection
	api.json("POST", "/admin/ai/connections", 201, map[string]any{
		"name": "DeepSeek", "provider": "deepseek", "protocol": "openai-completions", "base_url": provider.URL + "/v1",
		"api_key": "integration-provider-key", "models": []string{flash}, "enabled": true,
	}, &conn)
	api.json("PUT", "/admin/ai/routes", 200, map[string]any{"items": []route{
		{Purpose: "chat", ConnectionID: conn.ID, Model: flash, ContextWindow: 32000, MaxOutputTokens: chatBudget, Temperature: 0.6},
		{Purpose: "title", ConnectionID: conn.ID, Model: flash, ContextWindow: 32000, MaxOutputTokens: titleBudget, Temperature: 0.4},
		{Purpose: "summary", ConnectionID: conn.ID, Model: flash, ContextWindow: 32000, MaxOutputTokens: summaryBudget, Temperature: 0.2},
	}}, nil)
	api.json("POST", "/admin/ai/connections/"+conn.ID+"/test", 200, nil, &conn)
	if conn.TestStatus == nil || *conn.TestStatus != "completed" {
		t.Errorf("Flash connection probe did not complete: %+v", conn)
	}

	api.json("PUT", "/admin/ai/limits", 200, limits{Enabled: true, DailyLimit: 10, PerMinute: 10, GlobalConcurrency: 4}, nil)
	var c Conversation
	api.json("POST", "/ai/conversations", 201, map[string]string{}, &c)
	path := "/ai/conversations/" + c.ID
	var run Run
	api.json("POST", path+"/inputs", 202, map[string]string{"id": "flash-title-input", "text": "最近考试让我有些压力。"}, &run)
	waitRun(t, api, run.ID, "completed")
	var history struct{ Items []Message }
	api.json("GET", path+"/messages", 200, nil, &history)
	if len(history.Items) != 2 || history.Items[1].Text != chatReply {
		t.Fatalf("expected visible chat reply %q, got %+v", chatReply, history.Items)
	}
	var draft map[string]string
	api.json("POST", path+"/share-summary", 200, map[string][]string{"message_ids": {history.Items[0].ID}}, &draft)
	if draft["summary"] != summary {
		t.Errorf("share summary = %q, want %q", draft["summary"], summary)
	}
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(30 * time.Millisecond) {
		api.json("GET", path, 200, nil, &c)
		if c.Title == title {
			return
		}
	}
	t.Fatalf("generated title = %q, want %q", c.Title, title)
}
