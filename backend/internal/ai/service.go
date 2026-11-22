package ai

import (
	"bytes"
	"context"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	core "github.com/oines/astral-core"
)

type Config struct {
	UserID                func(*http.Request) string
	EncryptionKey         string
	EnvironmentAPIKey     string
	EnvironmentBaseURL    string
	EnvironmentModel      string
	AllowLocalProvider    bool
	OnConversationDeleted func(context.Context, string, string) error
	SessionActive         func(*http.Request) bool
	Logger                *slog.Logger
}

type Service struct {
	db        *pgxpool.Pool
	store     *Store
	cfg       Config
	keyCipher cipher.AEAD
	transport *http.Transport
	logger    *slog.Logger
	ctx       context.Context
	cancel    context.CancelFunc

	mu     sync.Mutex
	active map[string]*activation
	users  map[string]bool
	slots  int
	bg     sync.WaitGroup
}

type activation struct {
	runID   string
	userID  string
	convID  string
	session *core.Session
	run     *core.Run
	stop    context.CancelFunc
	ready   chan struct{}

	mu        sync.Mutex
	view      Run
	text      string
	attempt   string
	next      int
	listeners map[int]chan streamEvent
}

func New(db *pgxpool.Pool, cfg Config) (*Service, error) {
	if db == nil || cfg.UserID == nil {
		return nil, errors.New("AI requires database and authenticated identity")
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.EncryptionKey == "" {
		cfg.EncryptionKey = os.Getenv("AI_ENCRYPTION_KEY")
	}
	if cfg.EnvironmentAPIKey == "" {
		cfg.EnvironmentAPIKey = os.Getenv("AI_API_KEY")
		if cfg.EnvironmentAPIKey == "" {
			cfg.EnvironmentAPIKey = os.Getenv("DEEPSEEK_API_KEY")
		}
	}
	if cfg.EnvironmentBaseURL == "" {
		cfg.EnvironmentBaseURL = os.Getenv("AI_BASE_URL")
	}
	if cfg.EnvironmentModel == "" {
		cfg.EnvironmentModel = os.Getenv("AI_MODEL")
	}
	aead, err := makeCipher(cfg.EncryptionKey)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &Service{db: db, store: &Store{Pool: db}, cfg: cfg, keyCipher: aead,
		logger: cfg.Logger, ctx: ctx, cancel: cancel, active: make(map[string]*activation), users: make(map[string]bool)}
	s.transport = s.makeTransport()
	setupCtx, stop := context.WithTimeout(ctx, 20*time.Second)
	defer stop()
	if err = s.configureEnvironment(setupCtx); err == nil {
		err = s.recover(setupCtx)
	}
	if err != nil {
		cancel()
		return nil, err
	}
	return s, nil
}

func (s *Service) Close(ctx context.Context) error {
	s.cancel()
	s.transport.CloseIdleConnections()
	done := make(chan struct{})
	go func() { s.bg.Wait(); close(done) }()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-done:
		return nil
	}
}

func (s *Service) configureEnvironment(ctx context.Context) error {
	if s.cfg.EnvironmentAPIKey == "" {
		return nil
	}
	model := s.cfg.EnvironmentModel
	if model == "" {
		model = "deepseek-chat"
	}
	base := s.cfg.EnvironmentBaseURL
	if base == "" {
		base = "https://api.deepseek.com/v1"
	}
	base = strings.TrimRight(base, "/")
	if err := validateEndpoint(base, s.cfg.AllowLocalProvider); err != nil {
		return err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	var exists bool
	if err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM app.ai_connections)").Scan(&exists); err != nil || exists {
		return err
	}
	id := uuid.NewString()
	provider := "compatible"
	if strings.Contains(base, "://api.deepseek.com/") {
		provider = "deepseek"
	}
	_, err = tx.Exec(ctx, `INSERT INTO app.ai_connections(id,name,provider,protocol,base_url,use_environment_key,models,enabled)
	VALUES($1,'环境配置',$2,'openai-completions',$3,true,$4,true)`, id, provider, base, []string{model})
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO app.ai_routes(purpose,connection_id,model,temperature,max_output_tokens,context_window)
	VALUES('chat',$1,$2,0.6,2048,32000),('summary',$1,$2,0.2,1024,32000),('title',$1,$2,0.4,80,32000)`, id, model)
	}
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

type apiError struct {
	Status  int        `json:"-"`
	Code    string     `json:"code"`
	Message string     `json:"message"`
	RetryAt *time.Time `json:"retry_at,omitempty"`
}

func (e *apiError) Error() string { return e.Code }
func bad(code, message string) *apiError {
	return &apiError{Status: http.StatusBadRequest, Code: code, Message: message}
}
func conflict(code, message string) *apiError {
	return &apiError{Status: http.StatusConflict, Code: code, Message: message}
}
func unavailable(code, message string) *apiError {
	return &apiError{Status: http.StatusServiceUnavailable, Code: code, Message: message}
}
func notFound() *apiError {
	return &apiError{Status: http.StatusNotFound, Code: "not_found", Message: "找不到这条记录。"}
}

func errorCode(err error) string {
	if err == nil {
		return "model_error"
	}
	var ae *apiError
	var me *core.ModelError
	switch {
	case errors.As(err, &ae):
		return ae.Code
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, context.DeadlineExceeded):
		return "request_timeout"
	case errors.As(err, &me):
		if code := me.Code; len(code) > 0 && len(code) <= 60 && strings.IndexFunc(code, func(r rune) bool {
			return !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_')
		}) < 0 {
			return code
		}
		return "model_error"
	case errors.Is(err, core.ErrBudget):
		return "context_limit"
	default:
		return "model_error"
	}
}

func runMessage(code string) string {
	switch code {
	case "":
		return ""
	case "model_unavailable", "model_access":
		return "模型暂时不可用，请稍后重试。"
	case "disabled":
		return "AI 功能暂不可用。你仍可以查看历史和寻求校内支持。"
	case "request_timeout":
		return "回复超时了，请稍后重试。"
	case "context_limit":
		return "这段对话已接近长度上限，可以开启新的对话。"
	default:
		return "这次回复没有完成，可以稍后重试。"
	}
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *Service) fail(w http.ResponseWriter, err error) {
	var api *apiError
	switch {
	case errors.As(err, &api):
	case errors.Is(err, pgx.ErrNoRows), errors.Is(err, core.ErrNotFound):
		api = notFound()
	case errors.Is(err, core.ErrConflict):
		api = conflict("conflict", "请求与现有记录冲突。")
	case errors.Is(err, core.ErrBusy):
		api = conflict("busy", "已有一条回复正在生成。")
	default:
		s.logger.Error("AI handler error", "kind", fmt.Sprintf("%T", err))
		api = &apiError{Status: 500, Code: "internal", Message: "服务暂不可用，请稍后再试。"}
	}
	writeJSON(w, api.Status, api)
}

func decode(w http.ResponseWriter, r *http.Request, data any, optional bool) error {
	r.Body = http.MaxBytesReader(w, r.Body, 128<<10)
	d := json.NewDecoder(r.Body)
	if err := d.Decode(data); err != nil {
		if optional && errors.Is(err, io.EOF) {
			return nil
		}
		return bad("invalid_body", "请检查请求内容。")
	}
	if err := d.Decode(new(json.RawMessage)); !errors.Is(err, io.EOF) {
		return bad("invalid_body", "请检查请求内容。")
	}
	return nil
}

func validUUID(id string) bool {
	return len(id) == 36 && uuid.Validate(id) == nil
}

func validInputID(id string) bool {
	return len(id) > 0 && len(id) <= 100 && strings.IndexFunc(id, func(r rune) bool {
		return !(r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r == '-' || r == '_' || r == '.')
	}) < 0
}

func pageLimit(r *http.Request, fallback, max int) int {
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 {
		return min(n, max)
	}
	return fallback
}

func shortText(value string, n int) string {
	if utf8.RuneCountInString(value) <= n {
		return value
	}
	return string([]rune(value)[:n])
}

func (s *Service) Register(mux *http.ServeMux, auth, admin func(http.HandlerFunc) http.HandlerFunc) {
	handle := func(pattern string, handler http.HandlerFunc) { mux.HandleFunc(pattern, auth(handler)) }
	manage := func(pattern string, handler http.HandlerFunc) { mux.HandleFunc(pattern, admin(handler)) }
	handle("GET /api/v1/ai/conversations", s.listConversations)
	handle("POST /api/v1/ai/conversations", s.createConversation)
	handle("GET /api/v1/ai/conversations/{id}", s.getConversation)
	handle("PATCH /api/v1/ai/conversations/{id}", s.renameConversation)
	handle("DELETE /api/v1/ai/conversations/{id}", s.deleteConversation)
	handle("GET /api/v1/ai/conversations/{id}/messages", s.messages)
	handle("POST /api/v1/ai/conversations/{id}/share-summary", s.summarizeShare)
	handle("PUT /api/v1/ai/conversations/{id}/messages/{message}/feedback", s.feedback)
	handle("POST /api/v1/ai/conversations/{id}/inputs", s.send)
	handle("GET /api/v1/ai/runs/{id}", s.getRun)
	handle("GET /api/v1/ai/runs/{id}/events", s.events)
	handle("POST /api/v1/ai/runs/{id}/cancel", s.stopRun)
	handle("POST /api/v1/ai/inputs/{id}/retry", s.retry)
	handle("GET /api/v1/ai/quota", s.quota)
	manage("GET /api/v1/admin/ai/connections", s.listConnections)
	manage("POST /api/v1/admin/ai/connections", s.addConnection)
	manage("PATCH /api/v1/admin/ai/connections/{id}", s.editConnection)
	manage("POST /api/v1/admin/ai/connections/{id}/test", s.testConnection)
	manage("GET /api/v1/admin/ai/routes", s.listRoutes)
	manage("PUT /api/v1/admin/ai/routes", s.setRoutes)
	manage("GET /api/v1/admin/ai/calls", s.listCalls)
	manage("GET /api/v1/admin/ai/calls/{id}", s.getCall)
	manage("GET /api/v1/admin/ai/limits", s.getLimits)
	manage("PUT /api/v1/admin/ai/limits", s.setLimits)
	manage("GET /api/v1/admin/ai/limits/users", s.listUserLimits)
	manage("PUT /api/v1/admin/ai/limits/users/{id}", s.setUserLimits)
}

func digestText(text string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(text))) }

func visibleText(m *core.Message) string {
	if m == nil || m.Failed() {
		return ""
	}
	var b bytes.Buffer
	for _, c := range m.Content {
		if c.Type == "text" {
			b.WriteString(c.Text)
		}
	}
	return b.String()
}
