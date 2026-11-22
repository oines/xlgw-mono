package ai

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	core "github.com/oines/astral-core"
	"github.com/oines/astral-core/models/provider/openai/completions"
)

func (s *Service) listConnections(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(r.Context(), "SELECT "+connectionColumns+" FROM app.ai_connections ORDER BY created_at,id")
	if err != nil {
		s.fail(w, err)
		return
	}
	defer rows.Close()
	items := make([]connection, 0)
	for rows.Next() {
		c, err := s.scanConnection(rows)
		if err != nil {
			s.fail(w, err)
			return
		}
		items = append(items, c)
	}
	if err := rows.Err(); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

type connectionPatch struct {
	Name        *string       `json:"name"`
	Provider    *string       `json:"provider"`
	Protocol    *string       `json:"protocol"`
	BaseURL     *string       `json:"base_url"`
	APIKey      *string       `json:"api_key"`
	Enabled     *bool         `json:"enabled"`
	Models      *[]string     `json:"models"`
	InputPrice  nullablePrice `json:"input_price"`
	OutputPrice nullablePrice `json:"output_price"`
}

type nullablePrice struct {
	Present bool
	Value   *float64
}

func (n *nullablePrice) UnmarshalJSON(b []byte) error {
	n.Present = true
	return json.Unmarshal(b, &n.Value)
}

func (s *Service) addConnection(w http.ResponseWriter, r *http.Request) {
	c := connection{ID: uuid.NewString(), Provider: "compatible", Protocol: completions.Protocol, Enabled: true}
	s.saveConnection(w, r, c, true)
}

func (s *Service) editConnection(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validUUID(id) {
		s.fail(w, notFound())
		return
	}
	c, err := s.connection(r.Context(), id)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.saveConnection(w, r, c, false)
}

func validPrice(v *float64) bool { return v == nil || *v >= 0 && *v <= 1e6 && !math.IsNaN(*v) }

func (s *Service) saveConnection(w http.ResponseWriter, r *http.Request, c connection, create bool) {
	initialBase := c.BaseURL
	var p connectionPatch
	if err := decode(w, r, &p, false); err != nil {
		s.fail(w, err)
		return
	}
	if p.Name != nil {
		c.Name = strings.TrimSpace(*p.Name)
	}
	if p.Provider != nil {
		c.Provider = strings.ToLower(strings.TrimSpace(*p.Provider))
	}
	if p.Protocol != nil && *p.Protocol != "" {
		c.Protocol = *p.Protocol
	}
	if p.BaseURL != nil {
		c.BaseURL = strings.TrimRight(strings.TrimSpace(*p.BaseURL), "/")
	}
	if p.Enabled != nil {
		c.Enabled = *p.Enabled
	}
	if p.Models != nil {
		c.Models = nil
		for _, m := range *p.Models {
			m = strings.TrimSpace(m)
			if m == "" || len(m) > 200 || strings.ContainsAny(m, "\r\n\x00") {
				s.fail(w, bad("invalid_model", "模型名称无效。"))
				return
			}
			if !slices.Contains(c.Models, m) {
				c.Models = append(c.Models, m)
			}
		}
	}
	if p.InputPrice.Present {
		c.InputPrice = p.InputPrice.Value
	}
	if p.OutputPrice.Present {
		c.OutputPrice = p.OutputPrice.Value
	}
	if c.Name == "" || len(c.Name) > 200 || len(c.Provider) > 50 || c.Protocol != completions.Protocol ||
		len(c.Models) == 0 || len(c.Models) > 30 || !validPrice(c.InputPrice) || !validPrice(c.OutputPrice) {
		s.fail(w, bad("invalid_connection", "请填写连接名称、模型和有效的价格。"))
		return
	}
	if err := validateEndpoint(c.BaseURL, s.cfg.AllowLocalProvider); err != nil {
		s.fail(w, err)
		return
	}
	if p.APIKey != nil {
		key := strings.TrimSpace(*p.APIKey)
		if key != "" {
			if len(key) > 4096 || strings.ContainsAny(key, "\r\n\x00") {
				s.fail(w, bad("invalid_key", "模型密钥格式不正确。"))
				return
			}
			raw, err := s.seal(key, c.ID)
			if err != nil {
				s.fail(w, err)
				return
			}
			c.key, c.environment = raw, false
		}
	}
	if create && len(c.key) == 0 {
		// The deployment key is only valid for the configured deployment
		// provider. It must never be sent to an arbitrary configured endpoint.
		base := s.cfg.EnvironmentBaseURL
		if base == "" {
			base = "https://api.deepseek.com/v1"
		}
		c.environment = s.cfg.EnvironmentAPIKey != "" && c.BaseURL == strings.TrimRight(base, "/")
	}
	if !create && initialBase != c.BaseURL && c.HasKey && (p.APIKey == nil || strings.TrimSpace(*p.APIKey) == "") {
		s.fail(w, bad("key_origin", "修改服务地址需要填写该地址的模型密钥。"))
		return
	}
	if c.environment {
		base := s.cfg.EnvironmentBaseURL
		if base == "" {
			base = "https://api.deepseek.com/v1"
		}
		if c.BaseURL != strings.TrimRight(base, "/") {
			s.fail(w, bad("key_origin", "修改服务地址需要填写该地址的模型密钥。"))
			return
		}
	}
	ctx := r.Context()
	args := []any{c.ID, c.Name, c.Provider, c.Protocol, c.BaseURL, c.key, c.environment, c.Models, c.Enabled, c.InputPrice, c.OutputPrice}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	defer tx.Rollback(context.Background())
	action := "update_ai_connection"
	if create {
		action = "create_ai_connection"
		_, err = tx.Exec(ctx, `INSERT INTO app.ai_connections (id,name,provider,protocol,base_url,key_ciphertext,use_environment_key,models,enabled,input_price,output_price)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`, args...)
	} else {
		_, err = tx.Exec(ctx, `UPDATE app.ai_connections SET name=$2,provider=$3,protocol=$4,base_url=$5,key_ciphertext=$6,use_environment_key=$7,
		models=$8,enabled=$9,input_price=$10,output_price=$11,
		last_test_status=CASE WHEN base_url<>$5 OR models<>$8 OR key_ciphertext IS DISTINCT FROM $6 THEN NULL ELSE last_test_status END,
		last_test_at=CASE WHEN base_url<>$5 OR models<>$8 OR key_ciphertext IS DISTINCT FROM $6 THEN NULL ELSE last_test_at END,
		last_test_error=CASE WHEN base_url<>$5 OR models<>$8 OR key_ciphertext IS DISTINCT FROM $6 THEN NULL ELSE last_test_error END
		WHERE id=$1`, args...)
	}
	if err == nil {
		err = auditAI(ctx, tx, s.cfg.UserID(r), c.ID, action)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		s.fail(w, err)
		return
	}
	result, err := s.connection(ctx, c.ID)
	if err != nil {
		s.fail(w, err)
		return
	}
	status := 200
	if create {
		status = 201
	}
	writeJSON(w, status, result)
}

func (s *Service) testConnection(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validUUID(id) {
		s.fail(w, notFound())
		return
	}
	ctx := r.Context()
	c, err := s.connection(ctx, id)
	if err != nil {
		s.fail(w, err)
		return
	}
	if !s.acquireExtra(ctx) {
		s.fail(w, unavailable("busy", "服务正忙，请稍后再试。"))
		return
	}
	defer s.releaseExtra()
	status := "completed"
	code := ""
	if !c.HasKey || len(c.Models) == 0 {
		status, code = "failed", "model_access"
	} else {
		target := newTarget(c, "test", c.Models[0])
		request := core.Request{Messages: []core.Message{core.User("Reply with OK.")}, MaxOutputTokens: 16}
		if target.isDeepSeekFlash() {
			request.Options.Reasoning.Enabled = new(true)
			request.MaxOutputTokens = 1024
		}
		m, err := s.gatewayModel(target, core.ModelSpec{ID: "test/" + c.ID, ContextWindow: 4096, MaxOutputTokens: request.MaxOutputTokens}, s.cfg.UserID(r), "", true, "")
		if err == nil {
			_, err = s.invokeOnce(ctx, m, request)
		}
		if err != nil {
			status, code = "failed", errorCode(err)
		}
	}
	recordCtx, done := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer done()
	_, err = s.db.Exec(recordCtx, "UPDATE app.ai_connections SET last_test_status=$2,last_test_at=now(),last_test_error=NULLIF($3,'') WHERE id=$1", c.ID, status, code)
	if err != nil {
		s.fail(w, err)
		return
	}
	c, err = s.connection(recordCtx, c.ID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, c)
}

func (s *Service) listRoutes(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(r.Context(), "SELECT "+routeColumns+" FROM app.ai_routes ORDER BY purpose")
	if err != nil {
		s.fail(w, err)
		return
	}
	defer rows.Close()
	items := []route{}
	for rows.Next() {
		value, err := scanRoute(rows)
		if err != nil {
			s.fail(w, err)
			return
		}
		items = append(items, value)
	}
	if err := rows.Err(); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (s *Service) setRoutes(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Items []route `json:"items"`
	}
	if err := decode(w, r, &body, false); err != nil {
		s.fail(w, err)
		return
	}
	if len(body.Items) == 0 || len(body.Items) > 3 {
		s.fail(w, bad("invalid_routes", "请选择需要保存的模型用途。"))
		return
	}
	ctx := r.Context()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	defer tx.Rollback(context.Background())
	seen := map[string]bool{}
	fail := bad("invalid_route", "请选择有效连接、模型和上下文参数。")
	modelAvailable := func(id, model string) bool {
		if !validUUID(id) || model == "" {
			return false
		}
		var found bool
		return tx.QueryRow(ctx, "SELECT $2=ANY(models) FROM app.ai_connections WHERE id=$1", id, model).Scan(&found) == nil && found
	}
	for i := range body.Items {
		v := &body.Items[i]
		if v.FallbackID != nil && *v.FallbackID == "" {
			v.FallbackID = nil
		}
		if v.FallbackModel != nil && *v.FallbackModel == "" {
			v.FallbackModel = nil
		}
		if seen[v.Purpose] || v.Purpose != "chat" && v.Purpose != "summary" && v.Purpose != "title" ||
			v.ContextWindow < 1024 || v.ContextWindow > 2_000_000 || v.MaxOutputTokens < 1 || v.MaxOutputTokens > 64_000 ||
			v.MaxOutputTokens+32 >= v.ContextWindow || v.Temperature < 0 || v.Temperature > 2 || math.IsNaN(v.Temperature) ||
			!modelAvailable(v.ConnectionID, v.Model) || (v.FallbackID == nil) != (v.FallbackModel == nil) ||
			v.FallbackID != nil && !modelAvailable(*v.FallbackID, *v.FallbackModel) {
			s.fail(w, fail)
			return
		}
		seen[v.Purpose] = true
		_, err := tx.Exec(ctx, `INSERT INTO app.ai_routes(purpose,connection_id,model,fallback_connection_id,fallback_model,temperature,max_output_tokens,context_window)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8)
		ON CONFLICT(purpose) DO UPDATE SET connection_id=excluded.connection_id,model=excluded.model,fallback_connection_id=excluded.fallback_connection_id,
		fallback_model=excluded.fallback_model,temperature=excluded.temperature,max_output_tokens=excluded.max_output_tokens,context_window=excluded.context_window`,
			v.Purpose, v.ConnectionID, v.Model, v.FallbackID, v.FallbackModel, v.Temperature, v.MaxOutputTokens, v.ContextWindow)
		if err != nil {
			s.fail(w, err)
			return
		}
	}
	if err := auditAI(ctx, tx, s.cfg.UserID(r), s.cfg.UserID(r), "update_ai_routes"); err != nil {
		s.fail(w, err)
		return
	}
	if err := tx.Commit(ctx); err != nil {
		s.fail(w, err)
		return
	}
	s.listRoutes(w, r)
}

type modelCall struct {
	ID           string    `json:"id"`
	ConnectionID string    `json:"connection_id"`
	Purpose      string    `json:"purpose"`
	Model        string    `json:"model"`
	UserID       *string   `json:"user_id,omitempty"`
	RunID        *string   `json:"run_id,omitempty"`
	Status       string    `json:"status"`
	Latency      int64     `json:"latency_ms"`
	Input        *int      `json:"input_tokens"`
	Output       *int      `json:"output_tokens"`
	Cost         *float64  `json:"cost_estimate"`
	Error        *string   `json:"error_code,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
}

const callColumns = "id::text,connection_id::text,purpose,model,user_id::text,run_id::text,status,latency_ms,input_tokens,output_tokens,cost_estimate::float8,error_code,created_at"

func scanCall(row interface{ Scan(...any) error }) (a modelCall, err error) {
	err = row.Scan(&a.ID, &a.ConnectionID, &a.Purpose, &a.Model, &a.UserID, &a.RunID, &a.Status, &a.Latency, &a.Input, &a.Output, &a.Cost, &a.Error, &a.CreatedAt)
	return
}

func (s *Service) listCalls(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	rows, err := s.db.Query(r.Context(), "SELECT "+callColumns+` FROM app.ai_calls WHERE ($1='' OR status=$1)
		AND ($2='' OR purpose=$2) AND ($3='' OR error_code=$3) ORDER BY created_at DESC LIMIT $4`,
		q.Get("status"), q.Get("purpose"), q.Get("error_code"), pageLimit(r, 100, 500))
	if err != nil {
		s.fail(w, err)
		return
	}
	defer rows.Close()
	items := []modelCall{}
	for rows.Next() {
		a, err := scanCall(rows)
		if err != nil {
			s.fail(w, err)
			return
		}
		items = append(items, a)
	}
	if err := rows.Err(); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (s *Service) getCall(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validUUID(id) {
		s.fail(w, notFound())
		return
	}
	row, err := scanCall(s.db.QueryRow(r.Context(), "SELECT "+callColumns+" FROM app.ai_calls WHERE id=$1", id))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, row)
}

func (s *Service) getLimits(w http.ResponseWriter, r *http.Request) {
	v, err := getLimits(r.Context(), s.db, "")
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, v)
}

func (s *Service) setLimits(w http.ResponseWriter, r *http.Request) {
	var v limits
	if err := decode(w, r, &v, false); err != nil {
		s.fail(w, err)
		return
	}
	if v.DailyLimit < 0 || v.DailyLimit > 5000 || v.PerMinute < 0 || v.PerMinute > 120 || v.GlobalConcurrency < 1 || v.GlobalConcurrency > 100 {
		s.fail(w, bad("invalid_limits", "请检查限额和并发数。"))
		return
	}
	ctx := r.Context()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	defer tx.Rollback(context.Background())
	_, err = tx.Exec(ctx, "UPDATE app.ai_limits SET enabled=$1,daily_limit=$2,per_minute=$3,global_concurrency=$4 WHERE id=1",
		v.Enabled, v.DailyLimit, v.PerMinute, v.GlobalConcurrency)
	if err == nil {
		err = auditAI(ctx, tx, s.cfg.UserID(r), s.cfg.UserID(r), "update_ai_limits")
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, v)
}

type userLimits struct {
	UserID     string `json:"user_id"`
	Enabled    *bool  `json:"enabled"`
	DailyLimit *int   `json:"daily_limit"`
	PerMinute  *int   `json:"per_minute"`
}

func (s *Service) listUserLimits(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(r.Context(), "SELECT user_id::text,enabled,daily_limit,per_minute FROM app.ai_user_limits ORDER BY user_id LIMIT $1", pageLimit(r, 100, 500))
	if err != nil {
		s.fail(w, err)
		return
	}
	defer rows.Close()
	items := []userLimits{}
	for rows.Next() {
		var v userLimits
		if err := rows.Scan(&v.UserID, &v.Enabled, &v.DailyLimit, &v.PerMinute); err != nil {
			s.fail(w, err)
			return
		}
		items = append(items, v)
	}
	if err := rows.Err(); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (s *Service) setUserLimits(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validUUID(id) {
		s.fail(w, notFound())
		return
	}
	var v userLimits
	if err := decode(w, r, &v, false); err != nil {
		s.fail(w, err)
		return
	}
	if v.DailyLimit != nil && (*v.DailyLimit < 0 || *v.DailyLimit > 5000) || v.PerMinute != nil && (*v.PerMinute < 0 || *v.PerMinute > 120) {
		s.fail(w, bad("invalid_limits", "请检查个人限额与频次。"))
		return
	}
	ctx := r.Context()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		s.fail(w, err)
		return
	}
	defer tx.Rollback(context.Background())
	var exists bool
	err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM app.users WHERE id=$1)", id).Scan(&exists)
	if err != nil || !exists {
		if err == nil {
			err = pgx.ErrNoRows
		}
		s.fail(w, err)
		return
	}
	if v.Enabled == nil && v.DailyLimit == nil && v.PerMinute == nil {
		_, err = tx.Exec(ctx, "DELETE FROM app.ai_user_limits WHERE user_id=$1", id)
	} else {
		_, err = tx.Exec(ctx, `INSERT INTO app.ai_user_limits(user_id,enabled,daily_limit,per_minute) VALUES($1,$2,$3,$4)
		ON CONFLICT(user_id) DO UPDATE SET enabled=excluded.enabled,daily_limit=excluded.daily_limit,per_minute=excluded.per_minute`, id, v.Enabled, v.DailyLimit, v.PerMinute)
	}
	if err == nil {
		err = auditAI(ctx, tx, s.cfg.UserID(r), id, "update_ai_user_limits")
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	if err != nil {
		s.fail(w, err)
		return
	}
	v.UserID = id
	writeJSON(w, 200, v)
}

func auditAI(ctx context.Context, tx pgx.Tx, actor, target, action string) error {
	_, err := tx.Exec(ctx, `INSERT INTO app.history(kind,object_id,actor_id,action)
	VALUES('operation',$1,NULLIF($2,'')::uuid,$3)`, target, actor, action)
	return err
}
