package ai

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	core "github.com/oines/astral-core"
)

type Conversation struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	sessionID string
	owner     string
}

const conversationColumns = "id::text,title,created_at,updated_at,session_id,user_id::text"

func scanConversation(row interface{ Scan(...any) error }) (c Conversation, err error) {
	err = row.Scan(&c.ID, &c.Title, &c.CreatedAt, &c.UpdatedAt, &c.sessionID, &c.owner)
	return
}

func (s *Service) conversation(ctx context.Context, owner, id string) (Conversation, error) {
	if !validUUID(id) {
		return Conversation{}, notFound()
	}
	return scanConversation(s.db.QueryRow(ctx, "SELECT "+conversationColumns+" FROM app.ai_conversations WHERE user_id=$1 AND id=$2", owner, id))
}

func (s *Service) listConversations(w http.ResponseWriter, r *http.Request) {
	words := shortText(strings.TrimSpace(r.URL.Query().Get("q")), 100)
	rows, err := s.db.Query(r.Context(), "SELECT "+conversationColumns+` FROM app.ai_conversations WHERE user_id=$1 AND strpos(lower(title),lower($2))>0 ORDER BY updated_at DESC LIMIT $3`,
		s.cfg.UserID(r), words, pageLimit(r, 100, 200))
	if err != nil {
		s.fail(w, err)
		return
	}
	items := make([]Conversation, 0)
	defer rows.Close()
	for rows.Next() {
		c, err := scanConversation(rows)
		if err != nil {
			s.fail(w, err)
			return
		}
		items = append(items, c)
	}
	if err = rows.Err(); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}

func (s *Service) createConversation(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title string `json:"title"`
	}
	if err := decode(w, r, &body, true); err != nil {
		s.fail(w, err)
		return
	}
	body.Title = strings.TrimSpace(body.Title)
	if body.Title == "" {
		body.Title = "新对话"
	}
	if utf8.RuneCountInString(body.Title) > 80 {
		s.fail(w, bad("invalid_title", "会话标题不能超过 80 字。"))
		return
	}
	id := uuid.NewString()
	c, err := scanConversation(s.db.QueryRow(r.Context(),
		"INSERT INTO app.ai_conversations(id,user_id,session_id,title) VALUES($1,$2,$3,$4) RETURNING "+conversationColumns,
		id, s.cfg.UserID(r), id, body.Title))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 201, c)
}

func (s *Service) getConversation(w http.ResponseWriter, r *http.Request) {
	c, err := s.conversation(r.Context(), s.cfg.UserID(r), r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, c)
}

func (s *Service) renameConversation(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validUUID(id) {
		s.fail(w, notFound())
		return
	}
	var body struct {
		Title string `json:"title"`
	}
	if err := decode(w, r, &body, false); err != nil {
		s.fail(w, err)
		return
	}
	body.Title = strings.TrimSpace(body.Title)
	if body.Title == "" || utf8.RuneCountInString(body.Title) > 80 {
		s.fail(w, bad("invalid_title", "请输入 1 到 80 字的会话标题。"))
		return
	}
	c, err := scanConversation(s.db.QueryRow(r.Context(),
		"UPDATE app.ai_conversations SET title=$3,updated_at=now() WHERE user_id=$1 AND id=$2 RETURNING "+conversationColumns,
		s.cfg.UserID(r), id, body.Title))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, c)
}

func (s *Service) deleteConversation(w http.ResponseWriter, r *http.Request) {
	owner, id := s.cfg.UserID(r), r.PathValue("id")
	c, err := s.conversation(r.Context(), owner, id)
	if err != nil {
		s.fail(w, err)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 12*time.Second)
	defer cancel()
	s.mu.Lock()
	// Marking deletion first prevents a new run attaching while we stop the old one.
	err = s.db.QueryRow(ctx, "UPDATE app.ai_conversations SET deleting=true WHERE id=$1 AND user_id=$2 RETURNING session_id", id, owner).
		Scan(&c.sessionID)
	a := s.active[id]
	if err == nil && a != nil {
		a.stop()
		if a.run != nil {
			a.run.Cancel()
		}
	}
	s.mu.Unlock()
	if err != nil {
		s.fail(w, err)
		return
	}
	if a != nil {
		select {
		case <-a.ready:
		case <-ctx.Done():
			s.fail(w, unavailable("deleting", "会话正在结束，请稍后再次删除。"))
			return
		}
	}
	if s.cfg.OnConversationDeleted != nil {
		if err := s.cfg.OnConversationDeleted(ctx, owner, id); err != nil {
			s.fail(w, err)
			return
		}
	}
	err = s.store.mutate(ctx, func(tx pgx.Tx) error {
		// Remove retry forks as well as the current session. Detached retry
		// rollouts are private to the same business conversation.
		_, err := tx.Exec(ctx, `DELETE FROM agent.rollouts WHERE id IN (
			SELECT rollout_id FROM agent.sessions WHERE id=$2 OR id IN (
				SELECT session_id FROM app.ai_runs WHERE conversation_id=$1))`, c.ID, c.sessionID)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "DELETE FROM app.ai_conversations WHERE id=$1 AND user_id=$2", id, owner)
		return err
	})
	if err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(204)
}

type Message struct {
	ID        string    `json:"id"`
	Role      string    `json:"role"`
	Text      string    `json:"text"`
	InputID   string    `json:"input_id,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

func messageOf(e core.Entry) (Message, bool) {
	if e.Kind != core.EntryMessage || e.Message == nil || e.Message.ContextKind != "" ||
		(e.Message.Role != core.RoleUser && e.Message.Role != core.RoleAssistant) {
		return Message{}, false
	}
	text := visibleText(e.Message)
	if text == "" {
		return Message{}, false
	}
	return Message{ID: e.ID, Role: string(e.Message.Role), Text: text, InputID: e.InputID, CreatedAt: e.Time}, true
}

func (s *Service) messages(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	c, err := s.conversation(ctx, s.cfg.UserID(r), r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	state, err := s.store.LoadState(ctx, c.sessionID)
	if err != nil && !errors.Is(err, core.ErrNotFound) {
		s.fail(w, err)
		return
	}
	limit := pageLimit(r, 100, 200)
	cursor := strings.TrimSpace(r.URL.Query().Get("before"))
	if cursor != "" && !validIDCursor(cursor) {
		s.fail(w, bad("invalid_cursor", "历史记录游标无效。"))
		return
	}
	current := state.Branch.HeadID
	if cursor != "" && current != "" {
		// A cursor exposed by this API is always a message ID. Check that it
		// belongs to the selected history, not to an abandoned branch.
		found, err := s.visibleEntries(ctx, state, []string{cursor})
		if err != nil || len(found) != 1 {
			s.fail(w, notFound())
			return
		}
		e, err := s.store.Get(ctx, state.RolloutID, cursor)
		if err != nil {
			s.fail(w, err)
			return
		}
		current = e.Entry.ParentID
	}
	items := make([]Message, 0, limit)
	more := false
	for current != "" {
		p, err := s.store.Scan(ctx, state.RolloutID, core.Query{PathHead: state.Branch.HeadID, Cursor: current, Limit: 64})
		if err != nil {
			s.fail(w, err)
			return
		}
		for _, rec := range p.Records {
			if message, ok := messageOf(rec.Entry); ok {
				if len(items) == limit {
					more = true
					break
				}
				items = append(items, message)
			}
		}
		if more {
			break
		}
		current = p.Next
	}
	if cursor == "" && len(items) < limit {
		if message, ok := s.uncommittedMessage(ctx, c, state); ok {
			items = append([]Message{message}, items...)
		}
	}
	var next string
	if more && len(items) > 0 {
		next = items[len(items)-1].ID
	}
	slices.Reverse(items)
	response := map[string]any{"items": items}
	if next != "" {
		response["next_before"] = next
	}
	run, err := s.latestRun(ctx, c.owner, c.ID)
	if err == nil {
		response["run"] = s.currentRun(run)
	} else if !errors.Is(err, pgx.ErrNoRows) {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, response)
}

func (s *Service) uncommittedMessage(ctx context.Context, c Conversation, st core.RuntimeState) (Message, bool) {
	var id string
	var body *string
	var created time.Time
	err := s.db.QueryRow(ctx, `SELECT i.id,i.body,r.created_at FROM app.ai_inputs i
		JOIN app.ai_runs r ON r.input_id=i.id AND r.retry_id IS NULL
		WHERE i.conversation_id=$1 AND i.core_entry_id='' ORDER BY i.position DESC LIMIT 1`, c.ID).Scan(&id, &body, &created)
	if err != nil || body == nil {
		return Message{}, false
	}
	if st.SessionID != "" {
		if receipt, err := s.store.LookupInput(ctx, st.SessionID, id); err == nil && receipt.EntryID != "" {
			return Message{}, false
		}
	}
	return Message{ID: "pending-" + id, Role: "user", Text: *body, InputID: id, CreatedAt: created}, true
}

func validIDCursor(id string) bool { return validInputID(id) }

func (s *Service) visibleEntries(ctx context.Context, state core.RuntimeState, ids []string) ([]Message, error) {
	for _, id := range ids {
		if !validIDCursor(id) {
			return nil, bad("invalid_messages", "所选消息无效。")
		}
	}
	rows, err := s.db.Query(ctx, `WITH RECURSIVE chain AS (
	  SELECT id,parent_id,sequence,entry FROM agent.entries WHERE rollout_id=$1 AND id=$2
	  UNION ALL SELECT e.id,e.parent_id,e.sequence,e.entry FROM chain c JOIN agent.entries e ON e.id=c.parent_id AND e.rollout_id=$1
	) SELECT entry FROM chain WHERE id=ANY($3::text[]) ORDER BY sequence`, state.RolloutID, state.Branch.HeadID, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Message, 0, len(ids))
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		e, err := decodeRecord(raw, nil)
		if err != nil {
			return nil, err
		}
		if m, ok := messageOf(e.Entry); ok {
			out = append(out, m)
		}
	}
	return out, rows.Err()
}

// ShareMessages returns a bounded snapshot of selected, committed messages
// from the owner's current branch. Callers own recipient permission and expiry.
func (s *Service) ShareMessages(ctx context.Context, owner, convID string, nodeIDs []string) (string, error) {
	if len(nodeIDs) == 0 || len(nodeIDs) > 20 {
		return "", bad("invalid_messages", "请选择 1 到 20 条消息。")
	}
	c, err := scanConversation(s.db.QueryRow(ctx, "SELECT "+conversationColumns+
		" FROM app.ai_conversations WHERE user_id=$1 AND id=$2 AND NOT deleting", owner, convID))
	if err != nil {
		return "", err
	}
	state, err := s.store.LoadState(ctx, c.sessionID)
	if err != nil {
		return "", err
	}
	items, err := s.visibleEntries(ctx, state, nodeIDs)
	if err != nil {
		return "", err
	}
	if len(items) != len(nodeIDs) {
		return "", notFound()
	}
	var parts []string
	for _, m := range items {
		role := "我"
		if m.Role == "assistant" {
			role = "AI"
		}
		parts = append(parts, role+"："+m.Text)
	}
	result := strings.Join(parts, "\n\n")
	if utf8.RuneCountInString(result) > 12000 {
		return "", bad("share_too_long", "选中的内容过长，请减少消息数。")
	}
	return result, nil
}

func (s *Service) feedback(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Helpful *bool  `json:"helpful"`
		Note    string `json:"note"`
	}
	if err := decode(w, r, &in, false); err != nil {
		s.fail(w, err)
		return
	}
	if in.Helpful == nil || len([]rune(in.Note)) > 500 {
		s.fail(w, bad("invalid_feedback", "请选择反馈类型，意见最多 500 字。"))
		return
	}
	ctx, owner := r.Context(), s.cfg.UserID(r)
	c, err := s.conversation(ctx, owner, r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	id := r.PathValue("message")
	state, err := s.store.LoadState(ctx, c.sessionID)
	if err != nil {
		s.fail(w, err)
		return
	}
	entries, err := s.visibleEntries(ctx, state, []string{id})
	if err != nil || len(entries) != 1 || entries[0].Role != "assistant" {
		s.fail(w, notFound())
		return
	}
	_, err = s.db.Exec(ctx, `INSERT INTO app.ai_feedback(conversation_id,message_id,user_id,helpful,note)
 VALUES($1,$2,$3,$4,$5) ON CONFLICT(conversation_id,message_id,user_id)
 DO UPDATE SET helpful=excluded.helpful,note=excluded.note,updated_at=now()`, c.ID, id, owner, *in.Helpful, strings.TrimSpace(in.Note))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"helpful": *in.Helpful})
}
