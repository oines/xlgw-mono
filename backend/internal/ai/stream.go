package ai

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"time"

	core "github.com/oines/astral-core"
)

type streamEvent struct {
	kind      string
	Run       Run    `json:"run"`
	Text      string `json:"text,omitempty"`
	AttemptID string `json:"attempt_id,omitempty"`
	Reset     bool   `json:"reset,omitempty"`
}

func (a *activation) broadcast(e streamEvent) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.publish(e)
}

func (a *activation) publish(e streamEvent) {
	a.view = e.Run
	if e.Reset {
		a.text = ""
	}
	a.text += e.Text
	if e.AttemptID != "" {
		a.attempt = e.AttemptID
	}
	for id, ch := range a.listeners {
		select {
		case ch <- e:
		default:
			close(ch)
			delete(a.listeners, id)
		}
	}
}

func (a *activation) listen() (streamEvent, <-chan streamEvent, func()) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.next++
	id := a.next
	ch := make(chan streamEvent, 128)
	a.listeners[id] = ch
	return streamEvent{kind: "snapshot", Run: a.view, Text: a.text, AttemptID: a.attempt, Reset: true}, ch, func() {
		a.mu.Lock()
		defer a.mu.Unlock()
		if _, ok := a.listeners[id]; ok {
			delete(a.listeners, id)
			close(ch)
		}
	}
}

func (s *Service) handleCoreEvent(a *activation, e core.Event) {
	if e.Type == core.EventCommitted {
		s.includeToolActions(a, e.EntryID)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	run := a.view
	if terminal(run.Status) {
		return
	}
	switch {
	case e.Type == core.EventAttemptStart && e.Attempt != nil && e.Attempt.Purpose == "generation":
		if run.Status == "waiting" {
			run.Status = "streaming"
		}
		a.publish(streamEvent{kind: "delta", Run: run, AttemptID: e.AttemptID, Reset: true})
	case e.Type == core.EventAttemptFailed && e.Attempt != nil && e.Attempt.Purpose == "generation":
		a.publish(streamEvent{kind: "delta", Run: run, AttemptID: e.AttemptID, Reset: true})
	case e.Type == core.EventMessageUpdate && e.Model != nil && e.Model.Type == "text_delta" && e.Model.Text != "":
		reset := a.attempt != "" && a.attempt != e.AttemptID
		run.Status = "streaming"
		a.publish(streamEvent{kind: "delta", Run: run, Text: e.Model.Text, AttemptID: e.AttemptID, Reset: reset})
	}
}

func (s *Service) includeToolActions(a *activation, id string) {
	if a.session == nil || id == "" {
		return
	}
	entry, err := a.session.History().Get(s.ctx, id)
	if err != nil || entry.Tool == nil || entry.Tool.Result == nil || entry.Tool.Invocation.Call.Name != "school_options" {
		return
	}
	var actions []Action
	if json.Unmarshal(entry.Tool.Result.Details, &actions) != nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	run := a.view
	if terminal(run.Status) {
		return
	}
	run.Actions = append([]Action(nil), run.Actions...)
	for _, action := range actions {
		if len(run.Actions) >= 10 {
			break
		}
		if !slices.ContainsFunc(run.Actions, func(old Action) bool {
			return old.Kind == action.Kind && old.ID == action.ID && old.Title == action.Title
		}) {
			run.Actions = append(run.Actions, action)
		}
	}
	a.publish(streamEvent{kind: "state", Run: run})
}

func (s *Service) events(w http.ResponseWriter, r *http.Request) {
	run, err := s.findRun(r.Context(), s.cfg.UserID(r), r.PathValue("id"))
	if err != nil {
		s.fail(w, err)
		return
	}
	var next <-chan streamEvent
	var stop func()
	snapshot := streamEvent{kind: "snapshot", Run: run, Reset: true}
	s.mu.Lock()
	a := s.active[run.ConversationID]
	if a != nil && a.runID == run.ID {
		snapshot, next, stop = a.listen()
	}
	s.mu.Unlock()
	if stop != nil {
		defer stop()
	} else if !terminal(run.Status) {
		// A run may have just finished between its DB lookup and listener
		// registration. Confirm the persisted terminal status in that case.
		if updated, err := s.findRun(r.Context(), run.userID, run.ID); err == nil {
			snapshot.Run = updated
		}
	}
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	rc := http.NewResponseController(w)
	send := func(e streamEvent) error {
		if err := rc.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return err
		}
		b, err := json.Marshal(e)
		if err != nil {
			return err
		}
		if _, err = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e.kind, b); err != nil {
			return err
		}
		return rc.Flush()
	}
	if err := send(snapshot); err != nil || next == nil || terminal(snapshot.Run.Status) {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			if s.cfg.SessionActive != nil && !s.cfg.SessionActive(r) {
				return
			}
			var active bool
			if err := s.db.QueryRow(r.Context(), "SELECT active FROM app.users WHERE id=$1", run.userID).Scan(&active); err != nil || !active {
				return
			}
			if err := rc.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
				return
			}
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil || rc.Flush() != nil {
				return
			}
		case e, open := <-next:
			if !open || send(e) != nil || terminal(e.Run.Status) {
				return
			}
		}
	}
}
