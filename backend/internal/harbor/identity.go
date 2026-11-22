package harbor

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

var accountPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_.@-]{2,63}$`)

func credentials(account, password string) (string, []byte, error) {
	account = strings.ToLower(strings.TrimSpace(account))
	if !accountPattern.MatchString(account) {
		return "", nil, invalid("账号应为 3–64 位字母、数字和常用符号")
	}
	if len(password) < 8 || len(password) > 72 {
		return "", nil, invalid("密码请填写 8–72 字节")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return account, hash, err
}
func (s *Server) Bootstrap(ctx context.Context, account, password string) error {
	if account == "" && password == "" {
		return nil
	}
	var exists bool
	if err := s.DB.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM app.users WHERE active AND 'admin'=ANY(roles))`).Scan(&exists); err != nil || exists {
		return err
	}
	account, hash, err := credentials(account, password)
	if err != nil {
		return err
	}
	_, err = s.DB.Exec(ctx, `INSERT INTO app.users(account,password_hash,nickname,roles) VALUES($1,$2,'运营管理员',ARRAY['admin'])`, account, string(hash))
	return err
}

const schoolSelect = `SELECT id,name,intro,logo_url,location,contact,service_hours,timezone,registered_open,
 followup_delay_hours,teacher_minutes,peer_minutes,slot_gap_minutes,registration_mode,(invite_hash IS NOT NULL) invite_configured,
 EXISTS(SELECT 1 FROM app.users WHERE active AND 'admin'=ANY(roles)) initialized FROM app.settings`

func (s *Server) school(r *http.Request) (any, error) { return object(r.Context(), s.DB, schoolSelect) }

type loginRequest struct {
	Account, Password, Nickname string
	InviteCode                  string `json:"invite_code"`
	Roles                       []string
}

func (s *Server) authenticate(register bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" {
			host := r.Host
			if f := r.Header.Get("X-Forwarded-Host"); f != "" {
				host = f
			}
			if origin != "http://"+host && origin != "https://"+host {
				errorOut(w, forbidden())
				return
			}
		}
		var in loginRequest
		if err := decode(r, &in); err != nil {
			errorOut(w, err)
			return
		}
		ctx := r.Context()
		token := newToken()
		expires := time.Now().Add(30 * 24 * time.Hour)
		u, err := transaction(ctx, s.DB, func(tx pgx.Tx) (User, error) {
			var uid string
			if register {
				a, h, err := credentials(in.Account, in.Password)
				if err != nil {
					return User{}, err
				}
				name, err := field(in.Nickname, "昵称", 1, 32)
				if err != nil {
					return User{}, err
				}
				var open bool
				var mode string
				var invite *string
				if err = tx.QueryRow(ctx, "SELECT registered_open,registration_mode,invite_hash FROM app.settings").Scan(&open, &mode, &invite); err != nil {
					return User{}, err
				}
				if !open {
					return User{}, fail(403, "registration_closed", "学校暂未开放注册")
				}
				if mode == "invite" && (invite == nil || bcrypt.CompareHashAndPassword([]byte(*invite), []byte(strings.TrimSpace(in.InviteCode))) != nil) {
					return User{}, fail(403, "invite_required", "学校注册需要有效的邀请码")
				}

				if err = tx.QueryRow(ctx, `SELECT registered_open FROM app.settings`).Scan(&open); err != nil {
					return User{}, err
				}
				if !open {
					return User{}, fail(403, "registration_closed", "学校暂未开放注册")
				}
				if err = tx.QueryRow(ctx, `INSERT INTO app.users(account,password_hash,nickname) VALUES($1,$2,$3) RETURNING id`, a, string(h), name).Scan(&uid); err != nil {
					return User{}, err
				}
			} else {
				var h string
				err := tx.QueryRow(ctx, `SELECT id,password_hash FROM app.users WHERE account=$1 AND active FOR SHARE`, strings.ToLower(strings.TrimSpace(in.Account))).Scan(&uid, &h)
				if errors.Is(err, pgx.ErrNoRows) || err == nil && bcrypt.CompareHashAndPassword([]byte(h), []byte(in.Password)) != nil {
					return User{}, fail(401, "invalid_credentials", "账号或密码有误")
				}
				if err != nil {
					return User{}, err
				}
			}
			if _, err := tx.Exec(ctx, `INSERT INTO app.auth_sessions(token_hash,user_id,expires_at) VALUES($1,$2,$3)`, tokenHash(token), uid, expires); err != nil {
				return User{}, err
			}
			return getUser(ctx, tx, "WHERE u.id=$1", uid)
		})
		if err != nil {
			errorOut(w, err)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "harbor_session", Value: token, Path: "/api/v1", HttpOnly: true, Secure: r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https", SameSite: http.SameSiteStrictMode, Expires: expires})
		jsonOut(w, 200, Object{"user": u, "token": token})
	}
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	token, _ := tokenFrom(r)
	if _, err := s.DB.Exec(r.Context(), `DELETE FROM app.auth_sessions WHERE token_hash=$1`, tokenHash(token)); err != nil {
		errorOut(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: "harbor_session", Path: "/api/v1", HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: -1})
	jsonOut(w, 204, nil)
}
func (s *Server) me(r *http.Request) (any, error) { return actor(r), nil }
func (s *Server) updateMe(r *http.Request) (any, error) {
	var in struct {
		Nickname, Theme, Motion *string
		AvatarURL               *string `json:"avatar_url"`
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if in.Nickname != nil {
		val, err := field(*in.Nickname, "昵称", 1, 32)
		if err != nil {
			return nil, err
		}
		in.Nickname = &val
	}
	if in.Theme != nil && !oneOf(*in.Theme, "light", "dark", "system") {
		return nil, invalid("主题无效")
	}
	if in.Motion != nil && !oneOf(*in.Motion, "standard", "subtle", "still") {
		return nil, invalid("动作设置无效")
	}
	if in.AvatarURL != nil && !validLink(*in.AvatarURL) {
		return nil, invalid("头像链接无效")
	}
	if _, err := s.DB.Exec(r.Context(), `UPDATE app.users SET nickname=coalesce($2,nickname),avatar_url=coalesce($3,avatar_url),theme=coalesce($4,theme),motion=coalesce($5,motion) WHERE id=$1`, UserID(r), in.Nickname, in.AvatarURL, in.Theme, in.Motion); err != nil {
		return nil, err
	}
	return getUser(r.Context(), s.DB, "WHERE u.id=$1", UserID(r))
}
func (s *Server) password(r *http.Request) (any, error) {
	var in struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	_, h, err := credentials(actor(r).Account, in.New)
	if err != nil {
		return nil, err
	}
	return transaction(r.Context(), s.DB, func(tx pgx.Tx) (any, error) {
		var old string
		if err := tx.QueryRow(r.Context(), `SELECT password_hash FROM app.users WHERE id=$1 FOR UPDATE`, UserID(r)).Scan(&old); err != nil {
			return nil, err
		}
		if bcrypt.CompareHashAndPassword([]byte(old), []byte(in.Old)) != nil {
			return nil, invalid("当前密码有误")
		}
		if _, err := tx.Exec(r.Context(), `UPDATE app.users SET password_hash=$2 WHERE id=$1`, UserID(r), string(h)); err != nil {
			return nil, err
		}
		token, _ := tokenFrom(r)
		_, err := tx.Exec(r.Context(), `DELETE FROM app.auth_sessions WHERE user_id=$1 AND token_hash<>$2`, UserID(r), tokenHash(token))
		return nil, err
	})
}
func allowedRoles(v []string) bool {
	if len(v) == 0 || len(v) > 4 {
		return false
	}
	seen := map[string]bool{}
	for _, r := range v {
		if !oneOf(r, "student", "teacher", "peer", "admin") || seen[r] {
			return false
		}
		seen[r] = true
	}
	return true
}
func (s *Server) adminCreateUser(r *http.Request) (any, error) {
	var in loginRequest
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	name, err := field(in.Nickname, "昵称", 1, 32)
	if err != nil {
		return nil, err
	}
	a, h, err := credentials(in.Account, in.Password)
	if err != nil {
		return nil, err
	}
	if !allowedRoles(in.Roles) {
		return nil, invalid("请选择有效角色")
	}
	return transaction(r.Context(), s.DB, func(tx pgx.Tx) (any, error) {
		var uid string
		if err := tx.QueryRow(r.Context(), `INSERT INTO app.users(account,password_hash,nickname,roles) VALUES($1,$2,$3,$4) RETURNING id`, a, string(h), name, in.Roles).Scan(&uid); err != nil {
			return nil, err
		}
		if err := record(r.Context(), tx, "operation", uid, UserID(r), "create_user", "", ""); err != nil {
			return nil, err
		}
		return getUser(r.Context(), tx, "WHERE u.id=$1", uid)
	})
}
func (s *Server) adminUsers(r *http.Request) (any, error) {
	n, o := page(r)
	raw := r.URL.Query()
	return items(r.Context(), s.DB, `SELECT u.id,u.account,u.nickname,u.avatar_url,u.roles,u.active,u.theme,u.motion,u.created_at,(SELECT name FROM app.settings) school,
 (SELECT count(*) FROM app.appointments a WHERE a.staff_id=u.id AND a.status IN ('pending','confirmed','in_progress'))+
 (SELECT count(*) FROM app.help_requests h WHERE h.staff_id=u.id AND h.status<>'closed')+
 (SELECT count(*) FROM app.followups f WHERE f.staff_id=u.id AND f.status IN ('pending_review','pending_contact','following')) AS open_items
 FROM app.users u WHERE ($1='' OR u.account ILIKE '%'||$1||'%' OR u.nickname ILIKE '%'||$1||'%') AND ($2='' OR $2=ANY(u.roles))
 AND ($3='' OR u.active::text=$3) ORDER BY created_at DESC,id LIMIT $4 OFFSET $5`, raw.Get("q"), raw.Get("role"), raw.Get("active"), n, o)
}
func (s *Server) adminUpdateUser(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in struct {
		Nickname, Password *string
		Roles              []string
		Active             *bool
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if in.Nickname != nil {
		v, err := field(*in.Nickname, "昵称", 1, 32)
		if err != nil {
			return nil, err
		}
		in.Nickname = &v
	}
	if in.Roles != nil && !allowedRoles(in.Roles) {
		return nil, invalid("请选择有效角色")
	}
	if uid == UserID(r) && (in.Active != nil && !*in.Active || in.Roles != nil && !slices.Contains(in.Roles, "admin")) {
		return nil, invalid("请保留当前登录账号的管理员权限")
	}
	return transaction(r.Context(), s.DB, func(tx pgx.Tx) (any, error) {
		if _, err := tx.Exec(r.Context(), "SELECT pg_advisory_xact_lock(114551072)"); err != nil {
			return nil, err
		}
		current, err := getUser(r.Context(), tx, "WHERE u.id=$1", UserID(r))
		if err != nil {
			return nil, err
		}
		if !current.Active || !current.Has("admin") {
			return nil, forbidden()
		}
		var hashed *string
		if in.Password != nil {
			u, err := getUser(r.Context(), tx, "WHERE u.id=$1", uid)
			if err != nil {
				return nil, err
			}
			_, h, err := credentials(u.Account, *in.Password)
			if err != nil {
				return nil, err
			}
			v := string(h)
			hashed = &v
		}
		if _, err := tx.Exec(r.Context(), `UPDATE app.users SET nickname=coalesce($2,nickname),roles=coalesce($3,roles),active=coalesce($4,active),password_hash=coalesce($5,password_hash) WHERE id=$1`, uid, in.Nickname, in.Roles, in.Active, hashed); err != nil {
			return nil, err
		}
		if in.Active != nil && !*in.Active || hashed != nil {
			if _, err := tx.Exec(r.Context(), `DELETE FROM app.auth_sessions WHERE user_id=$1`, uid); err != nil {
				return nil, err
			}
		}
		if err := record(r.Context(), tx, "operation", uid, UserID(r), "update_user", "", ""); err != nil {
			return nil, err
		}
		return getUser(r.Context(), tx, "WHERE u.id=$1", uid)
	})
}

var moods = []string{"平静", "开心", "低落", "焦虑", "疲惫", "孤单", "生气", "期待", "迷茫"}
var faceKeys = []string{"faceWidth", "faceLength", "jawWidth", "chinLength", "eyeSize", "eyeSpacing", "browHeight", "noseWidth", "noseLength", "mouthWidth"}
var colorPattern = regexp.MustCompile(`^#[a-fA-F0-9]{6}$`)

type avatarConfig struct {
	Version    int            `json:"version"`
	Preset     string         `json:"preset"`
	Hair       int            `json:"hair"`
	Outfit     int            `json:"outfit"`
	Skin       string         `json:"skin"`
	HairColor  string         `json:"hairColor"`
	EyeColor   string         `json:"eyeColor"`
	ClothColor string         `json:"clothColor"`
	Face       map[string]int `json:"face"`
}

func newAvatar() avatarConfig {
	face := map[string]int{}
	for _, k := range faceKeys {
		face[k] = 50
	}
	return avatarConfig{Version: 1, Preset: "clear", Skin: "#FFFFFF", HairColor: "#FFFFFF", EyeColor: "#FFFFFF", ClothColor: "#6D9D89", Face: face}
}
func (s *Server) catalog(r *http.Request) (any, error) {
	return Object{"version": 1, "presets": []string{"clear", "soft", "poised"}, "moods": moods}, nil
}
func (s *Server) avatar(r *http.Request) (any, error) {
	o, err := object(r.Context(), s.DB, `SELECT revision,config FROM app.avatars WHERE user_id=$1`, UserID(r))
	if errors.Is(err, pgx.ErrNoRows) {
		return Object{"revision": 0, "config": newAvatar()}, nil
	}
	return o, err
}
func (s *Server) saveAvatar(r *http.Request) (any, error) {
	var in struct {
		Revision int
		Config   avatarConfig
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	v := in.Config
	if in.Revision < 0 || v.Version != 1 || !oneOf(v.Preset, "clear", "soft", "poised") || v.Hair < 0 || v.Hair > 5 || v.Outfit < 0 || v.Outfit > 2 || len(v.Face) != len(faceKeys) {
		return nil, invalid("形象版本或部件无效")
	}
	for _, k := range faceKeys {
		if n, ok := v.Face[k]; !ok || n < 0 || n > 100 {
			return nil, invalid("捏脸参数超出范围")
		}
	}
	for _, c := range []string{v.Skin, v.HairColor, v.EyeColor, v.ClothColor} {
		if !colorPattern.MatchString(c) {
			return nil, invalid("颜色格式无效")
		}
	}
	var revision int
	q := `UPDATE app.avatars SET revision=revision+1,config=$3,updated_at=now() WHERE user_id=$1 AND revision=$2 RETURNING revision`
	if in.Revision == 0 {
		q = `INSERT INTO app.avatars(user_id,revision,config) VALUES($1,$2::int+1,$3) ON CONFLICT DO NOTHING RETURNING revision`
	}
	err := s.DB.QueryRow(r.Context(), q, UserID(r), in.Revision, v).Scan(&revision)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, stale("另一台设备已经保存了形象，请先重新加载")
	}
	return Object{"revision": revision, "config": v}, err
}

func (s *Server) aiConsent(r *http.Request) (any, error) {
	if !actor(r).Has("student") {
		return nil, forbidden()
	}
	if r.Method == "POST" {
		var in struct{ Agreed bool }
		if err := decode(r, &in); err != nil {
			return nil, err
		}
		if !in.Agreed {
			return nil, invalid("请确认 AI 使用说明")
		}
		if _, err := s.DB.Exec(r.Context(), "UPDATE app.users SET ai_consented_at=coalesce(ai_consented_at,now()) WHERE id=$1", UserID(r)); err != nil {
			return nil, err
		}
	}
	var accepted bool
	err := s.DB.QueryRow(r.Context(), "SELECT ai_consented_at IS NOT NULL FROM app.users WHERE id=$1", UserID(r)).Scan(&accepted)
	return Object{"agreed": accepted}, err
}
