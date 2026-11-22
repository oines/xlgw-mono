package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	core "github.com/oines/astral-core"
)

// Store keeps the checkpoint, append-only history, receipts and pending work in
// PostgreSQL. JSON is stored as bytes to preserve opaque model protocol fields.
type Store struct{ Pool *pgxpool.Pool }

var (
	_ core.Store          = (*Store)(nil)
	_ core.SessionDeleter = (*Store)(nil)
)

type rowQuery interface {
	QueryRow(context.Context, string, ...any) pgx.Row
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

func readJSON[T any](row pgx.Row) (T, error) {
	var result T
	var raw []byte
	if err := row.Scan(&raw); err != nil {
		return result, storeError(err)
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return result, fmt.Errorf("%w: invalid stored JSON", core.ErrCorrupt)
	}
	return result, nil
}

func storeError(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return core.ErrNotFound
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return core.ErrConflict
	}
	return err
}

func (s *Store) LoadState(ctx context.Context, id string) (core.RuntimeState, error) {
	return loadState(ctx, s.Pool, id)
}

func loadState(ctx context.Context, q rowQuery, id string) (core.RuntimeState, error) {
	state, err := readJSON[core.RuntimeState](q.QueryRow(ctx, "SELECT state FROM agent.sessions WHERE id=$1", id))
	if err != nil {
		return state, err
	}
	if !core.SupportsFormat(state.FormatVersion) {
		return state, core.ErrUnsupportedFormat
	}
	if state.SessionID != id || state.RolloutID == "" || state.Version == 0 {
		return state, core.ErrCorrupt
	}
	return state, nil
}

func (s *Store) LookupCommit(ctx context.Context, sessionID, id string) (core.Receipt, error) {
	r, err := readJSON[core.Receipt](s.Pool.QueryRow(ctx,
		"SELECT receipt FROM agent.receipts WHERE session_id=$1 AND id=$2", sessionID, id))
	if err == nil {
		err = storeError(s.Pool.QueryRow(ctx,
			"SELECT version FROM agent.sessions WHERE id=$1", sessionID).Scan(&r.CurrentVersion))
	}
	return r, err
}

func (s *Store) LookupInput(ctx context.Context, sessionID, id string) (core.InputReceipt, error) {
	var r core.InputReceipt
	var raw []byte
	err := s.Pool.QueryRow(ctx, "SELECT input,accepted_at,state,entry_id FROM agent.inputs WHERE session_id=$1 AND id=$2", sessionID, id).
		Scan(&raw, &r.AcceptedAt, &r.State, &r.EntryID)
	if err != nil {
		return r, storeError(err)
	}
	if json.Unmarshal(raw, &r.InputRecord) != nil || r.ID != id {
		return r, core.ErrCorrupt
	}
	return r, nil
}

func decodeRecord(entry, projection []byte) (core.Record, error) {
	var r core.Record
	if json.Unmarshal(entry, &r.Entry) != nil || r.Entry.ID == "" {
		return r, core.ErrCorrupt
	}
	if len(projection) > 0 {
		var p core.Projection
		if json.Unmarshal(projection, &p) != nil || p.HeadID != r.Entry.ID {
			return r, core.ErrCorrupt
		}
		r.Projection = &p
	}
	return r, nil
}

func getRecord(ctx context.Context, q rowQuery, rolloutID, id string) (core.Record, error) {
	var e, p []byte
	err := q.QueryRow(ctx, "SELECT entry,projection FROM agent.entries WHERE rollout_id=$1 AND id=$2", rolloutID, id).Scan(&e, &p)
	if err != nil {
		return core.Record{}, storeError(err)
	}
	return decodeRecord(e, p)
}

func (s *Store) Get(ctx context.Context, rolloutID, id string) (core.Record, error) {
	return getRecord(ctx, s.Pool, rolloutID, id)
}

const historyQuery = `WITH RECURSIVE chain AS (
	SELECT id,parent_id,0 AS depth FROM agent.entries
	  WHERE rollout_id=$1 AND id=$2 AND projection IS NOT NULL
	UNION ALL
	SELECT e.id,e.parent_id,c.depth+1 FROM chain c JOIN agent.entries e
	  ON e.rollout_id=$1 AND e.id=c.parent_id
	  WHERE c.depth+1 < $3 AND c.id<>$4 AND e.projection IS NOT NULL
) SELECT e.entry,e.projection,e.payload_bytes FROM chain c JOIN agent.entries e
  ON e.rollout_id=$1 AND e.id=c.id ORDER BY c.depth`

func (s *Store) Scan(ctx context.Context, id string, q core.Query) (core.Page, error) {
	limit, maxBytes := core.PageLimits(q.Limit, q.MaxBytes)
	if q.PathHead != "" {
		head := q.PathHead
		if q.Cursor != "" {
			head = q.Cursor
		}
		page, err := readPage(ctx, s.Pool, historyQuery, []any{id, head, limit + 1, q.StopID}, limit, maxBytes, true)
		if err == nil && len(page.Records) == 0 {
			err = core.ErrNotFound
		}
		return page, err
	}
	b := queryBuilder{sql: "SELECT entry,projection,payload_bytes FROM agent.entries WHERE rollout_id=$1", args: []any{id}}
	if q.SessionID != "" {
		b.add("writer=", q.SessionID)
	}
	if q.ParentID != nil {
		b.add("parent_id=", *q.ParentID)
		b.sql += " AND projection IS NOT NULL"
	}
	if q.Kind != "" {
		b.add("kind=", string(q.Kind))
	}
	if q.Reference != "" {
		b.add("reference=", q.Reference)
	}
	if q.HistoryOnly {
		b.sql += " AND projection IS NOT NULL"
	}
	if err := b.order(q.Cursor, q.Reverse, "sequence", limit); err != nil {
		return core.Page{}, err
	}
	page, err := readPage(ctx, s.Pool, b.sql, b.args, limit, maxBytes, false)
	if err == nil && len(page.Records) == 0 {
		var exists bool
		err = s.Pool.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM agent.rollouts WHERE id=$1)", id).Scan(&exists)
		if err == nil && !exists {
			err = core.ErrNotFound
		}
	}
	return page, err
}

type queryBuilder struct {
	sql  string
	args []any
}

func (b *queryBuilder) add(condition string, value any) {
	b.sql += fmt.Sprintf(" AND %s$%d", condition, len(b.args)+1)
	b.args = append(b.args, value)
}

func (b *queryBuilder) order(cursor string, reverse bool, column string, limit int) error {
	op, order := ">", "ASC"
	if reverse {
		op, order = "<", "DESC"
	}
	if cursor != "" {
		c, err := strconv.ParseInt(cursor, 10, 64)
		if err != nil || c < 1 {
			return core.ErrInvalid
		}
		b.add(column+op, c)
	}
	b.sql += fmt.Sprintf(" ORDER BY %s %s LIMIT $%d", column, order, len(b.args)+1)
	b.args = append(b.args, limit+1)
	return nil
}

func readPage(ctx context.Context, q rowQuery, sql string, args []any, limit, maxBytes int, path bool) (core.Page, error) {
	rows, err := q.Query(ctx, sql, args...)
	if err != nil {
		return core.Page{}, err
	}
	defer rows.Close()
	var p core.Page
	var size int
	for rows.Next() {
		var e, project []byte
		var n int
		if err := rows.Scan(&e, &project, &n); err != nil {
			return p, err
		}
		if len(p.Records) >= limit || n > maxBytes-size {
			if len(p.Records) == 0 {
				return p, core.ErrBudget
			}
			last := p.Records[len(p.Records)-1].Entry
			p.Next = strconv.FormatUint(last.Sequence, 10)
			if path {
				p.Next = last.ParentID
			}
			break
		}
		record, err := decodeRecord(e, project)
		if err != nil {
			return p, err
		}
		if n < 1 || path && record.Projection == nil {
			return p, core.ErrCorrupt
		}
		p.Records = append(p.Records, record)
		size += n
	}
	return p, rows.Err()
}

func (s *Store) Pending(ctx context.Context, id string, q core.PendingQuery) (core.Page, error) {
	limit, maxBytes := core.PageLimits(q.Limit, q.MaxBytes)
	b := queryBuilder{sql: "SELECT entry,NULL::bytea,payload_bytes FROM agent.pending WHERE session_id=$1", args: []any{id}}
	if q.Kind != "" {
		b.add("bucket=", string(q.Kind))
	}
	if q.InputID != "" {
		b.add("bucket=", string(core.EntryInputQueued))
		b.add("key=", q.InputID)
	}
	if q.InputKind != "" {
		b.add("input_kind=", string(q.InputKind))
	}
	if err := b.order(q.Cursor, false, "sequence", limit); err != nil {
		return core.Page{}, err
	}
	p, err := readPage(ctx, s.Pool, b.sql, b.args, limit, maxBytes, false)
	if err == nil && len(p.Records) == 0 {
		_, err = s.LoadState(ctx, id)
	}
	return p, err
}

func (s *Store) GetAttempt(ctx context.Context, sessionID, id string) (core.ModelAttempt, error) {
	return readJSON[core.ModelAttempt](s.Pool.QueryRow(ctx,
		"SELECT attempt FROM agent.attempts WHERE session_id=$1 AND id=$2", sessionID, id))
}

func (s *Store) ScanAttempts(ctx context.Context, id string, q core.AttemptQuery) (core.AttemptPage, error) {
	limit, maxBytes := core.PageLimits(q.Limit, q.MaxBytes)
	b := queryBuilder{sql: "SELECT attempt,payload_bytes FROM agent.attempts WHERE session_id=$1", args: []any{id}}
	if q.Purpose != "" {
		b.add("purpose=", q.Purpose)
	}
	if err := b.order(q.Cursor, q.Reverse, "version", limit); err != nil {
		return core.AttemptPage{}, err
	}
	rows, err := s.Pool.Query(ctx, b.sql, b.args...)
	if err != nil {
		return core.AttemptPage{}, err
	}
	defer rows.Close()
	var page core.AttemptPage
	var size int
	for rows.Next() {
		var raw []byte
		var n int
		if err := rows.Scan(&raw, &n); err != nil {
			return page, err
		}
		if len(page.Attempts) >= limit || n > maxBytes-size {
			if len(page.Attempts) == 0 {
				return page, core.ErrBudget
			}
			page.Next = strconv.FormatUint(page.Attempts[len(page.Attempts)-1].Version, 10)
			break
		}
		var a core.ModelAttempt
		if n < 1 || json.Unmarshal(raw, &a) != nil || a.SessionID != id {
			return page, core.ErrCorrupt
		}
		page.Attempts = append(page.Attempts, a)
		size += n
	}
	if err := rows.Err(); err != nil {
		return page, err
	}
	rows.Close()
	if len(page.Attempts) == 0 {
		_, err = s.LoadState(ctx, id)
	}
	return page, err
}

// Mutations are short transactions. A transaction advisory lock keeps fork,
// commit and deletion ordering identical, with no network calls under the lock.
func (s *Store) mutate(ctx context.Context, f func(pgx.Tx) error) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock(727199413615)"); err != nil {
		return err
	}
	if err := f(tx); err != nil {
		return storeError(err)
	}
	return storeError(tx.Commit(ctx))
}

func (s *Store) Commit(ctx context.Context, id string, c core.Commit) (receipt core.Receipt, err error) {
	if id == "" || c.ID == "" || c.ID == core.ForkCommitID || len(c.Entries)+len(c.Attempts) == 0 {
		return receipt, core.ErrInvalid
	}
	digest, err := c.Digest()
	if err != nil {
		return receipt, err
	}
	err = s.mutate(ctx, func(tx pgx.Tx) error {
		state, err := loadState(ctx, tx, id)
		if errors.Is(err, core.ErrNotFound) {
			if len(c.Entries) == 0 || c.Entries[0].Created == nil || c.Entries[0].Created.Projection != nil {
				return core.ErrCorrupt
			}
			state = core.RuntimeState{}
		} else if err != nil {
			return err
		}
		old, err := readJSON[core.Receipt](tx.QueryRow(ctx, "SELECT receipt FROM agent.receipts WHERE session_id=$1 AND id=$2", id, c.ID))
		if err == nil {
			if old.Digest != digest {
				return core.ErrConflict
			}
			old.CurrentVersion = state.Version
			receipt = old
			return nil
		}
		if !errors.Is(err, core.ErrNotFound) {
			return err
		}
		if state.Version != c.ExpectedVersion {
			return core.ErrConflict
		}
		var sequence uint64
		rollout := state.RolloutID
		if state.Version == 0 {
			rollout = c.Entries[0].Created.RolloutID
			if rollout == "" {
				return core.ErrCorrupt
			}
			if _, err := tx.Exec(ctx, "INSERT INTO agent.rollouts(id) VALUES($1)", rollout); err != nil {
				return err
			}
		} else if err := tx.QueryRow(ctx, "SELECT sequence FROM agent.rollouts WHERE id=$1", rollout).Scan(&sequence); err != nil {
			return err
		}
		confirmed, r, err := core.AssignCommit(c, sequence+1)
		if err != nil {
			return err
		}
		next, records, err := core.Reduce(state, confirmed)
		if err != nil {
			return err
		}
		if next.RolloutID != rollout || next.SessionID != id {
			return core.ErrCorrupt
		}
		if err := saveState(ctx, tx, next); err != nil {
			return err
		}
		for _, row := range records {
			if err := insertRecord(ctx, tx, rollout, row); err != nil {
				return err
			}
			if err := updatePending(ctx, tx, row.Entry); err != nil {
				return err
			}
		}
		if err := saveAttempts(ctx, tx, next, confirmed); err != nil {
			return err
		}
		if err := saveReceipt(ctx, tx, next, r); err != nil {
			return err
		}
		receipt = r
		return nil
	})
	return receipt, err
}

func saveState(ctx context.Context, tx pgx.Tx, st core.RuntimeState) error {
	raw, err := json.Marshal(st)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO agent.sessions(id,rollout_id,version,state) VALUES($1,$2,$3,$4)
	ON CONFLICT(id) DO UPDATE SET version=excluded.version,state=excluded.state`, st.SessionID, st.RolloutID, st.Version, raw)
	return err
}

func saveReceipt(ctx context.Context, tx pgx.Tx, st core.RuntimeState, r core.Receipt) error {
	raw, err := json.Marshal(r)
	if err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, "INSERT INTO agent.receipts(session_id,id,receipt) VALUES($1,$2,$3)", st.SessionID, r.CommitID, raw); err != nil {
		return err
	}
	if r.LastSequence > 0 {
		_, err = tx.Exec(ctx, "UPDATE agent.rollouts SET sequence=$2 WHERE id=$1", st.RolloutID, r.LastSequence)
	}
	return err
}

func insertRecord(ctx context.Context, tx pgx.Tx, rollout string, record core.Record) error {
	e := record.Entry
	raw, err := json.Marshal(e)
	if err != nil {
		return err
	}
	var p []byte
	if record.Projection != nil {
		p, err = json.Marshal(record.Projection)
		if err != nil {
			return err
		}
	}
	if e.Compaction != nil {
		through, err := getRecord(ctx, tx, rollout, e.Compaction.ThroughID)
		if err != nil || through.Projection == nil {
			return core.ErrCorrupt
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO agent.entries(rollout_id,id,writer,sequence,parent_id,kind,reference,entry,projection,payload_bytes)
	VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, rollout, e.ID, e.SessionID, e.Sequence, e.ParentID, string(e.Kind),
		core.Reference(e), raw, p, len(raw)+len(p)+20)
	return err
}

func updatePending(ctx context.Context, tx pgx.Tx, e core.Entry) error {
	exec := func(sql string, args ...any) error {
		_, err := tx.Exec(ctx, sql, args...)
		return err
	}
	change := func(sql string, args ...any) error {
		tag, err := tx.Exec(ctx, sql, args...)
		if err == nil && tag.RowsAffected() != 1 {
			return core.ErrCorrupt
		}
		return err
	}
	add := func(bucket core.EntryKind, key, owner, inputKind string) error {
		raw, err := json.Marshal(e)
		if err != nil {
			return err
		}
		return exec(`INSERT INTO agent.pending(session_id,bucket,key,owner,input_kind,sequence,entry,payload_bytes)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8)`, e.SessionID, string(bucket), key, owner, inputKind, e.Sequence, raw, len(raw)+12)
	}
	remove := func(bucket core.EntryKind, key string) error {
		return exec("DELETE FROM agent.pending WHERE session_id=$1 AND bucket=$2 AND key=$3", e.SessionID, string(bucket), key)
	}
	if e.InputID != "" && (e.Kind == core.EntryMessage || e.Kind == core.EntryContext) {
		err := exec("UPDATE agent.inputs SET entry_id=$3 WHERE session_id=$1 AND id=$2 AND (entry_id='' OR $4)", e.SessionID, e.InputID, e.ID, e.Kind == core.EntryMessage)
		if err != nil {
			return err
		}
	}
	switch e.Kind {
	case core.EntryInputQueued, core.EntryInputRequeued:
		raw, err := json.Marshal(e.Input)
		if err != nil {
			return err
		}
		if e.Kind == core.EntryInputQueued {
			err = exec("INSERT INTO agent.inputs(session_id,id,kind,state,input,accepted_at) VALUES($1,$2,$3,'pending',$4,$5)", e.SessionID, e.Input.ID, string(e.Input.Kind), raw, e.Time)
		} else {
			err = change("UPDATE agent.inputs SET kind=$3,state='pending',input=$4 WHERE session_id=$1 AND id=$2 AND state='cleared'", e.SessionID, e.Input.ID, string(e.Input.Kind), raw)
		}
		if err != nil {
			return err
		}
		return add(core.EntryInputQueued, e.Input.ID, "", string(e.Input.Kind))
	case core.EntryInputConsumed, core.EntryInputCleared:
		if e.Input == nil {
			for _, kind := range e.Clear.Kinds {
				if err := exec("UPDATE agent.inputs SET state='cleared' WHERE session_id=$1 AND kind=$2 AND state='pending'", e.SessionID, string(kind)); err != nil {
					return err
				}
				if err := exec("DELETE FROM agent.pending WHERE session_id=$1 AND bucket=$2 AND input_kind=$3", e.SessionID, string(core.EntryInputQueued), string(kind)); err != nil {
					return err
				}
			}
			return nil
		}
		state := core.InputCleared
		if e.Kind == core.EntryInputConsumed {
			state = core.InputApplied
		}
		if err := change("UPDATE agent.inputs SET state=$4 WHERE session_id=$1 AND id=$2 AND kind=$3 AND state='pending'",
			e.SessionID, e.Input.ID, string(e.Input.Kind), string(state)); err != nil {
			return err
		}
		return remove(core.EntryInputQueued, e.Input.ID)
	case core.EntryApprovalRequested:
		return add(e.Kind, e.Approval.ID, e.Approval.ExecutionID, "")
	case core.EntryApprovalDecided:
		return remove(core.EntryApprovalRequested, e.Approval.ID)
	case core.EntryToolResult, core.EntryToolResolution, core.EntryToolControl, core.EntryToolUnresolved:
		return exec("DELETE FROM agent.pending WHERE session_id=$1 AND bucket=$2 AND owner=$3", e.SessionID, string(core.EntryApprovalRequested), e.Tool.Invocation.ExecutionID)
	case core.EntryMessage:
		return exec("DELETE FROM agent.pending WHERE session_id=$1 AND bucket=$2", e.SessionID, string(core.EntryApprovalRequested))
	}
	return nil
}

func saveAttempts(ctx context.Context, tx pgx.Tx, state core.RuntimeState, c core.Commit) error {
	seen := map[string]bool{}
	for _, m := range c.Attempts {
		if seen[m.ID] {
			return core.ErrCorrupt
		}
		seen[m.ID] = true
		var old *core.ModelAttempt
		value, err := readJSON[core.ModelAttempt](tx.QueryRow(ctx, "SELECT attempt FROM agent.attempts WHERE session_id=$1 AND id=$2", state.SessionID, m.ID))
		if err == nil {
			old = &value
		} else if !errors.Is(err, core.ErrNotFound) {
			return err
		}
		a, err := core.ApplyAttemptMutation(old, m, c.Entries)
		if err != nil {
			return err
		}
		if a.SessionID != state.SessionID || a.Input.RolloutID != state.RolloutID {
			return core.ErrCorrupt
		}
		if m.Create != nil {
			head, err := getRecord(ctx, tx, state.RolloutID, a.Input.HeadID)
			if err != nil || head.Projection == nil || !head.Projection.Complete() || head.Projection.ConfigurationID != a.Input.ConfigurationID {
				return core.ErrCorrupt
			}
		}
		raw, err := json.Marshal(a)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO agent.attempts(session_id,id,version,purpose,attempt,payload_bytes)
		VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(session_id,id) DO UPDATE SET attempt=excluded.attempt,payload_bytes=excluded.payload_bytes`,
			state.SessionID, a.ID, a.Version, a.Purpose, raw, len(raw))
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) Fork(ctx context.Context, r core.ForkRequest) (next core.RuntimeState, err error) {
	if err := core.ValidateFork(r); err != nil {
		return next, err
	}
	digest, err := r.Digest()
	if err != nil {
		return next, err
	}
	err = s.mutate(ctx, func(tx pgx.Tx) error {
		old, err := readJSON[core.Receipt](tx.QueryRow(ctx, "SELECT receipt FROM agent.receipts WHERE session_id=$1 AND id=$2", r.TargetID, core.ForkCommitID))
		if err == nil {
			if old.Digest != digest {
				return core.ErrConflict
			}
			next, err = loadState(ctx, tx, r.TargetID)
			return err
		}
		if !errors.Is(err, core.ErrNotFound) {
			return err
		}
		source, err := loadState(ctx, tx, r.SourceID)
		if err != nil || source.RolloutID != r.SourceRolloutID {
			return core.ErrNotFound
		}
		head, err := getRecord(ctx, tx, r.SourceRolloutID, r.HeadID)
		if err != nil {
			return err
		}
		var seq uint64
		if err := tx.QueryRow(ctx, "SELECT sequence FROM agent.rollouts WHERE id=$1", r.SourceRolloutID).Scan(&seq); err != nil {
			return err
		}
		if r.Mode == core.ForkDetached {
			seq = head.Entry.Sequence
		}
		_, state, records, receipt, err := core.PrepareFork(r, head, seq+1)
		if err != nil {
			return err
		}
		target, err := tx.Exec(ctx, "SELECT 1 FROM agent.sessions WHERE id=$1", r.TargetID)
		if err != nil {
			return err
		}
		if target.RowsAffected() > 0 {
			return core.ErrConflict
		}
		if r.Mode == core.ForkDetached {
			if _, err := tx.Exec(ctx, "INSERT INTO agent.rollouts(id,sequence) VALUES($1,$2)", state.RolloutID, seq); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `WITH RECURSIVE chain AS (
				SELECT id,parent_id FROM agent.entries WHERE rollout_id=$1 AND id=$2 AND projection IS NOT NULL
				UNION ALL SELECT e.id,e.parent_id FROM agent.entries e JOIN chain c ON e.id=c.parent_id
				WHERE e.rollout_id=$1 AND e.projection IS NOT NULL
			) INSERT INTO agent.entries(rollout_id,id,writer,sequence,parent_id,kind,reference,entry,projection,payload_bytes)
			SELECT $3,e.id,e.writer,e.sequence,e.parent_id,e.kind,e.reference,e.entry,e.projection,e.payload_bytes
			FROM chain c JOIN agent.entries e ON e.rollout_id=$1 AND e.id=c.id`,
				r.SourceRolloutID, r.HeadID, state.RolloutID)
			if err != nil {
				return err
			}
		}
		if err := saveState(ctx, tx, state); err != nil {
			return err
		}
		for _, row := range records {
			if err := insertRecord(ctx, tx, state.RolloutID, row); err != nil {
				return err
			}
		}
		next = state
		return saveReceipt(ctx, tx, state, receipt)
	})
	return next, err
}

func (s *Store) DeleteSession(ctx context.Context, id string) error {
	return s.mutate(ctx, func(tx pgx.Tx) error {
		st, err := loadState(ctx, tx, id)
		if errors.Is(err, core.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		var count int
		if err := tx.QueryRow(ctx, "SELECT count(*) FROM agent.sessions WHERE rollout_id=$1", st.RolloutID).Scan(&count); err != nil {
			return err
		}
		if count != 1 {
			return core.ErrConflict
		}
		_, err = tx.Exec(ctx, "DELETE FROM agent.rollouts WHERE id=$1", st.RolloutID)
		return err
	})
}
