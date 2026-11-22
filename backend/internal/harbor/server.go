package harbor

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Object = map[string]any
type queryer interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	QueryRow(context.Context, string, ...any) pgx.Row
	Query(context.Context, string, ...any) (pgx.Rows, error)
}
type Server struct {
	DB            *pgxpool.Pool
	ShareMessages func(context.Context, string, string, []string) (string, error)
}
type User struct {
	ID        string    `json:"id"`
	Account   string    `json:"account"`
	Nickname  string    `json:"nickname"`
	AvatarURL string    `json:"avatar_url"`
	Roles     []string  `json:"roles"`
	Active    bool      `json:"active"`
	School    string    `json:"school"`
	Theme     string    `json:"theme"`
	Motion    string    `json:"motion"`
	CreatedAt time.Time `json:"created_at"`
}

func (u User) Has(role string) bool {
	for _, r := range u.Roles {
		if r == role {
			return true
		}
	}
	return false
}
func (u User) Work() bool { return u.Has("teacher") || u.Has("peer") }

type userKey struct{}

func actor(r *http.Request) User    { u, _ := r.Context().Value(userKey{}).(User); return u }
func UserID(r *http.Request) string { return actor(r).ID }

type problem struct {
	status        int
	code, message string
}

func (p *problem) Error() string              { return p.message }
func fail(status int, code, msg string) error { return &problem{status, code, msg} }
func invalid(msg string) error                { return fail(400, "invalid_input", msg) }
func forbidden() error                        { return fail(403, "forbidden", "你没有执行这项操作的权限") }
func missing() error                          { return fail(404, "not_found", "这条记录已不可用") }
func stale(msg string) error                  { return fail(409, "conflict", msg) }
func jsonOut(w http.ResponseWriter, status int, v any) {
	if status == 204 {
		w.WriteHeader(status)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Debug("write response", "error", err)
	}
}
func errorOut(w http.ResponseWriter, err error) {
	var p *problem
	var dbErr *pgconn.PgError
	switch {
	case errors.As(err, &p):
		jsonOut(w, p.status, Object{"code": p.code, "message": p.message})
	case errors.Is(err, pgx.ErrNoRows):
		errorOut(w, missing())
	case errors.As(err, &dbErr) && dbErr.Code == "23505":
		errorOut(w, stale("这条记录已经存在，请刷新后再试"))
	case errors.As(err, &dbErr) && (dbErr.Code == "22P02" || dbErr.Code == "23503" || dbErr.Code == "23514"):
		errorOut(w, invalid("请检查输入和所选记录"))
	default:
		slog.Error("harbor request failed", "error", err)
		jsonOut(w, 500, Object{"code": "internal_error", "message": "暂时无法完成，请稍后重试"})
	}
}

type endpoint func(*http.Request) (any, error)

func handle(fn endpoint) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		v, err := fn(r)
		if err != nil {
			errorOut(w, err)
			return
		}
		if v == nil {
			jsonOut(w, 204, nil)
			return
		}
		jsonOut(w, 200, v)
	}
}
func decode(r *http.Request, dst any) error {
	d := json.NewDecoder(io.LimitReader(r.Body, 128<<10))
	if err := d.Decode(dst); err != nil {
		return invalid("请求格式有误")
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return invalid("请求格式有误")
	}
	return nil
}
func field(raw, name string, min, max int) (string, error) {
	v := strings.TrimSpace(raw)
	n := utf8.RuneCountInString(v)
	if n < min || n > max {
		return "", invalid(fmt.Sprintf("%s需填写 %d–%d 个字符", name, min, max))
	}
	return v, nil
}
func oneOf(v string, options ...string) bool {
	for _, o := range options {
		if v == o {
			return true
		}
	}
	return false
}
func id(raw string) (string, error) {
	v, e := uuid.Parse(raw)
	if e != nil || v == uuid.Nil {
		return "", invalid("记录编号无效")
	}
	return v.String(), nil
}
func optionalID(raw string) (any, error) {
	if raw == "" {
		return nil, nil
	}
	return id(raw)
}
func clientID(raw string) (string, error) {
	if raw == "" {
		return uuid.NewString(), nil
	}
	return id(raw)
}
func pathID(r *http.Request) (string, error) { return id(r.PathValue("id")) }
func page(r *http.Request) (int, int) {
	q := r.URL.Query()
	offset, _ := strconv.Atoi(q.Get("offset"))
	n, _ := strconv.Atoi(q.Get("limit"))
	if n <= 0 || n > 100 {
		n = 100
	}
	return n, max(offset, 0)
}
func object(ctx context.Context, q queryer, sql string, args ...any) (Object, error) {
	var v Object
	err := q.QueryRow(ctx, "SELECT to_jsonb(item) FROM ("+sql+") item", args...).Scan(&v)
	return v, err
}
func items(ctx context.Context, q queryer, sql string, args ...any) (Object, error) {
	rows, err := q.Query(ctx, "SELECT to_jsonb(item) FROM ("+sql+") item", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Object{}
	for rows.Next() {
		var v Object
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return Object{"items": out}, rows.Err()
}
func transaction[T any](ctx context.Context, db *pgxpool.Pool, fn func(pgx.Tx) (T, error)) (T, error) {
	var zero T
	tx, err := db.Begin(ctx)
	if err != nil {
		return zero, err
	}
	defer tx.Rollback(ctx)
	value, err := fn(tx)
	if err != nil {
		return zero, err
	}
	return value, tx.Commit(ctx)
}
func lockedUsers(ctx context.Context, tx pgx.Tx, ids ...string) error {
	rows, err := tx.Query(ctx, "SELECT id FROM app.users WHERE id=ANY($1::uuid[]) ORDER BY id FOR UPDATE", ids)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
	}
	return rows.Err()
}
func tokenHash(v string) string { h := sha256.Sum256([]byte(v)); return hex.EncodeToString(h[:]) }
func newToken() string          { b := make([]byte, 32); _, _ = rand.Read(b); return hex.EncodeToString(b) }
func tokenFrom(r *http.Request) (string, bool) {
	if v := r.Header.Get("Authorization"); strings.HasPrefix(v, "Bearer ") {
		return strings.TrimPrefix(v, "Bearer "), false
	}
	if c, err := r.Cookie("harbor_session"); err == nil {
		return c.Value, true
	}
	return "", false
}

const userSelect = `SELECT u.id,u.account,u.nickname,u.avatar_url,u.roles,u.active,u.theme,u.motion,u.created_at,(SELECT name FROM app.settings) school FROM app.users u`

func getUser(ctx context.Context, q queryer, where string, args ...any) (User, error) {
	var u User
	err := q.QueryRow(ctx, userSelect+" "+where, args...).Scan(&u.ID, &u.Account, &u.Nickname, &u.AvatarURL, &u.Roles, &u.Active, &u.Theme, &u.Motion, &u.CreatedAt, &u.School)
	return u, err
}
func (s *Server) Auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, cookie := tokenFrom(r)
		if token == "" {
			errorOut(w, fail(401, "unauthorized", "请先登录"))
			return
		}
		if cookie && !oneOf(r.Method, "GET", "HEAD", "OPTIONS") {
			host := r.Host
			if r.Header.Get("X-Forwarded-Host") != "" {
				host = r.Header.Get("X-Forwarded-Host")
			}
			origin, err := url.Parse(r.Header.Get("Origin"))
			if err != nil || origin.Host != host || !oneOf(origin.Scheme, "http", "https") {
				errorOut(w, forbidden())
				return
			}
		}
		ctx := r.Context()
		u, err := getUser(ctx, s.DB, `JOIN app.auth_sessions a ON a.user_id=u.id WHERE a.token_hash=$1 AND a.expires_at>now() AND u.active`, tokenHash(token))
		if errors.Is(err, pgx.ErrNoRows) {
			errorOut(w, fail(401, "unauthorized", "登录已失效，请重新登录"))
			return
		}
		if err != nil {
			errorOut(w, err)
			return
		}
		if _, err = s.DB.Exec(ctx, `INSERT INTO app.activity SELECT $1,(now() AT TIME ZONE timezone)::date FROM app.settings ON CONFLICT DO NOTHING`, u.ID); err != nil {
			slog.Debug("record activity", "error", err)
		}
		next(w, r.WithContext(context.WithValue(ctx, userKey{}, u)))
	}
}
func (s *Server) SessionActive(r *http.Request) bool {
	token, _ := tokenFrom(r)
	if token == "" {
		return false
	}
	var active bool
	err := s.DB.QueryRow(r.Context(), `SELECT EXISTS(
   SELECT 1 FROM app.auth_sessions a JOIN app.users u ON u.id=a.user_id
   WHERE a.token_hash=$1 AND a.expires_at>now() AND u.id=$2 AND u.active AND 'student'=ANY(u.roles) AND u.ai_consented_at IS NOT NULL)`,
		tokenHash(token), UserID(r)).Scan(&active)
	return err == nil && active
}

func (s *Server) Student(next http.HandlerFunc) http.HandlerFunc {
	return s.Auth(func(w http.ResponseWriter, r *http.Request) {
		if !actor(r).Has("student") {
			errorOut(w, forbidden())
			return
		}
		if oneOf(r.Method, "POST", "PUT") && (strings.HasSuffix(r.URL.Path, "/inputs") ||
			strings.HasSuffix(r.URL.Path, "/retry") || strings.HasSuffix(r.URL.Path, "/share-summary")) {
			var allowed bool
			if err := s.DB.QueryRow(r.Context(), "SELECT ai_consented_at IS NOT NULL FROM app.users WHERE id=$1", UserID(r)).Scan(&allowed); err != nil {
				errorOut(w, err)
				return
			}
			if !allowed {
				errorOut(w, fail(403, "ai_consent_required", "请先阅读并确认 AI 使用说明"))
				return
			}
		}
		next(w, r)
	})
}

func (s *Server) Admin(next http.HandlerFunc) http.HandlerFunc {
	return s.Auth(func(w http.ResponseWriter, r *http.Request) {
		if !actor(r).Has("admin") {
			errorOut(w, forbidden())
			return
		}
		next(w, r)
	})
}

func notice(ctx context.Context, q queryer, user string, work bool, kind, title, body, target, targetID string) error {
	_, err := q.Exec(ctx, `INSERT INTO app.notifications(user_id,work,kind,title,body,target_type,target_id) VALUES($1,$2,$3,$4,$5,$6,NULLIF($7,'')::uuid)`, user, work, kind, title, body, target, targetID)
	return err
}
func record(ctx context.Context, q queryer, kind, oid, operator, action, note, studentNote string) error {
	_, err := q.Exec(ctx, `INSERT INTO app.history(kind,object_id,actor_id,action,note,student_note) VALUES($1,$2,NULLIF($3,'')::uuid,$4,$5,$6)`, kind, oid, operator, action, note, studentNote)
	return err
}
