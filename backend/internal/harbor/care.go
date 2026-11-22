package harbor

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

func openCare(ctx context.Context, tx pgx.Tx, student, staff string, appointment, help *string) (string, string, error) {
	var service, conv string
	if err := tx.QueryRow(ctx, `INSERT INTO app.services(student_id,staff_id,appointment_id,help_id,status) VALUES($1,$2,$3,$4,CASE WHEN $4::uuid IS NULL THEN 'waiting' ELSE 'in_progress' END) RETURNING id`, student, staff, appointment, help).Scan(&service); err != nil {
		return "", "", err
	}
	if err := tx.QueryRow(ctx, `INSERT INTO app.conversations(kind,service_id) VALUES('care',$1) RETURNING id`, service).Scan(&conv); err != nil {
		return "", "", err
	}
	_, err := tx.Exec(ctx, `INSERT INTO app.conversation_members(conversation_id,user_id) VALUES($1,$2),($1,$3)`, conv, student, staff)
	return service, conv, err
}
func moveCare(ctx context.Context, tx pgx.Tx, service, from, to string) error {
	if _, err := tx.Exec(ctx, `UPDATE app.services SET staff_id=$2 WHERE id=$1`, service, to); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM app.conversation_members WHERE conversation_id=(SELECT id FROM app.conversations WHERE service_id=$1) AND user_id=$2`, service, from); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO app.conversation_members(conversation_id,user_id) SELECT id,$2 FROM app.conversations WHERE service_id=$1 ON CONFLICT DO NOTHING`, service, to); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE app.followups SET staff_id=$3 WHERE service_id=$1 AND staff_id=$2 AND status<>'closed'`, service, from, to); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE app.ai_shares SET revoked_at=now() WHERE service_id=$1 AND revoked_at IS NULL`, service); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE app.transfers SET status='rejected' WHERE service_id=$1 AND status='pending'`, service)
	return err
}
func (s *Server) completeCare(ctx context.Context, tx pgx.Tx, service, student, staff string, in careInput) error {
	if strings.TrimSpace(in.InternalNote) == "" {
		return invalid("请填写内部服务记录")
	}
	if _, err := tx.Exec(ctx, `UPDATE app.services SET status='completed',internal_note=$2,student_note=$3,completed_at=now() WHERE id=$1`, service, in.InternalNote, in.StudentNote); err != nil {
		return err
	}
	var fid string
	var immediate bool
	err := tx.QueryRow(ctx, `INSERT INTO app.followups(service_id,student_id,staff_id,available_at,invited) SELECT $1,$2,$3,now()+followup_delay_hours*interval '1 hour',followup_delay_hours=0 FROM app.settings RETURNING id,invited`, service, student, staff).Scan(&fid, &immediate)
	if err != nil {
		return err
	}
	if immediate {
		return notice(ctx, tx, student, false, "followup", "可以填写服务回访了", "告诉我们这次交流是否对你有帮助。", "followup", fid)
	}
	return nil
}

const serviceSelect = `SELECT s.id,s.student_id,st.nickname student_name,s.staff_id,u.nickname staff_name,p.role,s.appointment_id,s.help_id,c.id conversation_id,s.status,
 CASE WHEN s.staff_id=$1 AND $2 THEN s.internal_note END internal_note,s.student_note,s.completed_at,s.created_at
 FROM app.services s JOIN app.users st ON st.id=s.student_id JOIN app.users u ON u.id=s.staff_id JOIN app.staff p ON p.id=s.staff_id
 JOIN app.conversations c ON c.service_id=s.id`

const serviceAccess = `(s.student_id=$1 OR s.staff_id=$1 AND $2 AND p.active AND u.active AND p.role=ANY(u.roles))`

func (s *Server) services(r *http.Request) (any, error) {
	work := r.URL.Query().Get("scope") == "work"
	u := actor(r)
	n, o := page(r)
	if work && !u.Work() {
		return nil, forbidden()
	}
	return items(r.Context(), s.DB, serviceSelect+` WHERE CASE WHEN $2 THEN s.staff_id=$1 AND p.active AND u.active AND p.role=ANY(u.roles) ELSE s.student_id=$1 END ORDER BY s.created_at DESC LIMIT $3 OFFSET $4`, u.ID, work, n, o)
}
func (s *Server) serviceDetail(r *http.Request) (any, error) {
	id, err := pathID(r)
	if err != nil {
		return nil, err
	}
	u, ctx := actor(r), r.Context()
	v, err := object(ctx, s.DB, serviceSelect+" WHERE s.id=$3 AND "+serviceAccess, u.ID, u.Work(), id)
	if err != nil {
		return nil, err
	}
	shares, err := s.readShares(ctx, u, id)
	if err != nil {
		return nil, err
	}
	v["shares"] = shares["items"]
	return v, nil
}
func (s *Server) readShares(ctx context.Context, u User, id string) (Object, error) {
	return items(ctx, s.DB, `SELECT h.id,h.body,h.conversation_id,h.created_at FROM app.ai_shares h JOIN app.services s ON s.id=h.service_id
 WHERE s.id=$3 AND (s.student_id=$1 OR s.staff_id=$1 AND h.staff_id=$1 AND $2 AND EXISTS (
 SELECT 1 FROM app.staff profile JOIN app.users account ON account.id=profile.id
 WHERE profile.id=$1 AND profile.active AND account.active AND profile.role=ANY(account.roles))) AND h.revoked_at IS NULL AND s.status<>'closed'
 AND (s.completed_at IS NULL OR s.completed_at+interval '7 days'>now()) ORDER BY h.created_at DESC`, u.ID, u.Work(), id)
}
func (s *Server) serviceShares(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	return s.readShares(r.Context(), actor(r), uid)
}
func (s *Server) myShares(r *http.Request) (any, error) {
	return items(r.Context(), s.DB, `SELECT h.id,h.body,h.service_id,h.staff_id,u.nickname staff_name,h.conversation_id,h.created_at,h.revoked_at,
 h.revoked_at IS NULL AND s.status<>'closed' AND (s.completed_at IS NULL OR s.completed_at+interval '7 days'>now()) active
 FROM app.ai_shares h JOIN app.services s ON s.id=h.service_id JOIN app.users u ON u.id=h.staff_id WHERE h.student_id=$1 ORDER BY h.created_at DESC LIMIT 100`, UserID(r))
}
func (s *Server) createShare(r *http.Request) (any, error) {
	sid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in struct {
		ConversationID  string   `json:"conversation_id"`
		MessageIDs      []string `json:"message_ids"`
		ExpectedStaffID string   `json:"expected_staff_id"`
		Summary         string
	}
	if err = decode(r, &in); err != nil {
		return nil, err
	}
	conv, err := id(in.ConversationID)
	if err != nil {
		return nil, err
	}
	expected, err := id(in.ExpectedStaffID)
	if err != nil {
		return nil, invalid("请确认分享接收人")
	}
	ctx, student := r.Context(), UserID(r)
	body, err := field(in.Summary, "分享摘要", 0, 6000)
	if err != nil {
		return nil, err
	}
	if body == "" {
		if len(in.MessageIDs) == 0 || len(in.MessageIDs) > 20 || s.ShareMessages == nil {
			return nil, invalid("请选择要分享的消息")
		}
		body, err = s.ShareMessages(ctx, student, conv, in.MessageIDs)
		if err != nil {
			return nil, invalid("无法读取选中的 AI 消息")
		}
		if body, err = field(body, "分享内容", 1, 20000); err != nil {
			return nil, err
		}
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var staff string
		if err := tx.QueryRow(ctx, `SELECT staff_id FROM app.services WHERE id=$1 AND student_id=$2 AND status<>'closed' AND (completed_at IS NULL OR completed_at+interval '7 days'>now()) FOR UPDATE`, sid, student).Scan(&staff); err != nil {
			return nil, err
		}
		if staff != expected {
			return nil, stale("负责人员已更换，请重新确认分享接收人")
		}
		if err := eligibleStaff(ctx, tx, staff, ""); err != nil {
			return nil, err
		}
		var owned bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app.ai_conversations WHERE id=$1 AND user_id=$2 AND NOT deleting)`, conv, student).Scan(&owned); err != nil {
			return nil, err
		}
		if !owned {
			return nil, missing()
		}
		var shareID string
		var created time.Time
		err := tx.QueryRow(ctx, `INSERT INTO app.ai_shares(service_id,student_id,staff_id,conversation_id,body)
            VALUES($1,$2,$3,$4,$5) RETURNING id,created_at`, sid, student, staff, conv, body).Scan(&shareID, &created)
		v := Object{"id": shareID, "body": body, "created_at": created}
		if err != nil {
			return nil, err
		}
		return v, notice(ctx, tx, staff, true, "share", "学生分享了一段 AI 聊天内容", "", "service", sid)
	})
}
func (s *Server) deleteShare(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.ai_shares SET revoked_at=coalesce(revoked_at,now()) WHERE id=$1 AND student_id=$2`, uid, UserID(r))
	if err == nil && tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return nil, err
}

const followupSelect = `SELECT f.id,f.service_id,f.student_id,u.nickname student_name,f.staff_id,p.nickname staff_name,f.status,
 CASE WHEN f.student_id=$1 OR f.staff_id=$1 AND $2 AND p.active AND profile.active AND profile.role=ANY(p.roles) AND f.submitted_at IS NOT NULL THEN f.answers ELSE '{}'::jsonb END answers,
 f.created_at,f.available_at,f.submitted_at,NOT EXISTS(SELECT 1 FROM app.staff s WHERE s.id=f.staff_id AND s.active AND s.role=ANY(p.roles) AND p.active) needs_assignment,
 coalesce((SELECT jsonb_agg(jsonb_build_object('action',log.action,'note',CASE WHEN f.staff_id=$1 AND $2 AND p.active AND profile.active AND profile.role=ANY(p.roles) THEN log.note ELSE '' END,
 'student_note',log.student_note,'actor_name',author.nickname,'created_at',log.created_at) ORDER BY log.id)
 FROM app.history log LEFT JOIN app.users author ON author.id=log.actor_id WHERE log.kind='followup' AND log.object_id=f.id),'[]') history
 FROM app.followups f JOIN app.users u ON u.id=f.student_id JOIN app.users p ON p.id=f.staff_id JOIN app.staff profile ON profile.id=f.staff_id`

func (s *Server) followups(r *http.Request) (any, error) {
	u := actor(r)
	work := r.URL.Query().Get("scope") == "work"
	if work && !u.Work() && !u.Has("admin") {
		return nil, forbidden()
	}
	staff, err := optionalID(r.URL.Query().Get("staff_id"))
	if err != nil {
		return nil, err
	}
	n, o := page(r)
	return items(r.Context(), s.DB, followupSelect+` WHERE (CASE WHEN $2 THEN f.staff_id=$1 AND p.active AND profile.active AND profile.role=ANY(p.roles) OR $3 ELSE f.student_id=$1 AND f.available_at<=now() END)
 AND ($4='' OR f.status=$4) AND ($5::uuid IS NULL OR f.staff_id=$5) ORDER BY f.created_at DESC LIMIT $6 OFFSET $7`, u.ID, work, u.Has("admin"), r.URL.Query().Get("status"), staff, n, o)
}
func (s *Server) followupDetail(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	u := actor(r)
	return object(r.Context(), s.DB, followupSelect+` WHERE f.id=$3 AND (f.student_id=$1 AND f.available_at<=now() OR f.staff_id=$1 AND $2 AND p.active AND profile.active AND profile.role=ANY(p.roles) OR $4)`, u.ID, u.Work(), uid, u.Has("admin"))
}

type answer struct {
	Mood             string `json:"mood"`
	Helpfulness      string `json:"helpfulness"`
	Recommendation   string `json:"recommendation"`
	Note             string `json:"note"`
	ContactRequested bool   `json:"contact_requested"`
}

func readAnswer(r *http.Request, submit bool) (answer, error) {
	var in answer
	if err := decode(r, &in); err != nil {
		return in, err
	}
	if (in.Mood != "" || submit) && !oneOf(in.Mood, "better", "same", "worse") {
		return in, invalid("请选择当前状态")
	}
	if (in.Helpfulness != "" || submit) && !oneOf(in.Helpfulness, "helpful", "neutral", "unhelpful") {
		return in, invalid("请选择帮助程度")
	}
	if _, err := field(in.Recommendation, "推荐意愿", 0, 100); err != nil {
		return in, err
	}
	if _, err := field(in.Note, "意见", 0, 1000); err != nil {
		return in, err
	}
	return in, nil
}
func (s *Server) followupDraft(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	in, err := readAnswer(r, false)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.followups SET answers=$3 WHERE id=$1 AND student_id=$2 AND available_at<=now() AND status='awaiting'`, uid, UserID(r), in)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, stale("问卷已提交或暂不可填写")
	}
	return s.followupDetail(r)
}
func (s *Server) followupAction(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	u, ctx, action := actor(r), r.Context(), r.PathValue("action")
	var in careInput
	var a answer
	if action == "submit" {
		a, err = readAnswer(r, true)
	} else {
		err = decode(r, &in)
	}
	if err != nil {
		return nil, err
	}
	if _, err := field(in.Note, "跟进记录", 0, 2000); err != nil {
		return nil, err
	}
	if _, err := field(in.StudentNote, "给学生的安排", 0, 1000); err != nil {
		return nil, err
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var student, staff, status, role, supervisor string
		var available bool
		if err := tx.QueryRow(ctx, `SELECT f.student_id,f.staff_id,f.status,p.role,coalesce(p.supervisor_id::text,''),f.available_at<=now() FROM app.followups f JOIN app.staff p ON p.id=f.staff_id WHERE f.id=$1 FOR UPDATE OF f`, uid).Scan(&student, &staff, &status, &role, &supervisor, &available); err != nil {
			return nil, err
		}
		if u.ID != student && u.ID != staff && !u.Has("admin") {
			return nil, missing()
		}
		next := status
		if action == "submit" {
			if student != u.ID || !available {
				return nil, forbidden()
			}
			if status != "awaiting" {
				return object(ctx, tx, followupSelect+" WHERE f.id=$3", u.ID, false, uid)
			}
			next = "pending_review"
			if a.Mood == "worse" || a.ContactRequested {
				next = "pending_contact"
				if role == "peer" && supervisor != "" {
					staff = supervisor
				}
			}
			if _, err := tx.Exec(ctx, `UPDATE app.followups SET answers=$2,submitted_at=now(),status=$3,staff_id=$4 WHERE id=$1`, uid, a, next, staff); err != nil {
				return nil, err
			}
			roleNeeded := ""
			if next == "pending_contact" {
				roleNeeded = "teacher"
			}
			if err := eligibleStaff(ctx, tx, staff, roleNeeded); err == nil {
				if err := notice(ctx, tx, staff, true, "followup", "收到一份新的服务回访", "", "followup", uid); err != nil {
					return nil, err
				}
			}
		} else {
			if action == "reassign" {
				if !u.Has("admin") {
					return nil, forbidden()
				}
			} else if u.ID != staff || !u.Work() {
				return nil, forbidden()
			}
			if action != "reassign" {
				if err := eligibleStaff(ctx, tx, staff, ""); err != nil {
					return nil, err
				}
			}
			switch action {
			case "resend":
				if status != "awaiting" {
					return nil, stale("问卷已填写")
				}
				if _, err := tx.Exec(ctx, `UPDATE app.followups SET available_at=least(available_at,now()),invited=true WHERE id=$1`, uid); err != nil {
					return nil, err
				}
				if err := notice(ctx, tx, student, false, "followup", "记得填写服务回访", "", "followup", uid); err != nil {
					return nil, err
				}
			case "review":
				if status != "pending_review" {
					return nil, stale("当前回访无法标记为已阅")
				}
				next = "closed"
			case "contact":
				if role != "teacher" {
					return nil, forbidden()
				}
				if !oneOf(status, "pending_contact", "following", "pending_review") || strings.TrimSpace(in.Note) == "" {
					return nil, invalid("请填写联系记录")
				}
				next = "following"
			case "close":
				if !oneOf(status, "pending_contact", "following", "pending_review") {
					return nil, stale("当前回访无法结案")
				}
				next = "closed"
			case "reassign":
				if status == "closed" {
					return nil, stale("回访已经结案")
				}
				staff, err = id(in.StaffID)
				if err != nil {
					return nil, err
				}
				role := ""
				if oneOf(status, "pending_contact", "following") {
					role = "teacher"
				}
				if err := eligibleStaff(ctx, tx, staff, role); err != nil {
					return nil, err
				}
				if err := notice(ctx, tx, staff, true, "followup", "一份回访已分配给你", "", "followup", uid); err != nil {
					return nil, err
				}
			default:
				return nil, missing()
			}
			if _, err := tx.Exec(ctx, `UPDATE app.followups SET status=$2,staff_id=$3 WHERE id=$1`, uid, next, staff); err != nil {
				return nil, err
			}
			if strings.TrimSpace(in.StudentNote) != "" {
				if err := notice(ctx, tx, student, false, "followup", "你的回访有新的跟进安排", in.StudentNote, "followup", uid); err != nil {
					return nil, err
				}
			}
		}
		if err := record(ctx, tx, "followup", uid, u.ID, action, in.Note, in.StudentNote); err != nil {
			return nil, err
		}
		return object(ctx, tx, followupSelect+" WHERE f.id=$3", u.ID, action != "submit" && u.ID == staff, uid)
	})
}

const helpSelect = `SELECT h.id,h.student_id,st.nickname student_name,h.staff_id,u.nickname staff_name,
 CASE WHEN h.student_id=$1 OR h.staff_id=$1 AND $2 AND profile.active AND u.active AND profile.role='teacher' AND profile.role=ANY(u.roles) THEN h.contact ELSE '' END contact,
 CASE WHEN h.student_id=$1 OR h.staff_id=$1 AND $2 AND profile.active AND u.active AND profile.role='teacher' AND profile.role=ANY(u.roles) THEN h.body ELSE '' END body,
 h.preferred_time,h.status,h.created_at,s.id service_id,c.id conversation_id,
 coalesce((SELECT jsonb_agg(jsonb_build_object('action',log.action,'note',CASE WHEN h.staff_id=$1 AND $2 AND profile.active AND u.active AND profile.role='teacher' AND profile.role=ANY(u.roles) THEN log.note ELSE '' END,
 'student_note',log.student_note,'actor_name',author.nickname,'created_at',log.created_at) ORDER BY log.id)
 FROM app.history log LEFT JOIN app.users author ON author.id=log.actor_id WHERE log.kind='help' AND log.object_id=h.id),'[]') history
 FROM app.help_requests h JOIN app.users st ON st.id=h.student_id LEFT JOIN app.users u ON u.id=h.staff_id LEFT JOIN app.staff profile ON profile.id=h.staff_id LEFT JOIN app.services s ON s.help_id=h.id LEFT JOIN app.conversations c ON c.service_id=s.id`

func (s *Server) helpRequests(r *http.Request) (any, error) {
	u := actor(r)
	work := r.URL.Query().Get("scope") == "work"
	if work && !u.Has("teacher") && !u.Has("admin") {
		return nil, forbidden()
	}
	if work && !u.Has("admin") {
		if err := eligibleStaff(r.Context(), s.DB, u.ID, "teacher"); err != nil {
			return nil, forbidden()
		}
	}
	staff, err := optionalID(r.URL.Query().Get("staff_id"))
	if err != nil {
		return nil, err
	}
	n, o := page(r)
	return items(r.Context(), s.DB, helpSelect+` WHERE (CASE WHEN $2 THEN $3 OR h.staff_id IS NULL OR h.staff_id=$1 AND profile.active AND u.active AND profile.role='teacher' AND profile.role=ANY(u.roles) ELSE h.student_id=$1 END)
 AND ($4='' OR h.status=$4) AND ($5::uuid IS NULL OR h.staff_id=$5) ORDER BY h.created_at DESC LIMIT $6 OFFSET $7`, u.ID, work, u.Has("admin"), r.URL.Query().Get("status"), staff, n, o)
}
func (s *Server) helpDetail(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	u := actor(r)
	teacher := u.Has("teacher") && eligibleStaff(r.Context(), s.DB, u.ID, "teacher") == nil
	return object(r.Context(), s.DB, helpSelect+` WHERE h.id=$3 AND (h.student_id=$1 OR (h.staff_id IS NULL OR h.staff_id=$1 AND profile.active AND u.active AND profile.role='teacher' AND profile.role=ANY(u.roles)) AND $2 OR $4)`, u.ID, teacher, uid, u.Has("admin"))
}
func (s *Server) createHelp(r *http.Request) (any, error) {
	if !actor(r).Has("student") {
		return nil, forbidden()
	}
	var in struct {
		Contact, Body string
		PreferredTime string `json:"preferred_time"`
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if _, err := field(in.Contact, "联系方式", 1, 120); err != nil {
		return nil, err
	}
	if _, err := field(in.Body, "想说明的事情", 1, 1500); err != nil {
		return nil, err
	}
	if _, err := field(in.PreferredTime, "方便联系的时间", 0, 120); err != nil {
		return nil, err
	}
	ctx, uid := r.Context(), UserID(r)
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var hid string
		if err := tx.QueryRow(ctx, `INSERT INTO app.help_requests(student_id,contact,body,preferred_time) VALUES($1,$2,$3,$4) RETURNING id`, uid, strings.TrimSpace(in.Contact), strings.TrimSpace(in.Body), strings.TrimSpace(in.PreferredTime)).Scan(&hid); err != nil {
			return nil, err
		}
		if err := record(ctx, tx, "help", hid, uid, "submit", "", ""); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO app.notifications(user_id,work,kind,title,target_type,target_id) SELECT id,true,'help','收到新的人工联系请求','help',$1 FROM app.users WHERE active AND 'admin'=ANY(roles)`, hid); err != nil {
			return nil, err
		}
		return object(ctx, tx, helpSelect+" WHERE h.id=$3", uid, false, hid)
	})
}
func (s *Server) helpAction(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	u, ctx, action := actor(r), r.Context(), r.PathValue("action")
	if !u.Has("teacher") && !u.Has("admin") {
		return nil, forbidden()
	}
	var in careInput
	if err = decode(r, &in); err != nil {
		return nil, err
	}
	if _, err := field(in.Note, "联系记录", 0, 2000); err != nil {
		return nil, err
	}
	if _, err := field(in.StudentNote, "给学生的安排", 0, 1000); err != nil {
		return nil, err
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var student, staff, status, service string
		if err := tx.QueryRow(ctx, `SELECT h.student_id,coalesce(h.staff_id::text,''),h.status,coalesce(s.id::text,'') FROM app.help_requests h LEFT JOIN app.services s ON s.help_id=h.id WHERE h.id=$1 FOR UPDATE OF h`, uid).Scan(&student, &staff, &status, &service); err != nil {
			return nil, err
		}
		if status == "closed" {
			return nil, stale("这项求助已结束")
		}
		next, title := status, "你的联系请求有新进展"
		if action == "assign" || action == "claim" {
			target := u.ID
			if action == "assign" {
				if !u.Has("admin") {
					return nil, forbidden()
				}
				target, err = id(in.StaffID)
				if err != nil {
					return nil, err
				}
			} else if !u.Has("teacher") || staff != "" && staff != u.ID {
				return nil, forbidden()
			}
			if target == student {
				return nil, invalid("不能分配给学生本人")
			}
			if err := eligibleStaff(ctx, tx, target, "teacher"); err != nil {
				return nil, err
			}
			if service == "" {
				if _, _, err := openCare(ctx, tx, student, target, nil, &uid); err != nil {
					return nil, err
				}
			} else if target != staff {
				if err := moveCare(ctx, tx, service, staff, target); err != nil {
					return nil, err
				}
			}
			if target != u.ID {
				if err := notice(ctx, tx, target, true, "help", "一项人工联系请求已分配给你", "", "help", uid); err != nil {
					return nil, err
				}
			}
			staff = target
			if status == "submitted" {
				next = "assigned"
			}
		} else {
			if staff != u.ID || !u.Has("teacher") {
				return nil, forbidden()
			}
			if err := eligibleStaff(ctx, tx, staff, "teacher"); err != nil {
				return nil, err
			}
			switch action {
			case "contact":
				if strings.TrimSpace(in.Note) == "" {
					return nil, invalid("请填写联系记录")
				}
				next = "contacting"
			case "close":
				if err := s.completeCare(ctx, tx, service, student, staff, careInput{InternalNote: in.Note, StudentNote: in.StudentNote}); err != nil {
					return nil, err
				}
				next, title = "closed", "联系请求已处理"
			default:
				return nil, missing()
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE app.help_requests SET staff_id=$2,status=$3 WHERE id=$1`, uid, staff, next); err != nil {
			return nil, err
		}
		if err := record(ctx, tx, "help", uid, u.ID, action, in.Note, in.StudentNote); err != nil {
			return nil, err
		}
		if err := notice(ctx, tx, student, false, "help", title, in.StudentNote, "help", uid); err != nil {
			return nil, err
		}
		return object(ctx, tx, helpSelect+" WHERE h.id=$3", u.ID, u.Has("teacher"), uid)
	})
}

const transferSelect = `SELECT t.id,t.service_id,t.from_id,f.nickname from_name,t.to_id,u.nickname to_name,st.nickname student_name,t.note,t.status,t.created_at
 FROM app.transfers t JOIN app.services s ON s.id=t.service_id JOIN app.users f ON f.id=t.from_id JOIN app.users u ON u.id=t.to_id JOIN app.users st ON st.id=s.student_id`

func (s *Server) transfers(r *http.Request) (any, error) {
	u := actor(r)
	if !u.Work() && !u.Has("admin") {
		return nil, forbidden()
	}
	if !u.Has("admin") {
		if err := eligibleStaff(r.Context(), s.DB, u.ID, ""); err != nil {
			return nil, forbidden()
		}
	}
	n, o := page(r)
	return items(r.Context(), s.DB, transferSelect+" WHERE (t.from_id=$1 OR t.to_id=$1 OR $2) AND ($3='' OR t.status=$3) ORDER BY t.created_at DESC LIMIT $4 OFFSET $5", u.ID, u.Has("admin"), r.URL.Query().Get("status"), n, o)
}
func (s *Server) createTransfer(r *http.Request) (any, error) {
	u, ctx := actor(r), r.Context()
	if !u.Work() {
		return nil, forbidden()
	}
	var in struct {
		ServiceID string `json:"service_id"`
		StaffID   string `json:"staff_id"`
		Note      string
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	sid, err := id(in.ServiceID)
	if err != nil {
		return nil, err
	}
	to, err := id(in.StaffID)
	if err != nil || to == u.ID {
		return nil, invalid("请选择接手的老师")
	}
	note, err := field(in.Note, "转交说明", 1, 1500)
	if err != nil {
		return nil, err
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var student, staff, status, supervisor, role string
		var aid *string
		if err := tx.QueryRow(ctx, `SELECT s.student_id,s.staff_id,s.status,s.appointment_id,coalesce(p.supervisor_id::text,''),p.role FROM app.services s JOIN app.staff p ON p.id=s.staff_id WHERE s.id=$1 FOR UPDATE OF s`, sid).Scan(&student, &staff, &status, &aid, &supervisor, &role); err != nil {
			return nil, err
		}
		if staff != u.ID || status == "closed" || status == "completed" {
			return nil, forbidden()
		}
		if err := eligibleStaff(ctx, tx, u.ID, ""); err != nil {
			return nil, err
		}
		if to == student || role == "peer" && to != supervisor {
			return nil, invalid("请转交给你的指导老师")
		}
		if err := eligibleStaff(ctx, tx, to, "teacher"); err != nil {
			return nil, err
		}
		var tid string
		if err := tx.QueryRow(ctx, `INSERT INTO app.transfers(service_id,from_id,to_id,note) VALUES($1,$2,$3,$4) RETURNING id`, sid, staff, to, note).Scan(&tid); err != nil {
			return nil, err
		}
		if err := notice(ctx, tx, to, true, "transfer", "收到待接手的服务", "", "transfer", tid); err != nil {
			return nil, err
		}
		return object(ctx, tx, transferSelect+" WHERE t.id=$1", tid)
	})
}
func (s *Server) transferAction(r *http.Request) (any, error) {
	tid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	u, ctx, action := actor(r), r.Context(), r.PathValue("action")
	if !u.Has("teacher") {
		return nil, forbidden()
	}
	if !oneOf(action, "accept", "reject") {
		return nil, missing()
	}
	var in careInput
	if err = decode(r, &in); err != nil {
		return nil, err
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var sid, to, from, state, student, staff, serviceStatus string
		var aid, hid *string
		if err := tx.QueryRow(ctx, `SELECT t.service_id,t.to_id,t.from_id,t.status,s.student_id,s.appointment_id,s.help_id FROM app.transfers t JOIN app.services s ON s.id=t.service_id WHERE t.id=$1`, tid).Scan(&sid, &to, &from, &state, &student, &aid, &hid); err != nil {
			return nil, err
		}
		if u.ID != to {
			return nil, missing()
		}
		if state != "pending" {
			return nil, stale("本次转交已经处理")
		}
		if err := lockedUsers(ctx, tx, student, to, from); err != nil {
			return nil, err
		}
		if err := eligibleStaff(ctx, tx, to, "teacher"); err != nil {
			return nil, err
		}
		if action == "accept" && aid != nil {
			var start, end time.Time
			if err := tx.QueryRow(ctx, `SELECT start_at,end_at FROM app.appointments WHERE id=$1 FOR UPDATE`, *aid).Scan(&start, &end); err != nil {
				return nil, err
			}
			if err := checkBookingTime(ctx, tx, student, to, start, end, *aid); err != nil {
				return nil, err
			}
		}
		if action == "accept" && hid != nil {
			if _, err := tx.Exec(ctx, `SELECT id FROM app.help_requests WHERE id=$1 FOR UPDATE`, *hid); err != nil {
				return nil, err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT staff_id,status FROM app.services WHERE id=$1 FOR UPDATE`, sid).Scan(&staff, &serviceStatus); err != nil {
			return nil, err
		}
		if err := tx.QueryRow(ctx, "SELECT status FROM app.transfers WHERE id=$1 FOR UPDATE", tid).Scan(&state); err != nil {
			return nil, err
		}
		if state != "pending" {
			return nil, stale("本次转交已经处理")
		}
		if staff != from || oneOf(serviceStatus, "closed", "completed") {
			return nil, stale("服务状态或负责人已更新")
		}
		if action == "accept" {
			var role, supervisor string
			if err := tx.QueryRow(ctx, `SELECT role,coalesce(supervisor_id::text,'') FROM app.staff WHERE id=$1`, from).Scan(&role, &supervisor); err != nil {
				return nil, err
			}
			if role == "peer" && supervisor != to {
				return nil, stale("指导老师已变更，请重新发起转交")
			}
			if aid != nil {
				if _, err := tx.Exec(ctx, `UPDATE app.appointments SET staff_id=$2,updated_at=now() WHERE id=$1`, *aid, to); err != nil {
					return nil, err
				}
				if err := record(ctx, tx, "appointment", *aid, to, "transfer", "", ""); err != nil {
					return nil, err
				}
			}
			if hid != nil {
				if _, err := tx.Exec(ctx, `UPDATE app.help_requests SET staff_id=$2 WHERE id=$1`, *hid, to); err != nil {
					return nil, err
				}
			}
			if err := moveCare(ctx, tx, sid, from, to); err != nil {
				return nil, err
			}
			if err := notice(ctx, tx, student, false, "transfer", "服务已由新的老师接手", "", "service", sid); err != nil {
				return nil, err
			}
		}
		status := "rejected"
		if action == "accept" {
			status = "accepted"
		}
		if _, err := tx.Exec(ctx, `UPDATE app.transfers SET status=$2 WHERE id=$1`, tid, status); err != nil {
			return nil, err
		}
		if err := notice(ctx, tx, from, true, "transfer", "转交申请有新进展", in.Note, "transfer", tid); err != nil {
			return nil, err
		}
		return object(ctx, tx, transferSelect+" WHERE t.id=$1", tid)
	})
}

func (s *Server) ProcessDue(ctx context.Context) error {
	returnErr := func() error {
		_, err := s.DB.Exec(ctx, `WITH expired AS (UPDATE app.appointments SET status='expired',reason='开始前未确认',updated_at=now() WHERE status='pending' AND start_at<=now() RETURNING id,student_id,staff_id),
  logged AS (INSERT INTO app.history(kind,object_id,action,note) SELECT 'appointment',id,'expire','开始前未确认' FROM expired)
  INSERT INTO app.notifications(user_id,work,kind,title,target_type,target_id)
  SELECT student_id,false,'appointment','预约未在开始前确认','appointment',id FROM expired UNION ALL SELECT staff_id,true,'appointment','预约申请已过期','appointment',id FROM expired`)
		return err
	}()
	if returnErr != nil {
		return returnErr
	}
	_, err := s.DB.Exec(ctx, `WITH due AS (UPDATE app.followups SET invited=true WHERE NOT invited AND available_at<=now() RETURNING id,student_id)
 INSERT INTO app.notifications(user_id,work,kind,title,target_type,target_id)
 SELECT student_id,false,'followup','可以填写服务回访了','followup',id FROM due`)
	if err != nil {
		return err
	}
	_, err = s.DB.Exec(ctx, `UPDATE app.chat_requests SET status='expired' WHERE status='pending' AND created_at<now()-interval '7 days'`)
	return err
}
