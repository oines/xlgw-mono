package harbor

import (
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/bcrypt"
)

func validLink(raw string) bool {
	if raw == "" {
		return true
	}
	u, e := url.Parse(raw)
	return e == nil && u.Hostname() != "" && u.User == nil && oneOf(u.Scheme, "http", "https")
}

type resource struct {
	Kind, Title, Body, URL string
	Published              bool
}

const resourceColumns = "id,kind,title,body,url,published,created_at"

func (s *Server) resources(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, "SELECT "+resourceColumns+" FROM app.resources WHERE published AND ($1='' OR kind=$1) ORDER BY created_at DESC LIMIT $2 OFFSET $3", r.URL.Query().Get("kind"), n, o)
}
func (s *Server) adminResources(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, "SELECT "+resourceColumns+" FROM app.resources WHERE ($1='' OR kind=$1) ORDER BY created_at DESC LIMIT $2 OFFSET $3", r.URL.Query().Get("kind"), n, o)
}
func resourceInput(r *http.Request) (resource, error) {
	var in resource
	if err := decode(r, &in); err != nil {
		return in, err
	}
	if !oneOf(in.Kind, "support", "article", "activity", "announcement") || !validLink(in.URL) {
		return in, invalid("请选择资源类型并检查链接")
	}
	var err error
	if in.Title, err = field(in.Title, "标题", 1, 100); err != nil {
		return in, err
	}
	in.Body, err = field(in.Body, "内容", 1, 5000)
	return in, err
}
func (s *Server) createResource(r *http.Request) (any, error) {
	in, err := resourceInput(r)
	if err != nil {
		return nil, err
	}
	return transaction(r.Context(), s.DB, func(tx pgx.Tx) (any, error) {
		var uid string
		if err := tx.QueryRow(r.Context(), `INSERT INTO app.resources(kind,title,body,url,published) VALUES($1,$2,$3,$4,$5) RETURNING id`, in.Kind, in.Title, in.Body, in.URL, in.Published).Scan(&uid); err != nil {
			return nil, err
		}
		if err := record(r.Context(), tx, "operation", uid, UserID(r), "create_resource", "", ""); err != nil {
			return nil, err
		}
		return object(r.Context(), tx, "SELECT "+resourceColumns+" FROM app.resources WHERE id=$1", uid)
	})
}
func (s *Server) editResource(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	in, err := resourceInput(r)
	if err != nil {
		return nil, err
	}
	return transaction(r.Context(), s.DB, func(tx pgx.Tx) (any, error) {
		if _, err := tx.Exec(r.Context(), `UPDATE app.resources SET kind=$2,title=$3,body=$4,url=$5,published=$6 WHERE id=$1`, uid, in.Kind, in.Title, in.Body, in.URL, in.Published); err != nil {
			return nil, err
		}
		if err := record(r.Context(), tx, "operation", uid, UserID(r), "edit_resource", "", ""); err != nil {
			return nil, err
		}
		return object(r.Context(), tx, "SELECT "+resourceColumns+" FROM app.resources WHERE id=$1", uid)
	})
}
func (s *Server) deleteResource(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	return transaction(r.Context(), s.DB, func(tx pgx.Tx) (any, error) {
		tag, err := tx.Exec(r.Context(), `DELETE FROM app.resources WHERE id=$1`, uid)
		if err != nil {
			return nil, err
		}
		if tag.RowsAffected() == 0 {
			return nil, missing()
		}
		return nil, record(r.Context(), tx, "operation", uid, UserID(r), "delete_resource", "", "")
	})
}
func (s *Server) updateSchool(r *http.Request) (any, error) {
	var in struct {
		Name, Intro, Location, Contact, Timezone *string
		LogoURL                                  *string `json:"logo_url"`
		ServiceHours                             *string `json:"service_hours"`
		RegisteredOpen                           *bool   `json:"registered_open"`
		RegistrationMode                         *string `json:"registration_mode"`
		InviteCode                               *string `json:"invite_code"`
		FollowupDelayHours                       *int    `json:"followup_delay_hours"`
		TeacherMinutes                           *int    `json:"teacher_minutes"`
		PeerMinutes                              *int    `json:"peer_minutes"`
		SlotGapMinutes                           *int    `json:"slot_gap_minutes"`
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if in.Name != nil {
		v, err := field(*in.Name, "学校名称", 1, 80)
		if err != nil {
			return nil, err
		}
		in.Name = &v
	}
	if in.LogoURL != nil && !validLink(*in.LogoURL) {
		return nil, invalid("请填写有效的标志图片链接")
	}
	if in.Timezone != nil {
		var known bool
		if _, err := time.LoadLocation(*in.Timezone); err != nil || *in.Timezone == "" || *in.Timezone == "Local" {
			return nil, invalid("请输入有效时区，如 Asia/Shanghai")
		}
		if err := s.DB.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM pg_timezone_names WHERE name=$1)", *in.Timezone).Scan(&known); err != nil {
			return nil, err
		}
		if !known {
			return nil, invalid("请输入有效时区，如 Asia/Shanghai")
		}
	}

	for _, v := range []*int{in.TeacherMinutes, in.PeerMinutes} {
		if v != nil && (*v < 10 || *v > 180) {
			return nil, invalid("服务时长应为 10–180 分钟")
		}
	}
	if in.SlotGapMinutes != nil && (*in.SlotGapMinutes < 0 || *in.SlotGapMinutes > 60) || in.FollowupDelayHours != nil && (*in.FollowupDelayHours < 0 || *in.FollowupDelayHours > 720) {
		return nil, invalid("检查预约间隔或回访延迟")
	}
	if in.RegistrationMode != nil && !oneOf(*in.RegistrationMode, "open", "invite") {
		return nil, invalid("注册方式无效")
	}
	var hash *string
	if in.InviteCode != nil && strings.TrimSpace(*in.InviteCode) != "" {
		code := strings.TrimSpace(*in.InviteCode)
		if len(code) < 6 || len(code) > 72 {
			return nil, invalid("邀请码长度为 6–72 字节")
		}
		value, err := bcrypt.GenerateFromPassword([]byte(code), bcrypt.DefaultCost)
		if err != nil {
			return nil, err
		}
		v := string(value)
		hash = &v
	}
	return transaction(r.Context(), s.DB, func(tx pgx.Tx) (any, error) {
		if _, err := tx.Exec(r.Context(), `UPDATE app.settings SET name=coalesce($1,name),intro=coalesce($2,intro),logo_url=coalesce($3,logo_url),location=coalesce($4,location),contact=coalesce($5,contact),service_hours=coalesce($6,service_hours),timezone=coalesce($7,timezone),registered_open=coalesce($8,registered_open),followup_delay_hours=coalesce($9,followup_delay_hours),teacher_minutes=coalesce($10,teacher_minutes),peer_minutes=coalesce($11,peer_minutes),slot_gap_minutes=coalesce($12,slot_gap_minutes),registration_mode=coalesce($13,registration_mode),invite_hash=coalesce($14,invite_hash)`, in.Name, in.Intro, in.LogoURL, in.Location, in.Contact, in.ServiceHours, in.Timezone, in.RegisteredOpen, in.FollowupDelayHours, in.TeacherMinutes, in.PeerMinutes, in.SlotGapMinutes, in.RegistrationMode, hash); err != nil {
			return nil, err
		}
		var inviteOkay bool
		if err := tx.QueryRow(r.Context(), "SELECT registration_mode='open' OR invite_hash IS NOT NULL FROM app.settings").Scan(&inviteOkay); err != nil {
			return nil, err
		}
		if !inviteOkay {
			return nil, invalid("请设置学生注册邀请码")
		}
		if err := record(r.Context(), tx, "operation", UserID(r), UserID(r), "update_settings", "", ""); err != nil {
			return nil, err
		}
		return object(r.Context(), tx, schoolSelect)
	})
}

const feedbackSelect = `SELECT f.id,f.student_id,u.nickname student_name,f.category,f.body,f.contact,f.status,f.reply,f.created_at FROM app.feedback f JOIN app.users u ON u.id=f.student_id`

func (s *Server) feedback(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, feedbackSelect+" WHERE f.student_id=$1 ORDER BY created_at DESC LIMIT $2 OFFSET $3", UserID(r), n, o)
}
func (s *Server) createFeedback(r *http.Request) (any, error) {
	var in struct{ Category, Body, Contact string }
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	body, err := field(in.Body, "反馈内容", 1, 1500)
	if err != nil {
		return nil, err
	}
	category, err := field(in.Category, "反馈类型", 1, 40)
	if err != nil {
		return nil, err
	}
	contact, err := field(in.Contact, "联系方式", 0, 100)
	if err != nil {
		return nil, err
	}
	var uid string
	if err = s.DB.QueryRow(r.Context(), `INSERT INTO app.feedback(student_id,category,body,contact) VALUES($1,$2,$3,$4) RETURNING id`, UserID(r), category, body, contact).Scan(&uid); err != nil {
		return nil, err
	}
	return object(r.Context(), s.DB, feedbackSelect+" WHERE f.id=$1", uid)
}
func (s *Server) adminFeedback(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, feedbackSelect+" WHERE ($1='' OR status=$1) ORDER BY created_at DESC LIMIT $2 OFFSET $3", r.URL.Query().Get("status"), n, o)
}
func (s *Server) updateFeedback(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in struct {
		Status string
		Reply  *string
	}
	if err = decode(r, &in); err != nil {
		return nil, err
	}
	if !oneOf(in.Status, "pending", "processing", "resolved") {
		return nil, invalid("请选择处理状态")
	}
	if in.Reply != nil {
		v, err := field(*in.Reply, "回复", 0, 1500)
		if err != nil {
			return nil, err
		}
		in.Reply = &v
	}
	ctx := r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var student, oldStatus, oldReply string
		if err := tx.QueryRow(ctx, "SELECT student_id,status,reply FROM app.feedback WHERE id=$1 FOR UPDATE", uid).Scan(&student, &oldStatus, &oldReply); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `UPDATE app.feedback SET status=$2,reply=coalesce($3,reply) WHERE id=$1`, uid, in.Status, in.Reply); err != nil {
			return nil, err
		}
		if oldStatus != in.Status || in.Reply != nil && *in.Reply != oldReply {
			if err := notice(ctx, tx, student, false, "feedback", "你的反馈有新进展", "", "feedback", uid); err != nil {
				return nil, err
			}
		}
		return object(ctx, tx, feedbackSelect+" WHERE f.id=$1", uid)
	})
}
func (s *Server) operations(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, `SELECT h.id,h.object_id,h.action,h.note,h.created_at,u.nickname actor_name FROM app.history h LEFT JOIN app.users u ON u.id=h.actor_id WHERE h.kind='operation' ORDER BY h.id DESC LIMIT $1 OFFSET $2`, n, o)
}
func (s *Server) stats(r *http.Request) (any, error) {
	ctx := r.Context()
	var timezone string
	if err := s.DB.QueryRow(ctx, `SELECT timezone FROM app.settings`).Scan(&timezone); err != nil {
		return nil, err
	}
	tz, err := time.LoadLocation(timezone)
	if err != nil {
		return nil, err
	}
	today := time.Now().In(tz)
	from, to := today.AddDate(0, 0, -13).Format("2006-01-02"), today.Format("2006-01-02")
	if v := r.URL.Query().Get("from"); v != "" {
		from = v
	}
	if v := r.URL.Query().Get("to"); v != "" {
		to = v
	}
	a, e := time.Parse("2006-01-02", from)
	b, f := time.Parse("2006-01-02", to)
	if e != nil || f != nil || a.After(b) || b.Sub(a) > 366*24*time.Hour {
		return nil, invalid("检查统计时间范围")
	}
	sql := `WITH days AS (
 SELECT generate_series($1::date,$2::date,interval '1 day')::date date
 ), data AS (
 SELECT date,
 (SELECT count(*) FROM app.users WHERE (created_at AT TIME ZONE $3)::date=date AND 'student'=ANY(roles)) registered,
 (SELECT count(*) FROM app.activity WHERE day=date) active,
 (SELECT count(*) FROM app.ai_admissions WHERE NOT is_retry AND (created_at AT TIME ZONE $3)::date=date) ai_inputs,
 (SELECT count(*) FROM app.services WHERE appointment_id IS NOT NULL AND status='completed' AND (completed_at AT TIME ZONE $3)::date=date) appointments_completed,
 (SELECT count(*) FROM app.followups WHERE (submitted_at AT TIME ZONE $3)::date=date) followups_submitted FROM days
 )
 SELECT coalesce(sum(registered),0) registered,(SELECT count(DISTINCT user_id) FROM app.activity WHERE day BETWEEN $1::date AND $2::date) active,coalesce(sum(ai_inputs),0) ai_inputs,
 coalesce(sum(appointments_completed),0) appointments_completed,coalesce(sum(followups_submitted),0) followups_submitted,
 (SELECT count(*) FROM app.appointments WHERE status='pending')+(SELECT count(*) FROM app.help_requests WHERE status<>'closed')+(SELECT count(*) FROM app.followups WHERE status IN ('pending_review','pending_contact','following'))+(SELECT count(*) FROM app.reports WHERE status='pending') pending,
 jsonb_agg(to_jsonb(data) ORDER BY date) series FROM data`
	return object(ctx, s.DB, strings.TrimSpace(sql), from, to, timezone)
}
