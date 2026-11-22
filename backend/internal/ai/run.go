package ai

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	core "github.com/oines/astral-core"
	"github.com/oines/xlgw-mono/backend/internal/safety"
)

type Action struct {
	Kind        string `json:"kind"`
	ID          string `json:"id,omitempty"`
	StaffID     string `json:"staff_id,omitempty"`
	Title       string `json:"title"`
	Description string `json:"description,omitempty"`
	URL         string `json:"url,omitempty"`
}

type Run struct {
	ID             string    `json:"id"`
	InputID        string    `json:"input_id"`
	ConversationID string    `json:"conversation_id"`
	Status         string    `json:"status"`
	Error          string    `json:"error,omitempty"`
	Risk           bool      `json:"risk,omitempty"`
	Actions        []Action  `json:"actions,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	userID         string
	sessionID      string
	coreID         string
	retryID        string
	charged        bool
	stopRequested  bool
}

const runColumns = `id::text,input_id,conversation_id::text,status,COALESCE(error_code,''),risk,actions,created_at,
user_id::text,session_id,core_run_id,COALESCE(retry_id,''),charged,stop_requested`

func scanRun(row interface{ Scan(...any) error }) (run Run, err error) {
	var code string
	err = row.Scan(&run.ID, &run.InputID, &run.ConversationID, &run.Status, &code, &run.Risk, &run.Actions, &run.CreatedAt,
		&run.userID, &run.sessionID, &run.coreID, &run.retryID, &run.charged, &run.stopRequested)
	if code != "" {
		run.Error = runMessage(code)
	}
	return
}

func terminal(status string) bool { return status != "waiting" && status != "streaming" }

func (s *Service) latestRun(ctx context.Context, owner, conversation string) (Run, error) {
	return scanRun(s.db.QueryRow(ctx, "SELECT "+runColumns+" FROM app.ai_runs WHERE user_id=$1 AND conversation_id=$2 ORDER BY created_at DESC LIMIT 1", owner, conversation))
}

func (s *Service) findRun(ctx context.Context, owner, id string) (Run, error) {
	if !validUUID(id) {
		return Run{}, notFound()
	}
	return scanRun(s.db.QueryRow(ctx, "SELECT "+runColumns+" FROM app.ai_runs WHERE user_id=$1 AND id=$2", owner, id))
}

type limits struct {
	Enabled           bool `json:"enabled"`
	DailyLimit        int  `json:"daily_limit"`
	PerMinute         int  `json:"per_minute"`
	GlobalConcurrency int  `json:"global_concurrency"`
}

func getLimits(ctx context.Context, q rowQuery, owner string) (l limits, err error) {
	if owner == "" {
		err = q.QueryRow(ctx, "SELECT enabled,daily_limit,per_minute,global_concurrency FROM app.ai_limits WHERE id=1").
			Scan(&l.Enabled, &l.DailyLimit, &l.PerMinute, &l.GlobalConcurrency)
	} else {
		err = q.QueryRow(ctx, `SELECT l.enabled AND COALESCE(u.enabled,true) AND a.active,
		COALESCE(u.daily_limit,l.daily_limit),COALESCE(u.per_minute,l.per_minute),l.global_concurrency
		FROM app.ai_limits l CROSS JOIN app.users a LEFT JOIN app.ai_user_limits u ON a.id=u.user_id
		WHERE l.id=1 AND a.id=$1`, owner).Scan(&l.Enabled, &l.DailyLimit, &l.PerMinute, &l.GlobalConcurrency)
	}
	return
}

func quotaDay(ctx context.Context, q rowQuery, t time.Time) (date string, reset time.Time, err error) {
	var zone string
	if err := q.QueryRow(ctx, "SELECT timezone FROM app.settings WHERE id=1").Scan(&zone); err != nil {
		return "", time.Time{}, err
	}
	loc, err := time.LoadLocation(zone)
	if err != nil {
		return "", time.Time{}, err
	}
	y, m, d := t.In(loc).Date()
	day := time.Date(y, m, d, 0, 0, 0, 0, loc)
	return day.Format("2006-01-02"), day.AddDate(0, 0, 1), nil
}

func chargedToday(ctx context.Context, q rowQuery, owner, date string) (int, error) {
	var used int
	err := q.QueryRow(ctx, "SELECT count(*) FROM app.ai_admissions WHERE user_id=$1 AND charged AND charge_date=$2::date", owner, date).Scan(&used)
	return used, err
}

func (s *Service) quota(w http.ResponseWriter, r *http.Request) {
	ctx, owner := r.Context(), s.cfg.UserID(r)
	l, err := getLimits(ctx, s.db, owner)
	if err != nil {
		s.fail(w, err)
		return
	}
	date, reset, err := quotaDay(ctx, s.db, time.Now())
	if err != nil {
		s.fail(w, err)
		return
	}
	used, err := chargedToday(ctx, s.db, owner, date)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"daily_limit": l.DailyLimit, "used": used,
		"remaining": max(0, l.DailyLimit-used), "per_minute": l.PerMinute,
		"enabled": l.Enabled && l.DailyLimit > 0 && l.PerMinute > 0, "reset_at": reset})
}

func (s *Service) send(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ID   string `json:"id"`
		Text string `json:"text"`
	}
	if err := decode(w, r, &body, false); err != nil {
		s.fail(w, err)
		return
	}
	body.Text = strings.TrimSpace(body.Text)
	if !validInputID(body.ID) || body.Text == "" || utf8.RuneCountInString(body.Text) > 4000 {
		s.fail(w, bad("invalid_input", "请输入 1 到 4000 字的消息。"))
		return
	}
	c, err := s.conversation(r.Context(), s.cfg.UserID(r), r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	run, err := s.admit(r.Context(), c, body.ID, body.Text, "")
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 202, run)
}

func (s *Service) retry(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ID string `json:"id"`
	}
	if err := decode(w, r, &body, false); err != nil {
		s.fail(w, err)
		return
	}
	inputID := r.PathValue("id")
	if !validInputID(body.ID) || !validInputID(inputID) {
		s.fail(w, bad("invalid_input", "重试标识无效。"))
		return
	}
	owner, ctx := s.cfg.UserID(r), r.Context()
	var convID string
	err := s.db.QueryRow(ctx, `SELECT i.conversation_id::text FROM app.ai_inputs i
		JOIN app.ai_conversations c ON c.id=i.conversation_id WHERE c.user_id=$1 AND i.id=$2`, owner, inputID).Scan(&convID)
	if err != nil {
		s.fail(w, err)
		return
	}
	c, err := s.conversation(ctx, owner, convID)
	if err != nil {
		s.fail(w, err)
		return
	}
	run, err := s.admit(ctx, c, inputID, "", body.ID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 202, run)
}

func (s *Service) admit(ctx context.Context, c Conversation, input, text, retryID string) (Run, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx.Err() != nil {
		return Run{}, unavailable("busy", "服务正在结束。")
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Run{}, err
	}
	defer tx.Rollback(context.Background())

	var deleting bool
	if err = tx.QueryRow(ctx, `SELECT session_id,deleting FROM app.ai_conversations
		WHERE id=$1 AND user_id=$2 AND (expires_at IS NULL OR expires_at>now()) FOR UPDATE`, c.ID, c.owner).
		Scan(&c.sessionID, &deleting); err != nil || deleting {
		return Run{}, notFound()
	}
	old, err := scanRun(tx.QueryRow(ctx, "SELECT "+runColumns+` FROM app.ai_runs
		WHERE conversation_id=$1 AND input_id=$2 AND retry_id IS NOT DISTINCT FROM NULLIF($3,'')::text`, c.ID, input, retryID))
	if err == nil {
		if retryID == "" {
			var stored string
			if err := tx.QueryRow(ctx, "SELECT digest FROM app.ai_inputs WHERE id=$1", input).Scan(&stored); err != nil {
				return Run{}, err
			}
			if stored != digestText(text) {
				return Run{}, conflict("input_conflict", "同一消息标识已用于不同内容。")
			}
		}
		return old, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Run{}, err
	}
	if s.users[c.owner] || s.active[c.ID] != nil {
		return Run{}, conflict("busy", "已有一条回复正在生成。")
	}
	l, err := getLimits(ctx, tx, c.owner)
	if err != nil {
		return Run{}, err
	}
	if !l.Enabled || l.DailyLimit == 0 || l.PerMinute == 0 {
		return Run{}, &apiError{Status: 403, Code: "disabled", Message: "AI 功能暂不可用。你仍可查看历史与校内支持。"}
	}
	if s.slots >= l.GlobalConcurrency {
		return Run{}, unavailable("busy", "服务正忙，请稍后再试。")
	}
	charge := true
	if retryID != "" {
		var previousID, status string
		if err := tx.QueryRow(ctx, `SELECT r.input_id,r.status FROM app.ai_runs r JOIN app.ai_inputs i ON i.id=r.input_id
			WHERE r.conversation_id=$1 ORDER BY i.position DESC,r.created_at DESC LIMIT 1`, c.ID).
			Scan(&previousID, &status); err != nil {
			return Run{}, err
		}
		if previousID != input || status != "failed" && status != "cancelled" {
			return Run{}, conflict("not_retryable", "只能重试当前会话最近一条未完成的回复。")
		}
		var alreadyCharged bool
		if err := tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM app.ai_runs WHERE input_id=$1 AND charged)", input).Scan(&alreadyCharged); err != nil {
			return Run{}, err
		}
		charge = !alreadyCharged
	}
	now := time.Now()
	date, reset, err := quotaDay(ctx, tx, now)
	if err != nil {
		return Run{}, err
	}
	used, err := chargedToday(ctx, tx, c.owner, date)
	if err != nil {
		return Run{}, err
	}
	if charge && used >= l.DailyLimit {
		return Run{}, &apiError{Status: 429, Code: "quota_exhausted", Message: "今日次数已用完。", RetryAt: &reset}
	}
	var sent int
	var oldest *time.Time
	if err = tx.QueryRow(ctx, `SELECT count(*),min(created_at) FROM app.ai_admissions WHERE user_id=$1 AND created_at>$2`,
		c.owner, now.Add(-time.Minute)).Scan(&sent, &oldest); err != nil {
		return Run{}, err
	}
	if sent >= l.PerMinute {
		retryAt := oldest.Add(time.Minute)
		return Run{}, &apiError{Status: 429, Code: "rate_limited", Message: "发送得有点快，请稍后再试。", RetryAt: &retryAt}
	}
	var risk bool
	if retryID == "" {
		risk = safety.ExplicitSignal(text)
		_, err = tx.Exec(ctx, `INSERT INTO app.ai_inputs(id,conversation_id,digest,body) VALUES($1,$2,$3,$4)`, input, c.ID, digestText(text), text)
		if err != nil {
			return Run{}, storeError(err)
		}
	} else if err := tx.QueryRow(ctx, "SELECT risk FROM app.ai_runs WHERE input_id=$1 ORDER BY created_at DESC LIMIT 1", input).Scan(&risk); err != nil {
		return Run{}, err
	}
	if !risk {
		_, err := s.resolveWith(ctx, tx, core.ModelSelection{ID: "chat"}, c.owner, c.sessionID)
		if err != nil {
			return Run{}, unavailable("model_unavailable", "模型还未配置或暂不可用。你仍可使用校内支持。")
		}
	}
	run, err := scanRun(tx.QueryRow(ctx, `INSERT INTO app.ai_runs(id,input_id,conversation_id,user_id,session_id,retry_id,status,charged,charge_date,risk)
	VALUES($1,$2,$3,$4,$5,NULLIF($6,'')::text,'waiting',$7,$8::date,$9) RETURNING `+runColumns,
		uuid.NewString(), input, c.ID, c.owner, c.sessionID, retryID, charge, date, risk))
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO app.ai_admissions(id,user_id,is_retry,charge_date,charged,created_at)
				VALUES($1,$2,$3,$4::date,$5,$6)`, run.ID, c.owner, retryID != "", date, charge, run.CreatedAt)
	}
	if err == nil {
		_, err = tx.Exec(ctx, "UPDATE app.ai_conversations SET updated_at=now() WHERE id=$1", c.ID)
	}
	if err != nil {
		return Run{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return Run{}, err
	}
	s.launch(c, run)
	return run, nil
}

// launch is called with the admission mutex held. No provider call runs under it.
func (s *Service) launch(c Conversation, run Run) {
	ctx, stop := context.WithTimeout(s.ctx, 90*time.Second)
	a := &activation{runID: run.ID, userID: c.owner, convID: c.ID, stop: stop, view: run, ready: make(chan struct{}),
		listeners: make(map[int]chan streamEvent)}
	s.active[c.ID], s.users[c.owner] = a, true
	s.slots++
	s.bg.Go(func() { s.executeRun(ctx, a, c, run) })
}

func (s *Service) sessionConfig(owner, sid string) core.Config {
	return core.Config{
		Store:                  s.store,
		Selection:              core.ModelSelection{ID: "chat"},
		SystemPrompt:           companionPrompt,
		Tools:                  s.tools(owner),
		MaxTurns:               5,
		Retry:                  core.RetryPolicy{MaxAttempts: 2, InitialBackoff: time.Second, MaxBackoff: time.Second, RequestTimeout: 45 * time.Second},
		Budget:                 core.BudgetPolicy{SafetyMargin: 16},
		Compaction:             core.CompactionPolicy{ModelID: "summary", ReserveTokens: 1600, KeepRecentTokens: 2400},
		EstimateTokensReadOnly: estimateTokens,
		ResolveModel: func(ctx context.Context, selection core.ModelSelection) (core.ResolvedModel, error) {
			return s.resolve(ctx, selection, owner, sid)
		},
		RestoreModel: func(ctx context.Context, snapshot core.ModelSnapshot) (core.Model, error) {
			return s.restore(ctx, snapshot, owner, sid)
		},
	}
}

func (s *Service) getSession(ctx context.Context, owner, sid string) (*core.Session, error) {
	config := s.sessionConfig(owner, sid)
	session, err := core.OpenSession(ctx, config, sid)
	if errors.Is(err, core.ErrNotFound) {
		return core.NewSession(ctx, config, core.SessionOptions{ID: sid})
	}
	return session, err
}

// executeRun owns exactly one conversation handle at a time. Forking for an
// explicit retry uses the original user entry as the inclusive boundary.
func (s *Service) executeRun(ctx context.Context, a *activation, c Conversation, run Run) {
	defer func() {
		a.stop()
		s.mu.Lock()
		delete(s.active, c.ID)
		delete(s.users, c.owner)
		s.slots--
		close(a.ready)
		s.mu.Unlock()
	}()
	var session *core.Session
	var inputText *string
	var entryID string
	err := s.db.QueryRow(ctx, "SELECT body,core_entry_id FROM app.ai_inputs WHERE id=$1", run.InputID).Scan(&inputText, &entryID)
	finish := func(status, code string) { s.finishRun(a, status, code) }
	if err != nil {
		if ctx.Err() != nil && s.userStopped(run.ID) {
			finish("cancelled", "")
		} else {
			finish("failed", errorCode(err))
		}
		return
	}
	if run.Risk {
		// Keep the crisis response on the Host. It neither waits for a model
		// nor independently contacts counselors or third parties.
		s.executeSafety(ctx, a, run, inputText, entryID)
		return
	}
	if run.retryID != "" && run.sessionID != "retry-"+run.ID && run.coreID == "" {
		src, openErr := s.getSession(ctx, c.owner, c.sessionID)
		if openErr != nil {
			finish("failed", errorCode(openErr))
			return
		}
		id := "retry-" + run.ID
		oldState := src.Snapshot().State
		head := entryID
		if head == "" {
			head = oldState.Branch.HeadID
		}
		_, err = s.store.Fork(ctx, core.ForkRequest{SourceID: c.sessionID, SourceRolloutID: oldState.RolloutID,
			TargetID: id, HeadID: head, Mode: core.ForkDetached})
		_ = src.Close(context.Background())
		if err == nil {
			err = s.moveBranch(ctx, c.ID, run.ID, id)
		}
		if err != nil {
			_ = s.store.DeleteSession(context.Background(), id)
			finish("failed", errorCode(err))
			return
		}
		run.sessionID = id
	}
	session, err = s.getSession(ctx, c.owner, run.sessionID)
	if err != nil {
		if ctx.Err() != nil && s.userStopped(run.ID) {
			finish("cancelled", "")
		} else {
			finish("failed", errorCode(err))
		}
		return
	}
	defer func() {
		closeCtx, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		_ = session.Close(closeCtx)
	}()
	a.session = session
	sub := session.Subscribe(256)
	collectorDone := make(chan struct{})
	go func() {
		defer close(collectorDone)
		for event := range sub.C {
			s.handleCoreEvent(a, event)
		}
	}()
	drainEvents := func() { sub.Close(); <-collectorDone }
	defer drainEvents()
	receipt, receivedErr := session.LookupInput(ctx, run.InputID)
	state := session.Snapshot().State
	if last := state.LastRun; last != nil && last.Status != "started" &&
		(last.ID == run.coreID || run.coreID == "" && (receivedErr == nil || run.sessionID == "retry-"+run.ID)) {
		s.rememberInput(run, receipt)
		status, code := last.Status, ""
		if status == "completed" {
			head, err := s.store.Get(ctx, state.RolloutID, state.Branch.LastMessageID)
			if err != nil || visibleText(head.Entry.Message) == "" {
				status, code = "failed", "interrupted"
			}
		}
		if status == "cancelled" && !s.userStopped(run.ID) || status == "failed" {
			status, code = "failed", "interrupted"
		}
		if status != "completed" && receipt.State == core.InputPending && !s.storePendingInput(run, session) {
			code = "interrupted"
		}
		finish(status, code)
		return
	}
	var coreRun *core.Run
	switch {
	case receivedErr == nil || run.retryID != "" && entryID != "":
		coreRun, err = session.Continue(ctx)
	case errors.Is(receivedErr, core.ErrNotFound) && inputText != nil:
		var p core.PromptResult
		p, err = session.Prompt(ctx, core.Input{ID: run.InputID, Message: core.User(*inputText)})
		coreRun = p.Run
	default:
		err = receivedErr
	}
	if err != nil || coreRun == nil {
		if ctx.Err() != nil && s.userStopped(run.ID) {
			finish("cancelled", "")
		} else {
			finish("failed", errorCode(err))
		}
		return
	}
	s.mu.Lock()
	a.run = coreRun
	s.mu.Unlock()
	ctxForUpdate, updateCancel := context.WithTimeout(context.Background(), 5*time.Second)
	_, _ = s.db.Exec(ctxForUpdate, "UPDATE app.ai_runs SET core_run_id=$2 WHERE id=$1", run.ID, coreRun.ID())
	updateCancel()
	untilDone := context.AfterFunc(ctx, coreRun.Cancel)
	result, err := coreRun.Wait(context.Background())
	untilDone()
	drainEvents()
	queryCtx, done := context.WithTimeout(context.Background(), 5*time.Second)
	receipt, _ = session.LookupInput(queryCtx, run.InputID)
	done()
	s.rememberInput(run, receipt)
	// On process shutdown leave a non-terminal Host row. The next process
	// can reconcile the Core terminal commit and any already recorded reply.
	if s.ctx.Err() != nil && result.Status != "completed" && !s.userStopped(run.ID) {
		return
	}
	if result.Status != "completed" && receipt.State == core.InputPending {
		s.storePendingInput(run, session)
	}
	switch {
	case result.Status == "completed" && visibleText(result.LastMessage) != "":
		finish("completed", "")
		if inputText != nil {
			s.maybeTitle(c, run, *inputText)
		}
	case s.userStopped(run.ID):
		finish("cancelled", "")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		finish("failed", "request_timeout")
	default:
		finish("failed", errorCode(err))
	}
}

// A terminal operation must not leave an old pending user turn queued ahead
// of the next user message. If its original input never reached history, a
// later explicit retry forks at the current head and admits that input anew.
func (s *Service) storePendingInput(run Run, session *core.Session) bool {
	ctx, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	if err := session.ClearQueuedInput(ctx, run.InputID); err != nil {
		s.logger.Error("unable to clear interrupted unconsumed input", "run_id", run.ID)
		return false
	}
	return true
}

func (s *Service) rememberInput(run Run, r core.InputReceipt) {
	if r.EntryID == "" {
		return
	}
	ctx, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	_, _ = s.db.Exec(ctx, "UPDATE app.ai_inputs SET core_entry_id=$2,body=NULL WHERE id=$1", run.InputID, r.EntryID)
}

func (s *Service) moveBranch(ctx context.Context, convID, runID, id string) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	tag, err := tx.Exec(ctx, "UPDATE app.ai_conversations SET session_id=$2 WHERE id=$1 AND NOT deleting", convID, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return notFound()
	}
	if _, err = tx.Exec(ctx, "UPDATE app.ai_runs SET session_id=$2 WHERE id=$1", runID, id); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *Service) userStopped(id string) bool {
	ctx, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	var stopped bool
	_ = s.db.QueryRow(ctx, "SELECT stop_requested FROM app.ai_runs WHERE id=$1", id).Scan(&stopped)
	return stopped
}

func (s *Service) finishRun(a *activation, status, code string) {
	ctx, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	a.mu.Lock()
	actions, _ := json.Marshal(a.view.Actions)
	if string(actions) == "null" {
		actions = []byte("[]")
	}
	a.mu.Unlock()
	run, err := s.persistRunStatus(ctx, a.runID, status, code, actions)
	if err != nil {
		s.logger.Error("unable to finish AI run", "run_id", a.runID)
		a.mu.Lock()
		run = a.view
		a.mu.Unlock()
		run.Status, run.Error = "failed", runMessage("model_error")
	}
	a.broadcast(streamEvent{kind: "state", Run: run})
}

func (s *Service) persistRunStatus(ctx context.Context, id, status, code string, actions []byte) (Run, error) {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return Run{}, err
	}
	defer tx.Rollback(context.Background())
	run, err := scanRun(tx.QueryRow(ctx, `UPDATE app.ai_runs SET status=$2,error_code=NULLIF($3,''),
		charged=charged AND $2<>'failed',actions=COALESCE($4::jsonb,actions),updated_at=now()
		WHERE id=$1 RETURNING `+runColumns, id, status, code, actions))
	if err == nil && status == "failed" {
		_, err = tx.Exec(ctx, "UPDATE app.ai_admissions SET charged=false WHERE id=$1 AND charged", id)
	}
	if err == nil {
		err = tx.Commit(ctx)
	}
	return run, err
}

func (s *Service) currentRun(run Run) Run {
	s.mu.Lock()
	defer s.mu.Unlock()
	if a := s.active[run.ConversationID]; a != nil && a.runID == run.ID {
		a.mu.Lock()
		defer a.mu.Unlock()
		return a.view
	}
	return run
}

func (s *Service) getRun(w http.ResponseWriter, r *http.Request) {
	run, err := s.findRun(r.Context(), s.cfg.UserID(r), r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, s.currentRun(run))
}

func (s *Service) stopRun(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	run, err := s.findRun(ctx, s.cfg.UserID(r), r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	if !terminal(run.Status) {
		_, err := s.db.Exec(ctx, "UPDATE app.ai_runs SET stop_requested=true WHERE id=$1 AND status IN ('waiting','streaming')", run.ID)
		if err != nil {
			s.fail(w, err)
			return
		}
		s.mu.Lock()
		a := s.active[run.ConversationID]
		if a != nil && a.runID == run.ID {
			a.stop()
			if a.run != nil {
				a.run.Cancel()
			}
		}
		s.mu.Unlock()
	}
	writeJSON(w, 200, run)
}

func (s *Service) recover(ctx context.Context) error {
	// Call records survive a process crash. An interrupted provider's cost is unknown.
	if _, err := s.db.Exec(ctx, "UPDATE app.ai_calls SET status='failed',error_code='interrupted' WHERE status='running'"); err != nil {
		return err
	}
	rows, err := s.db.Query(ctx, "SELECT "+runColumns+" FROM app.ai_runs WHERE status IN ('waiting','streaming') ORDER BY created_at")
	if err != nil {
		return err
	}
	pending := []Run{}
	for rows.Next() {
		r, err := scanRun(rows)
		if err != nil {
			rows.Close()
			return err
		}
		pending = append(pending, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	l, err := getLimits(ctx, s.db, "")
	if err != nil {
		return err
	}
	for _, run := range pending {
		c, err := s.conversation(ctx, run.userID, run.ConversationID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		var deleting bool
		_ = s.db.QueryRow(ctx, "SELECT deleting FROM app.ai_conversations WHERE id=$1", run.ConversationID).Scan(&deleting)
		s.mu.Lock()
		if !run.stopRequested && !deleting && c.ID != "" && !s.users[run.userID] && s.slots < l.GlobalConcurrency {
			s.launch(c, run)
			s.mu.Unlock()
			continue
		}
		s.mu.Unlock()
		status, code := "failed", "interrupted"
		if run.stopRequested || deleting {
			status, code = "cancelled", ""
		}
		if run.stopRequested && !deleting {
			// A crash can leave accepted input queued even though a stop was
			// already acknowledged. Do not let the next send consume it.
			session, openErr := core.OpenSession(ctx, s.sessionConfig(run.userID, run.sessionID), run.sessionID)
			if openErr == nil {
				receipt, lookupErr := session.LookupInput(ctx, run.InputID)
				if lookupErr == nil && receipt.State == core.InputPending {
					s.storePendingInput(run, session)
				}
				_ = session.Close(ctx)
			}
		}
		if _, err := s.persistRunStatus(ctx, run.ID, status, code, nil); err != nil {
			return err
		}
	}
	return nil
}
