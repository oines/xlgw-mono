package harbor

import (
	"net/http"
	"slices"

	"github.com/jackc/pgx/v5"
)

const postSelect = `SELECT p.id,p.author_id,u.nickname author_name,u.avatar_url author_avatar,p.body,p.tags,
 (SELECT count(*) FROM app.resonances a WHERE a.post_id=p.id) resonances,
 (SELECT count(*) FROM app.comments c WHERE c.post_id=p.id AND NOT c.hidden) comments,
 EXISTS(SELECT 1 FROM app.resonances r WHERE r.post_id=p.id AND r.user_id=$1) resonated,
 p.created_at,p.updated_at,p.updated_at>p.created_at edited
 FROM app.posts p JOIN app.users u ON u.id=p.author_id`
const postVisible = `NOT p.hidden AND u.active AND NOT EXISTS(SELECT 1 FROM app.blocks b WHERE b.owner_id=$1 AND b.target_id=p.author_id)`

func (s *Server) posts(r *http.Request) (any, error) {
	q := r.URL.Query()
	owner, err := optionalID(q.Get("author_id"))
	if err != nil {
		return nil, err
	}
	n, o := page(r)
	sort := "created_at DESC,id"
	switch q.Get("sort") {
	case "hot":
		sort = "(resonances+comments*2) DESC,created_at DESC,id"
	case "resonance":
		sort = "resonances DESC,created_at DESC,id"
	}
	return items(r.Context(), s.DB, "SELECT * FROM ("+postSelect+" WHERE "+postVisible+` AND ($2::uuid IS NULL OR p.author_id=$2)) visible ORDER BY `+sort+" LIMIT $3 OFFSET $4", UserID(r), owner, n, o)
}
func (s *Server) postDetail(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	return object(r.Context(), s.DB, postSelect+" WHERE p.id=$2 AND "+postVisible, UserID(r), uid)
}

type postInput struct {
	Body string
	Tags []string
}

func readPost(r *http.Request) (postInput, error) {
	var in postInput
	if err := decode(r, &in); err != nil {
		return in, err
	}
	var err error
	if in.Body, err = field(in.Body, "正文", 1, 2000); err != nil {
		return in, err
	}
	if len(in.Tags) < 1 || len(in.Tags) > 3 {
		return in, invalid("请选择 1–3 个情绪标签")
	}
	for i, v := range in.Tags {
		if !slices.Contains(moods, v) || slices.Contains(in.Tags[:i], v) {
			return in, invalid("情绪标签无效")
		}
	}
	return in, nil
}
func (s *Server) createPost(r *http.Request) (any, error) {
	if !actor(r).Has("student") {
		return nil, forbidden()
	}
	in, err := readPost(r)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	var uid string
	if err = s.DB.QueryRow(ctx, `INSERT INTO app.posts(author_id,body,tags) VALUES($1,$2,$3) RETURNING id`, UserID(r), in.Body, in.Tags).Scan(&uid); err != nil {
		return nil, err
	}
	return object(ctx, s.DB, postSelect+" WHERE p.id=$2", UserID(r), uid)
}
func (s *Server) editPost(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	in, err := readPost(r)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.posts SET body=$3,tags=$4,updated_at=now() WHERE id=$1 AND author_id=$2 AND NOT hidden`, uid, UserID(r), in.Body, in.Tags)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return s.postDetail(r)
}
func (s *Server) deletePost(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.posts SET hidden=true WHERE id=$1 AND author_id=$2`, uid, UserID(r))
	if err == nil && tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return nil, err
}

const commentSelect = `SELECT c.id,c.post_id,c.parent_id,c.author_id,u.nickname author_name,u.avatar_url author_avatar,c.body,c.created_at
 FROM app.comments c JOIN app.users u ON u.id=c.author_id`

func (s *Server) comments(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	if _, err := s.postDetail(r); err != nil {
		return nil, err
	}
	n, o := page(r)
	return items(r.Context(), s.DB, commentSelect+` WHERE c.post_id=$1 AND NOT c.hidden AND u.active AND NOT EXISTS(SELECT 1 FROM app.blocks b WHERE b.owner_id=$2 AND b.target_id=c.author_id) ORDER BY c.created_at,c.id LIMIT $3 OFFSET $4`, uid, UserID(r), n, o)
}
func (s *Server) myComments(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, commentSelect+" WHERE c.author_id=$1 AND NOT c.hidden ORDER BY c.created_at DESC LIMIT $2 OFFSET $3", UserID(r), n, o)
}
func (s *Server) createComment(r *http.Request) (any, error) {
	if !actor(r).Has("student") {
		return nil, forbidden()
	}
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in struct {
		Body     string
		ParentID string `json:"parent_id"`
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	body, err := field(in.Body, "评论", 1, 500)
	if err != nil {
		return nil, err
	}
	parent, err := optionalID(in.ParentID)
	if err != nil {
		return nil, err
	}
	ctx, author := r.Context(), UserID(r)
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var owner, recipient string
		if err := tx.QueryRow(ctx, `SELECT p.author_id FROM app.posts p JOIN app.users u ON u.id=p.author_id WHERE p.id=$2 AND `+postVisible+" FOR SHARE OF p", author, uid).Scan(&owner); err != nil {
			return nil, err
		}
		recipient = owner
		if parent != nil {
			if err := tx.QueryRow(ctx, `SELECT c.author_id,coalesce(c.parent_id,c.id) FROM app.comments c WHERE c.id=$1 AND c.post_id=$2 AND NOT c.hidden`, parent, uid).Scan(&recipient, &parent); err != nil {
				return nil, err
			}
		}
		var cid string
		if err := tx.QueryRow(ctx, `INSERT INTO app.comments(post_id,parent_id,author_id,body) VALUES($1,$2,$3,$4) RETURNING id`, uid, parent, author, body).Scan(&cid); err != nil {
			return nil, err
		}
		if recipient != author {
			if err := notice(ctx, tx, recipient, false, "comment", "有同学回复了你", "", "post", uid); err != nil {
				return nil, err
			}
		}
		return object(ctx, tx, commentSelect+" WHERE c.id=$1", cid)
	})
}
func (s *Server) deleteComment(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	tag, err := s.DB.Exec(r.Context(), `UPDATE app.comments SET hidden=true WHERE id=$1 AND author_id=$2`, uid, UserID(r))
	if err == nil && tag.RowsAffected() == 0 {
		return nil, missing()
	}
	return nil, err
}
func (s *Server) resonance(r *http.Request) (any, error) {
	if !actor(r).Has("student") {
		return nil, forbidden()
	}
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in struct{ Active bool }
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	ctx, author := r.Context(), UserID(r)
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var owner string
		if err := tx.QueryRow(ctx, `SELECT p.author_id FROM app.posts p JOIN app.users u ON u.id=p.author_id WHERE p.id=$2 AND `+postVisible+" FOR SHARE OF p", author, uid).Scan(&owner); err != nil {
			return nil, err
		}
		if in.Active {
			tag, err := tx.Exec(ctx, `INSERT INTO app.resonances(post_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, uid, author)
			if err != nil {
				return nil, err
			}
			if tag.RowsAffected() > 0 && owner != author {
				if err := notice(ctx, tx, owner, false, "resonance", "有同学与你产生了共鸣", "", "post", uid); err != nil {
					return nil, err
				}
			}
		} else {
			if _, err := tx.Exec(ctx, `DELETE FROM app.resonances WHERE post_id=$1 AND user_id=$2`, uid, author); err != nil {
				return nil, err
			}
		}
		return object(ctx, tx, postSelect+" WHERE p.id=$2", author, uid)
	})
}
func (s *Server) person(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	return object(r.Context(), s.DB, `SELECT id,nickname,avatar_url,EXISTS(SELECT 1 FROM app.blocks WHERE owner_id=$1 AND target_id=$2) blocked FROM app.users WHERE id=$2 AND active`, UserID(r), uid)
}
func (s *Server) blocks(r *http.Request) (any, error) {
	return items(r.Context(), s.DB, `SELECT u.id,u.nickname,b.created_at FROM app.blocks b JOIN app.users u ON u.id=b.target_id WHERE b.owner_id=$1 ORDER BY b.created_at DESC`, UserID(r))
}
func (s *Server) block(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	if uid == UserID(r) {
		return nil, invalid("不能屏蔽自己")
	}
	ctx := r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		if err := lockedUsers(ctx, tx, UserID(r), uid); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO app.blocks(owner_id,target_id) VALUES($1,$2) ON CONFLICT DO NOTHING`, UserID(r), uid); err != nil {
			return nil, err
		}
		_, err := tx.Exec(ctx, `UPDATE app.chat_requests SET status='rejected' WHERE (sender_id,recipient_id) IN (($1,$2),($2,$1)) AND status='pending'`, UserID(r), uid)
		return nil, err
	})
}
func (s *Server) unblock(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	_, err = s.DB.Exec(r.Context(), `DELETE FROM app.blocks WHERE owner_id=$1 AND target_id=$2`, UserID(r), uid)
	return nil, err
}

const reportSelect = `SELECT r.id,r.target_type,r.target_id,r.reporter_id,u.nickname reporter_name,r.author_id,a.nickname author_name,r.reason,r.note,r.evidence,r.status,r.result,r.created_at FROM app.reports r JOIN app.users u ON u.id=r.reporter_id JOIN app.users a ON a.id=r.author_id`

func (s *Server) report(r *http.Request) (any, error) {
	var in struct {
		TargetType   string `json:"target_type"`
		TargetID     string `json:"target_id"`
		Reason, Note string
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	uid, err := id(in.TargetID)
	if err != nil {
		return nil, err
	}
	reason, err := field(in.Reason, "举报原因", 1, 80)
	if err != nil {
		return nil, err
	}
	note, err := field(in.Note, "举报说明", 0, 500)
	if err != nil {
		return nil, err
	}
	ctx, reporter := r.Context(), UserID(r)
	var sql string
	switch in.TargetType {
	case "post":
		sql = `SELECT p.author_id,p.body FROM app.posts p JOIN app.users u ON u.id=p.author_id WHERE p.id=$2 AND ` + postVisible
	case "comment":
		sql = `SELECT c.author_id,c.body FROM app.comments c JOIN app.posts p ON p.id=c.post_id JOIN app.users u ON u.id=p.author_id WHERE c.id=$2 AND NOT c.hidden AND ` + postVisible
	case "message":
		sql = `SELECT m.sender_id,m.body FROM app.messages m JOIN app.conversations c ON c.id=m.conversation_id WHERE m.id=$2 AND c.kind='peer' AND NOT m.hidden AND EXISTS(SELECT 1 FROM app.conversation_members a WHERE a.conversation_id=c.id AND a.user_id=$1)`
	default:
		return nil, invalid("举报对象无效")
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var owner, evidence string
		if err := tx.QueryRow(ctx, sql, reporter, uid).Scan(&owner, &evidence); err != nil {
			return nil, err
		}
		if owner == reporter {
			return nil, invalid("不能举报自己的内容")
		}
		var rid string
		if err := tx.QueryRow(ctx, `INSERT INTO app.reports(reporter_id,author_id,target_type,target_id,reason,note,evidence) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id`, reporter, owner, in.TargetType, uid, reason, note, evidence).Scan(&rid); err != nil {
			return nil, err
		}
		return Object{"id": rid, "status": "pending"}, nil
	})
}
func (s *Server) adminReports(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, reportSelect+" WHERE ($1='' OR r.status=$1) ORDER BY r.created_at DESC LIMIT $2 OFFSET $3", r.URL.Query().Get("status"), n, o)
}
func (s *Server) resolveReport(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in struct{ Action, Result string }
	if err = decode(r, &in); err != nil {
		return nil, err
	}
	if !oneOf(in.Action, "dismiss", "remove", "restrict") {
		return nil, invalid("请选择有效处理方式")
	}
	explanation, err := field(in.Result, "处理结果", 1, 500)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var target, kind, owner, reporter, status string
		if err := tx.QueryRow(ctx, `SELECT target_id,target_type,author_id,reporter_id,status FROM app.reports WHERE id=$1 FOR UPDATE`, uid).Scan(&target, &kind, &owner, &reporter, &status); err != nil {
			return nil, err
		}
		if status != "pending" {
			return nil, stale("已处理，请刷新列表")
		}
		if in.Action == "remove" {
			table := map[string]string{"post": "posts", "comment": "comments", "message": "messages"}[kind]
			if table == "" {
				return nil, invalid("举报对象无效")
			}
			if _, err := tx.Exec(ctx, "UPDATE app."+table+" SET hidden=true WHERE id=$1", target); err != nil {
				return nil, err
			}
		}
		if in.Action == "restrict" {
			if owner == UserID(r) {
				return nil, invalid("不能限制当前管理员账号")
			}
			tag, err := tx.Exec(ctx, `UPDATE app.users SET active=false WHERE id=$1 AND NOT ('admin'=ANY(roles))`, owner)
			if err != nil {
				return nil, err
			}
			if tag.RowsAffected() == 0 {
				return nil, invalid("请从成员页面处理此账号")
			}
			if _, err := tx.Exec(ctx, `DELETE FROM app.auth_sessions WHERE user_id=$1`, owner); err != nil {
				return nil, err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE app.reports SET status=$2,result=$3 WHERE id=$1`, uid, map[string]string{"dismiss": "dismissed", "remove": "removed", "restrict": "restricted"}[in.Action], explanation); err != nil {
			return nil, err
		}
		if err := record(ctx, tx, "operation", uid, UserID(r), "report_"+in.Action, "", ""); err != nil {
			return nil, err
		}
		if err := notice(ctx, tx, reporter, false, "report", "你的举报已处理", explanation, "report", uid); err != nil {
			return nil, err
		}
		return object(ctx, tx, reportSelect+" WHERE r.id=$1", uid)
	})
}
