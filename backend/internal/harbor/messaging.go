package harbor

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

const conversationSelect = `SELECT c.id,c.kind,o.id participant_id,o.nickname name,o.avatar_url,c.service_id,s.appointment_id,c.closed,p.role staff_role,
 (c.closed OR s.status='closed' OR coalesce(s.completed_at+interval '7 days'<=now(),false) OR (c.kind='peer' AND (NOT o.active OR EXISTS(SELECT 1 FROM app.blocks b WHERE (b.owner_id,b.target_id) IN ((m.user_id,o.id),(o.id,m.user_id)))))) read_only,
 (SELECT count(*) FROM app.messages msg WHERE msg.conversation_id=c.id AND msg.sender_id<>m.user_id AND msg.created_at>m.last_read AND NOT msg.hidden) unread,
 coalesce((SELECT msg.body FROM app.messages msg WHERE msg.conversation_id=c.id AND NOT msg.hidden ORDER BY msg.created_at DESC,msg.id DESC LIMIT 1),'') last_message,c.updated_at
 FROM app.conversation_members m JOIN app.conversations c ON c.id=m.conversation_id
 JOIN app.conversation_members other ON other.conversation_id=c.id AND other.user_id<>m.user_id
 JOIN app.users o ON o.id=other.user_id LEFT JOIN app.services s ON s.id=c.service_id LEFT JOIN app.staff p ON p.id=s.staff_id`
const conversationAccess = `m.user_id=$1 AND (c.kind='peer' OR s.student_id=$1 OR s.staff_id=$1 AND $2 AND EXISTS(SELECT 1 FROM app.staff p JOIN app.users u ON u.id=p.id WHERE p.id=$1 AND p.active AND u.active AND p.role=ANY(u.roles)))`

func (s *Server) conversations(r *http.Request) (any, error) {
	u := actor(r)
	work := r.URL.Query().Get("scope") == "work"
	n, o := page(r)
	if work && !u.Work() {
		return nil, forbidden()
	}
	return items(r.Context(), s.DB, conversationSelect+" WHERE "+conversationAccess+` AND (CASE WHEN $3 THEN c.kind='care' AND s.staff_id=$1 ELSE c.kind='peer' OR s.student_id=$1 END) ORDER BY c.updated_at DESC,c.id LIMIT $4 OFFSET $5`, u.ID, u.Work(), work, n, o)
}
func (s *Server) conversationDetail(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	u := actor(r)
	return object(r.Context(), s.DB, conversationSelect+" WHERE "+conversationAccess+" AND c.id=$3", u.ID, u.Work(), uid)
}

const messageSelect = `SELECT m.id,m.sender_id,u.nickname sender_name,m.body,m.created_at FROM app.messages m JOIN app.users u ON u.id=m.sender_id`

func (s *Server) messages(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	n, _ := page(r)
	var before *time.Time
	if raw := r.URL.Query().Get("before"); raw != "" {
		v, err := time.Parse(time.RFC3339Nano, raw)
		if err != nil {
			return nil, invalid("消息游标无效")
		}
		before = &v
	}
	u := actor(r)
	ctx := r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		if _, err := object(ctx, tx, conversationSelect+" WHERE "+conversationAccess+" AND c.id=$3 FOR SHARE OF m", u.ID, u.Work(), uid); err != nil {
			return nil, err
		}
		return items(ctx, tx, "SELECT * FROM ("+messageSelect+` WHERE m.conversation_id=$1 AND NOT m.hidden AND ($2::timestamptz IS NULL OR m.created_at<$2) ORDER BY m.created_at DESC,m.id DESC LIMIT $3) newest ORDER BY created_at,id`, uid, before, n)
	})
}
func (s *Server) sendMessage(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in struct{ ID, Body string }
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	mid, err := clientID(in.ID)
	if err != nil {
		return nil, err
	}
	body, err := field(in.Body, "消息", 1, 2000)
	if err != nil {
		return nil, err
	}
	u, ctx := actor(r), r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		v, err := object(ctx, tx, conversationSelect+" WHERE "+conversationAccess+" AND c.id=$3 FOR UPDATE OF c", u.ID, u.Work(), uid)
		if err != nil {
			return nil, err
		}
		existing, err := object(ctx, tx, messageSelect+" WHERE m.id=$1 AND m.conversation_id=$2 AND m.sender_id=$3", mid, uid, u.ID)
		if err == nil {
			return existing, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		if v["read_only"] == true {
			return nil, stale("此会话已结束或暂不可发送")
		}
		if _, err := tx.Exec(ctx, `INSERT INTO app.messages(id,conversation_id,sender_id,body) VALUES($1,$2,$3,$4)`, mid, uid, u.ID, body); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `UPDATE app.conversations SET updated_at=now() WHERE id=$1`, uid); err != nil {
			return nil, err
		}
		return object(ctx, tx, messageSelect+" WHERE m.id=$1", mid)
	})
}
func (s *Server) readConversation(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.conversation_members SET last_read=clock_timestamp() WHERE conversation_id=$1 AND user_id=$2`, uid, UserID(r))
	if err == nil && tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return nil, err
}
func (s *Server) closeConversation(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.conversations SET closed=true WHERE id=$1 AND kind='peer' AND EXISTS(SELECT 1 FROM app.conversation_members WHERE conversation_id=$1 AND user_id=$2)`, uid, UserID(r))
	if err == nil && tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return nil, err
}

const chatSelect = `SELECT r.id,r.sender_id,s.nickname sender_name,r.recipient_id,u.nickname recipient_name,r.note,r.status,r.conversation_id,r.created_at
 FROM app.chat_requests r JOIN app.users s ON s.id=r.sender_id JOIN app.users u ON u.id=r.recipient_id`

func (s *Server) chatRequests(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, chatSelect+" WHERE $1 IN (r.sender_id,r.recipient_id) ORDER BY r.created_at DESC LIMIT $2 OFFSET $3", UserID(r), n, o)
}
func chatAllowed(ctx context.Context, q queryer, src, dst string) error {
	var allowed bool
	if err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app.users WHERE id=$2 AND active AND 'student'=ANY(roles))
 AND NOT EXISTS(SELECT 1 FROM app.blocks WHERE (owner_id,target_id) IN (($1,$2),($2,$1)))`, src, dst).Scan(&allowed); err != nil {
		return err
	}
	if !allowed {
		return forbidden()
	}
	return nil
}
func (s *Server) createChatRequest(r *http.Request) (any, error) {
	u := actor(r)
	if !u.Has("student") {
		return nil, forbidden()
	}
	var in struct {
		RecipientID string `json:"recipient_id"`
		Note        string
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	dest, err := id(in.RecipientID)
	if err != nil || u.ID == dest {
		return nil, invalid("请选择另一位同学")
	}
	note, err := field(in.Note, "申请说明", 0, 100)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		if err := lockedUsers(ctx, tx, u.ID, dest); err != nil {
			return nil, err
		}
		if err := chatAllowed(ctx, tx, u.ID, dest); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `UPDATE app.chat_requests SET status='expired' WHERE status='pending' AND created_at<now()-interval '7 days' AND (sender_id,recipient_id) IN (($1,$2),($2,$1))`, u.ID, dest); err != nil {
			return nil, err
		}
		var closed bool
		err := tx.QueryRow(ctx, `SELECT r.status='rejected' OR coalesce(NOT c.closed,false) OR r.status='pending' FROM app.chat_requests r LEFT JOIN app.conversations c ON c.id=r.conversation_id
   WHERE (r.sender_id,r.recipient_id) IN (($1,$2),($2,$1)) AND (r.status IN ('pending','accepted') OR r.status='rejected' AND r.created_at>now()-interval '7 days') ORDER BY r.created_at DESC LIMIT 1`, u.ID, dest).Scan(&closed)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		if closed {
			return nil, stale("已有会话或交流申请，请在消息中查看")
		}
		var rid string
		if err = tx.QueryRow(ctx, `INSERT INTO app.chat_requests(sender_id,recipient_id,note) VALUES($1,$2,$3) RETURNING id`, u.ID, dest, note).Scan(&rid); err != nil {
			return nil, err
		}
		if err := notice(ctx, tx, dest, false, "chat_request", "收到了同学的交流申请", "", "chat_request", rid); err != nil {
			return nil, err
		}
		return object(ctx, tx, chatSelect+" WHERE r.id=$1", rid)
	})
}
func (s *Server) chatAction(r *http.Request) (any, error) {
	rid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	action := r.PathValue("action")
	if !oneOf(action, "accept", "reject") {
		return nil, missing()
	}
	u, ctx := actor(r), r.Context()
	if !u.Has("student") {
		return nil, forbidden()
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var sender, receiver, status string
		var valid bool
		if err := tx.QueryRow(ctx, `SELECT sender_id,recipient_id FROM app.chat_requests WHERE id=$1`, rid).Scan(&sender, &receiver); err != nil {
			return nil, err
		}
		if receiver != u.ID {
			return nil, missing()
		}
		if err := lockedUsers(ctx, tx, sender, receiver); err != nil {
			return nil, err
		}
		if err := tx.QueryRow(ctx, `SELECT status,created_at>=now()-interval '7 days' FROM app.chat_requests WHERE id=$1 FOR UPDATE`, rid).Scan(&status, &valid); err != nil {
			return nil, err
		}
		if status != "pending" || !valid {
			return nil, stale("这条申请已处理或已过期")
		}
		var conversation *string
		next := "rejected"
		if action == "accept" {
			if err := chatAllowed(ctx, tx, receiver, sender); err != nil {
				return nil, err
			}
			var cid string
			if err := tx.QueryRow(ctx, `INSERT INTO app.conversations(kind) VALUES('peer') RETURNING id`).Scan(&cid); err != nil {
				return nil, err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO app.conversation_members(conversation_id,user_id) VALUES($1,$2),($1,$3)`, cid, sender, receiver); err != nil {
				return nil, err
			}
			conversation = &cid
			next = "accepted"
		}
		if _, err := tx.Exec(ctx, `UPDATE app.chat_requests SET status=$2,conversation_id=$3 WHERE id=$1`, rid, next, conversation); err != nil {
			return nil, err
		}
		if err := notice(ctx, tx, sender, false, "chat_request", "你的交流申请有新进展", "", "chat_request", rid); err != nil {
			return nil, err
		}
		return object(ctx, tx, chatSelect+" WHERE r.id=$1", rid)
	})
}
func (s *Server) notifications(r *http.Request) (any, error) {
	n, o := page(r)
	work := r.URL.Query().Get("scope") == "work"
	return items(r.Context(), s.DB, `SELECT id,kind,title,body,target_type,target_id,read,created_at FROM app.notifications WHERE user_id=$1 AND work=$2 ORDER BY created_at DESC LIMIT $3 OFFSET $4`, UserID(r), work, n, o)
}
func (s *Server) readNotice(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.notifications SET read=true WHERE id=$1 AND user_id=$2`, uid, UserID(r))
	if err == nil && tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return nil, err
}
func (s *Server) readAllNotices(r *http.Request) (any, error) {
	var in struct{ Scope string }
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	_, err := s.DB.Exec(r.Context(), `UPDATE app.notifications SET read=true WHERE user_id=$1 AND work=$2 AND NOT read`, UserID(r), in.Scope == "work")
	return nil, err
}
