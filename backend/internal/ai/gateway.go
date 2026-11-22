package ai

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	core "github.com/oines/astral-core"
	"github.com/oines/astral-core/models"
	"github.com/oines/astral-core/models/provider"
	"github.com/oines/astral-core/models/provider/openai/completions"
)

type connection struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Provider    string     `json:"provider"`
	Protocol    string     `json:"protocol"`
	BaseURL     string     `json:"base_url"`
	Models      []string   `json:"models"`
	Enabled     bool       `json:"enabled"`
	HasKey      bool       `json:"has_key"`
	InputPrice  *float64   `json:"input_price"`
	OutputPrice *float64   `json:"output_price"`
	TestStatus  *string    `json:"last_test_status"`
	TestAt      *time.Time `json:"last_test_at"`
	TestError   *string    `json:"last_test_error"`
	key         []byte
	environment bool
}

const connectionColumns = `id::text,name,provider,protocol,base_url,models,enabled,input_price::float8,output_price::float8,
  last_test_status,last_test_at,last_test_error,key_ciphertext,use_environment_key`

func (s *Service) scanConnection(row interface{ Scan(...any) error }) (c connection, err error) {
	err = row.Scan(&c.ID, &c.Name, &c.Provider, &c.Protocol, &c.BaseURL, &c.Models, &c.Enabled,
		&c.InputPrice, &c.OutputPrice, &c.TestStatus, &c.TestAt, &c.TestError, &c.key, &c.environment)
	c.HasKey = len(c.key) > 0 || c.environment && s.cfg.EnvironmentAPIKey != ""
	return c, err
}

func (s *Service) connection(ctx context.Context, id string) (connection, error) {
	return s.queryConnection(ctx, s.db, id)
}
func (s *Service) queryConnection(ctx context.Context, q rowQuery, id string) (connection, error) {
	return s.scanConnection(q.QueryRow(ctx, "SELECT "+connectionColumns+" FROM app.ai_connections WHERE id=$1", id))
}

type route struct {
	Purpose         string  `json:"purpose"`
	ConnectionID    string  `json:"connection_id"`
	Model           string  `json:"model"`
	FallbackID      *string `json:"fallback_connection_id"`
	FallbackModel   *string `json:"fallback_model"`
	Temperature     float64 `json:"temperature"`
	MaxOutputTokens int     `json:"max_output_tokens"`
	ContextWindow   int     `json:"context_window"`
}

const routeColumns = `purpose,connection_id::text,model,fallback_connection_id::text,fallback_model,temperature,max_output_tokens,context_window`

func scanRoute(row interface{ Scan(...any) error }) (r route, err error) {
	err = row.Scan(&r.Purpose, &r.ConnectionID, &r.Model, &r.FallbackID, &r.FallbackModel, &r.Temperature, &r.MaxOutputTokens, &r.ContextWindow)
	return r, err
}

type modelTarget struct {
	ConnectionID string         `json:"connection_id"`
	Purpose      string         `json:"purpose"`
	Model        string         `json:"model"`
	BaseURL      string         `json:"base_url"`
	Dialect      models.Dialect `json:"dialect"`
	InputPrice   *float64       `json:"input_price,omitempty"`
	OutputPrice  *float64       `json:"output_price,omitempty"`
}

func (t modelTarget) isDeepSeekFlash() bool {
	return t.Dialect == models.DeepSeek &&
		(t.Model == "deepseek-flash" || t.Model == "deepseek-v4-flash" || t.Model == "deepseek-v4-flash-vision-exp")
}

func (s *Service) resolve(ctx context.Context, selection core.ModelSelection, owner, sessionID string) (core.ResolvedModel, error) {
	return s.resolveWith(ctx, s.db, selection, owner, sessionID)
}

func (s *Service) resolveWith(ctx context.Context, q rowQuery, selection core.ModelSelection, owner, sessionID string) (core.ResolvedModel, error) {
	purpose := selection.ID
	r, err := scanRoute(q.QueryRow(ctx, "SELECT "+routeColumns+" FROM app.ai_routes WHERE purpose=$1", purpose))
	if err != nil || r.ContextWindow <= r.MaxOutputTokens+16 {
		return core.ResolvedModel{}, &core.ModelError{Code: "model_unavailable"}
	}
	c, err := s.queryConnection(ctx, q, r.ConnectionID)
	model := r.Model
	if err != nil || !c.Enabled || !c.HasKey {
		if r.FallbackID == nil || r.FallbackModel == nil {
			return core.ResolvedModel{}, &core.ModelError{Code: "model_unavailable"}
		}
		c, err = s.queryConnection(ctx, q, *r.FallbackID)
		model = *r.FallbackModel
	}
	if err != nil || !c.Enabled || !c.HasKey || !slices.Contains(c.Models, model) {
		return core.ResolvedModel{}, &core.ModelError{Code: "model_unavailable"}
	}
	target := newTarget(c, purpose, model)
	b, err := json.Marshal(target)
	if err != nil {
		return core.ResolvedModel{}, err
	}
	digest := sha256.Sum256(b)
	spec := core.ModelSpec{
		ID: purpose + "/" + c.ID + "/" + model, Revision: fmt.Sprintf("%x/%d/%d", digest, r.ContextWindow, r.MaxOutputTokens),
		ContextWindow: r.ContextWindow, MaxInputTokens: min(16_000, r.ContextWindow-r.MaxOutputTokens-16),
		MaxOutputTokens: r.MaxOutputTokens,
	}
	m, err := s.gatewayModel(target, spec, owner, sessionID, false, "")
	if err != nil {
		return core.ResolvedModel{}, err
	}
	options := selection.Options
	options.Temperature = &r.Temperature
	if target.isDeepSeekFlash() {
		options.Reasoning.Enabled = new(true)
	}
	return core.ResolvedModel{Model: m, Options: options, Snapshot: b}, nil
}

func newTarget(c connection, purpose, model string) modelTarget {
	dialect := models.Compatible
	switch strings.ToLower(c.Provider) {
	case "deepseek":
		dialect = models.DeepSeek
	case "openai":
		dialect = models.OpenAI
	case "openrouter":
		dialect = models.OpenRouter
	case "qwen":
		dialect = models.Qwen
	}
	return modelTarget{ConnectionID: c.ID, Purpose: purpose, Model: model, BaseURL: c.BaseURL,
		Dialect: dialect, InputPrice: c.InputPrice, OutputPrice: c.OutputPrice}
}

func (s *Service) restore(ctx context.Context, snapshot core.ModelSnapshot, owner, sessionID string) (core.Model, error) {
	var target modelTarget
	if json.Unmarshal(snapshot.Data, &target) != nil || target.ConnectionID == "" {
		return nil, core.ErrCorrupt
	}
	return s.gatewayModel(target, snapshot.Spec, owner, sessionID, false, "")
}

func (s *Service) seal(key, connectionID string) ([]byte, error) {
	if s.keyCipher == nil {
		return nil, bad("key_storage_unavailable", "服务器尚未配置模型密钥加密。")
	}
	nonce := make([]byte, s.keyCipher.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	return s.keyCipher.Seal(nonce, nonce, []byte(key), []byte(connectionID)), nil
}

func (s *Service) keyFor(c connection) (string, error) {
	if c.environment && len(c.key) == 0 && s.cfg.EnvironmentAPIKey != "" {
		return s.cfg.EnvironmentAPIKey, nil
	}
	if s.keyCipher != nil && len(c.key) > s.keyCipher.NonceSize() {
		size := s.keyCipher.NonceSize()
		plain, err := s.keyCipher.Open(nil, c.key[:size], c.key[size:], []byte(c.ID))
		if err == nil {
			return string(plain), nil
		}
	}
	return "", &core.ModelError{Code: "model_access"}
}

func makeCipher(key string) (cipher.AEAD, error) {
	if key == "" {
		return nil, nil
	}
	if len(key) < 24 {
		return nil, errors.New("AI_ENCRYPTION_KEY must have at least 24 characters")
	}
	digest := sha256.Sum256([]byte(key))
	block, err := aes.NewCipher(digest[:])
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func validateEndpoint(raw string, allowLocal bool) error {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || len(raw) > 500 {
		return bad("invalid_model_url", "请填写不含凭据、查询参数或片段的模型服务地址。")
	}
	if u.Scheme != "https" && !(allowLocal && u.Scheme == "http") {
		return bad("invalid_model_url", "模型服务必须使用 HTTPS。")
	}
	host := strings.ToLower(u.Hostname())
	if !allowLocal && (host == "localhost" || strings.HasSuffix(host, ".local") || !strings.Contains(host, ".") && !strings.Contains(host, ":")) {
		return bad("invalid_model_url", "不允许访问本地或内部地址。")
	}
	if ip, parseErr := netip.ParseAddr(host); parseErr == nil && !allowedIP(ip, allowLocal) {
		return bad("invalid_model_url", "不允许访问本地或内部地址。")
	}
	return nil
}

var blockedNetworks = []netip.Prefix{
	netip.MustParsePrefix("100.64.0.0/10"), netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("64:ff9b::/96"), netip.MustParsePrefix("64:ff9b:1::/48"),
}

func allowedIP(ip netip.Addr, allowLocal bool) bool {
	ip = ip.Unmap()
	if ip.IsLoopback() {
		return allowLocal
	}
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return false
	}
	for _, prefix := range blockedNetworks {
		if prefix.Contains(ip) {
			return false
		}
	}
	return true
}

func (s *Service) makeTransport() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.Proxy = nil
	t.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		if err != nil {
			return nil, err
		}
		dial := net.Dialer{Timeout: 10 * time.Second}
		for _, ip := range addrs {
			if !allowedIP(ip, s.cfg.AllowLocalProvider) {
				continue
			}
			conn, dErr := dial.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			if dErr == nil {
				return conn, nil
			}
			err = dErr
		}
		if err != nil {
			return nil, err
		}
		return nil, errors.New("provider endpoint is not reachable on an allowed network")
	}
	return t
}

type attemptKey struct{}

type outboundAttempt struct {
	id, owner, sessionID, runID string
	started                     bool
}

type gatewayTransport struct {
	service       *Service
	target        modelTarget
	allowDisabled bool
}

func (t gatewayTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	ctx := r.Context()
	attempt, ok := ctx.Value(attemptKey{}).(*outboundAttempt)
	if !ok || attempt.started {
		return nil, &core.ModelError{Code: "gateway_error"}
	}
	c, err := t.service.connection(ctx, t.target.ConnectionID)
	// An address edit changes where newly resolved calls go. Do not send new
	// credentials to a frozen address after the stored connection changes.
	if err != nil || !c.Enabled && !t.allowDisabled || c.BaseURL != t.target.BaseURL || !slices.Contains(c.Models, t.target.Model) {
		return nil, &core.ModelError{Code: "model_unavailable"}
	}
	if t.target.Purpose != "test" {
		var enabled bool
		err := t.service.db.QueryRow(ctx, `SELECT l.enabled AND COALESCE(u.enabled,true) AND a.active
		FROM app.ai_limits l CROSS JOIN app.users a LEFT JOIN app.ai_user_limits u ON a.id=u.user_id WHERE l.id=1 AND a.id=$1`,
			attempt.owner).Scan(&enabled)
		if err != nil || !enabled {
			return nil, &core.ModelError{Code: "disabled"}
		}
	}
	key, err := t.service.keyFor(c)
	if err != nil {
		return nil, err
	}
	if t.target.Purpose != "test" && t.target.Purpose != "title" && attempt.sessionID != "" {
		_ = t.service.db.QueryRow(ctx, `SELECT id::text FROM app.ai_runs WHERE session_id=$1 AND status IN ('waiting','streaming') ORDER BY created_at DESC LIMIT 1`, attempt.sessionID).
			Scan(&attempt.runID)
	}
	_, err = t.service.db.Exec(ctx, `INSERT INTO app.ai_calls(id,connection_id,user_id,run_id,purpose,model,status)
	VALUES($1,$2,NULLIF($3,'')::uuid,NULLIF($4,'')::uuid,$5,$6,'running')`, attempt.id, c.ID, attempt.owner, attempt.runID, t.target.Purpose, t.target.Model)
	if err != nil {
		return nil, &core.ModelError{Code: "gateway_error"}
	}
	attempt.started = true
	request := r.Clone(ctx)
	request.Header.Set("Authorization", "Bearer "+key)
	return t.service.transport.RoundTrip(request)
}

type gatewayModel struct {
	*completions.Model
	service   *Service
	target    modelTarget
	owner     string
	sessionID string
	runID     string
}

func (s *Service) gatewayModel(target modelTarget, spec core.ModelSpec, owner, sessionID string, allowDisabled bool, runID string) (core.Model, error) {
	if err := validateEndpoint(target.BaseURL, s.cfg.AllowLocalProvider); err != nil {
		return nil, &core.ModelError{Code: "model_unavailable"}
	}
	transport := gatewayTransport{service: s, target: target, allowDisabled: allowDisabled}
	config := models.Config{
		Spec: spec, Model: target.Model, BaseURL: target.BaseURL,
		ReplayScope: target.ConnectionID + ":" + target.BaseURL, Dialect: target.Dialect,
		HTTPClient: &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
	}
	if target.isDeepSeekFlash() {
		config.ReasoningFormat = models.ReasoningFormatThinkingType
		config.Reasoning = &models.ReasoningCapabilities{Toggle: new(true)}
	}
	adapter, err := completions.New(config)
	if err != nil {
		return nil, &core.ModelError{Code: "model_unavailable"}
	}
	return &gatewayModel{Model: adapter, service: s, target: target, owner: owner, sessionID: sessionID, runID: runID}, nil
}

func (m *gatewayModel) PrepareExecution(ctx context.Context, req core.Request) (core.RequestExecution, error) {
	x, err := m.Model.PrepareExecution(ctx, req)
	if err != nil {
		return nil, err
	}
	return core.RequestExecutionFunc(func(ctx context.Context, emit func(core.ModelEvent)) (core.Reply, error) {
		return m.invoke(ctx, emit, x.Stream)
	}), nil
}

func (m *gatewayModel) Stream(ctx context.Context, req core.Request, emit func(core.ModelEvent)) (core.Reply, error) {
	return m.invoke(ctx, emit, func(ctx context.Context, emit func(core.ModelEvent)) (core.Reply, error) {
		return m.Model.Stream(ctx, req, emit)
	})
}

func (m *gatewayModel) invoke(ctx context.Context, emit func(core.ModelEvent),
	run func(context.Context, func(core.ModelEvent)) (core.Reply, error)) (core.Reply, error) {
	attempt := outboundAttempt{id: uuid.NewString(), owner: m.owner, sessionID: m.sessionID, runID: m.runID}
	start := time.Now()
	reply, err := run(context.WithValue(ctx, attemptKey{}, &attempt), emit)
	if attempt.started {
		m.record(attempt.id, start, reply, err)
	}
	if err != nil {
		// Model libraries may include provider bodies in errors. Core persists
		// error strings; preserve classification without storing the raw cause.
		var modelErr *core.ModelError
		if errors.As(err, &modelErr) {
			err = &core.ModelError{Code: errorCode(err), Transient: modelErr.Transient,
				ContextOverflow: modelErr.ContextOverflow, RetryAfter: modelErr.RetryAfter}
		} else if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
			err = &core.ModelError{Code: "model_error"}
		}
		reply.Message.ErrorMessage = err.Error()
	}
	return reply, err
}

func (m *gatewayModel) record(id string, start time.Time, r core.Reply, err error) {
	status, code := "completed", ""
	switch {
	case errors.Is(err, context.Canceled) || r.Message.FinishReason == core.FinishCancelled:
		status, code = "cancelled", "cancelled"
	case err != nil || r.Message.Failed() || r.Message.FinishReason == core.FinishLength:
		status, code = "failed", errorCode(err)
	}
	var input, output *int
	if r.Usage.Available {
		if !r.Usage.InputMissing {
			input = &r.Usage.InputTokens
		}
		if !r.Usage.OutputMissing {
			output = &r.Usage.OutputTokens
		}
	}
	var amount *float64
	if m.target.InputPrice != nil && m.target.OutputPrice != nil && input != nil && output != nil {
		estimate := (*m.target.InputPrice*float64(*input) + *m.target.OutputPrice*float64(*output)) / 1_000_000
		amount = &estimate
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := m.service.db.Exec(ctx, `UPDATE app.ai_calls SET status=$2,latency_ms=$3,input_tokens=$4,output_tokens=$5,
		  cost_estimate=$6,error_code=NULLIF($7,'') WHERE id=$1`,
		id, status, time.Since(start).Milliseconds(), input, output, amount, code); err != nil {
		m.service.logger.Error("model call completion could not be recorded", "call_id", id)
	}
}

func (s *Service) invokeOnce(ctx context.Context, model core.Model, req core.Request) (core.Reply, error) {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	return provider.Call(ctx, model, req, nil)
}

func estimateTokens(ctx context.Context, model core.Model, request core.Request) (int, error) {
	if m, ok := model.(interface {
		EstimateTokens(context.Context, core.Request) (int, error)
	}); ok {
		return m.EstimateTokens(ctx, request)
	}
	return 0, core.ErrInvalid
}
