package harbor

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/oines/xlgw-mono/backend/migrations"
)

// XL_GW_TEST_DATABASE_URL identifies a PostgreSQL database whose account can
// CREATE DATABASE. Each test gets a separate database and normal migrations.
func businessTestDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("XL_GW_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set XL_GW_TEST_DATABASE_URL for PostgreSQL-backed HTTP tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	name := "harbor_it_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	quoted := pgx.Identifier{name}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quoted); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if _, err := admin.Exec(ctx, "DROP DATABASE "+quoted); err != nil {
			t.Error(err)
		}
	})
	cfg = cfg.Copy()
	cfg.ConnConfig.Database = name
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	return db
}

type businessClient struct {
	t     *testing.T
	url   string
	http  *http.Client
	token string
	ID    string
}

type response struct {
	status int
	body   []byte
	err    error
}

func (c businessClient) request(method, path string, values any) response {
	var data []byte
	if values != nil {
		data, _ = json.Marshal(values)
	}
	req, err := http.NewRequest(method, c.url+"/api/v1"+path, bytes.NewReader(data))
	if err != nil {
		return response{err: err}
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return response{err: err}
	}
	defer res.Body.Close()
	data, err = io.ReadAll(res.Body)
	return response{status: res.StatusCode, body: data, err: err}
}

func (c businessClient) call(method, path string, status int, payload any) Object {
	c.t.Helper()
	r := c.request(method, path, payload)
	return getResponse(c.t, r, status, method+" "+path)
}

func getResponse(t *testing.T, r response, expected int, operation string) Object {
	t.Helper()
	if r.err != nil || r.status != expected {
		t.Fatalf("%s: got HTTP %d (%s) %v, want %d", operation, r.status, r.body, r.err, expected)
	}
	var o Object
	if len(r.body) != 0 {
		if err := json.Unmarshal(r.body, &o); err != nil {
			t.Fatalf("%s: response is not an object: %s", operation, r.body)
		}
	}
	return o
}

func getStr(t *testing.T, o Object, key string) string {
	t.Helper()
	v, ok := o[key].(string)
	if !ok || v == "" {
		t.Fatalf("missing nonempty %s in %+v", key, o)
	}
	return v
}

func assertValue(t *testing.T, o Object, field string, value any) {
	t.Helper()
	if o[field] != value {
		t.Fatalf("%s = %#v; want %#v", field, o[field], value)
	}
}

func getItems(t *testing.T, o Object) []Object {
	t.Helper()
	raw, ok := o["items"].([]any)
	if !ok {
		t.Fatalf("missing items in %+v", o)
	}
	result := make([]Object, 0, len(raw))
	for _, item := range raw {
		row, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("expected object in %+v", raw)
		}
		result = append(result, row)
	}
	return result
}

func lookupItem(t *testing.T, items []Object, key, value string) Object {
	t.Helper()
	for _, item := range items {
		if item[key] == value {
			return item
		}
	}
	t.Fatalf("missing %s %q in %+v", key, value, items)
	return nil
}

const businessPassword = "only-for-postgres-tests-123"

func (c businessClient) authenticate(account, nickname string) businessClient {
	c.t.Helper()
	path := "/auth/login"
	payload := Object{"account": account, "password": businessPassword}
	if nickname != "" {
		path = "/auth/register"
		payload["nickname"] = nickname
	}
	o := c.call("POST", path, 200, payload)
	c.token = getStr(c.t, o, "token")
	u, ok := o["user"].(map[string]any)
	if !ok {
		c.t.Fatalf("missing user in response")
	}
	c.ID = getStr(c.t, u, "id")
	return c
}

func newBusinessTest(t *testing.T) (*Server, businessClient, businessClient) {
	t.Helper()
	server := &Server{DB: businessTestDB(t)}
	if err := server.Bootstrap(context.Background(), "school-admin", businessPassword); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	server.Register(mux)
	httpServer := httptest.NewServer(mux)
	t.Cleanup(httpServer.Close)
	public := businessClient{t: t, url: httpServer.URL, http: &http.Client{Timeout: 12 * time.Second}}
	return server, public, public.authenticate("school-admin", "")
}

func newWorker(t *testing.T, public, admin businessClient, account, role, supervisor string) businessClient {
	t.Helper()
	u := admin.call("POST", "/admin/users", 200, Object{"account": account, "password": businessPassword, "nickname": account, "roles": []string{role}})
	id := getStr(t, u, "id")
	admin.call("PUT", "/admin/staff/"+id, 200, Object{"role": role, "bio": "校内支持人员", "modes": []string{"online", "onsite"},
		"location": "校内咨询室", "supervisor_id": supervisor, "active": true})
	return public.authenticate(account, "")
}

func slot(t *testing.T, worker businessClient, when time.Time) string {
	t.Helper()
	rows := getItems(t, worker.call("POST", "/slots", 200, Object{"start_at": when, "mode": "online"}))
	if len(rows) != 1 {
		t.Fatalf("expected one slot: %+v", rows)
	}
	return getStr(t, rows[0], "id")
}

func TestReservationCareAndSupervisedFollowup(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	teacher := newWorker(t, public, admin, "teacher-chen", "teacher", "")
	peer := newWorker(t, public, admin, "peer-lin", "peer", teacher.ID)
	student := public.authenticate("student-yang", "杨同学")
	other := public.authenticate("student-zhou", "周同学")
	slotID := slot(t, peer, time.Now().UTC().Add(24*time.Hour).Truncate(time.Minute))

	// Two different students claim one slot at the same time. Only one can win.
	start := make(chan struct{})
	out := make(chan response, 2)
	for _, c := range []businessClient{student, other} {
		go func(c businessClient) {
			<-start
			out <- c.request("POST", "/appointments", Object{"id": uuid.NewString(), "slot_id": slotID, "note": "想聊学习安排"})
		}(c)
	}
	close(start)
	a, b := <-out, <-out
	if a.status == 409 {
		a, b = b, a
	}
	booked := getResponse(t, a, 200, "successful slot claimant")
	getResponse(t, b, 409, "duplicate slot claimant")
	assertValue(t, booked, "status", "pending")
	if booked["student_id"] == other.ID {
		student, other = other, student
	}
	appointment := getStr(t, booked, "id")
	path := "/appointments/" + appointment
	other.call("GET", path, 404, nil)
	student.call("POST", path+"/confirm", 403, Object{})
	confirmed := peer.call("POST", path+"/confirm", 200, Object{})
	assertValue(t, confirmed, "status", "confirmed")
	careConversation := getStr(t, confirmed, "conversation_id")
	service := getStr(t, confirmed, "service_id")
	msgPath := "/conversations/" + careConversation + "/messages"
	other.call("GET", msgPath, 404, nil)
	messageID := uuid.NewString()
	payload := Object{"id": messageID, "body": "你好，我想先聊最近的学习压力。"}
	assertValue(t, student.call("POST", msgPath, 200, payload), "id", messageID)
	assertValue(t, student.call("POST", msgPath, 200, payload), "id", messageID)
	peer.call("POST", msgPath, 200, Object{"body": "我们可以先聊你最担心的事。"})
	if seen := getItems(t, peer.call("GET", msgPath, 200, nil)); len(seen) != 2 {
		t.Fatalf("wrong conversation history: %+v", seen)
	}
	assertValue(t, peer.call("POST", path+"/start", 200, Object{}), "status", "in_progress")
	assertValue(t, peer.call("POST", path+"/complete", 200, Object{"internal_note": "内部记录，仅工作人员可见", "student_note": "可以填写回访"}), "status", "completed")
	ownerService := student.call("GET", "/services/"+service, 200, nil)
	assertValue(t, ownerService, "internal_note", nil)
	assertValue(t, ownerService, "student_note", "可以填写回访")
	follow := lookupItem(t, getItems(t, student.call("GET", "/followups", 200, nil)), "service_id", service)
	followID := getStr(t, follow, "id")
	followPath := "/followups/" + followID
	student.call("PUT", followPath+"/draft", 200, Object{"mood": "worse", "note": "草稿"})
	draft := peer.call("GET", followPath, 200, nil)
	if answers, ok := draft["answers"].(map[string]any); !ok || len(answers) != 0 {
		t.Fatalf("draft visible to peer: %+v", draft)
	}
	submitted := student.call("POST", followPath+"/submit", 200, Object{"mood": "worse", "helpfulness": "neutral", "contact_requested": true, "note": "希望老师联系"})
	assertValue(t, submitted, "status", "pending_contact")
	assertValue(t, submitted, "staff_id", teacher.ID)
	peer.call("GET", followPath, 404, nil)
	assertValue(t, teacher.call("POST", followPath+"/contact", 200, Object{"note": "联系记录", "student_note": "请查看消息"}), "status", "following")
	assertValue(t, teacher.call("POST", followPath+"/close", 200, Object{"note": "已跟进"}), "status", "closed")
}

func TestHelpAssignmentAndTransferMoveAccess(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	teacher := newWorker(t, public, admin, "teacher-wang", "teacher", "")
	next := newWorker(t, public, admin, "teacher-li", "teacher", "")
	student := public.authenticate("student-jin", "金同学")
	outsider := public.authenticate("student-wu", "吴同学")
	help := student.call("POST", "/help-requests", 200, Object{"contact": "可在校内联系", "body": "想请老师和我聊聊", "preferred_time": "周三下午"})
	assertValue(t, help, "status", "submitted")
	hp := "/help-requests/" + getStr(t, help, "id")
	outsider.call("GET", hp, 404, nil)
	assigned := admin.call("POST", hp+"/assign", 200, Object{"staff_id": teacher.ID})
	assertValue(t, assigned, "status", "assigned")
	msgPath := "/conversations/" + getStr(t, assigned, "conversation_id") + "/messages"
	service := getStr(t, assigned, "service_id")
	teacher.call("POST", msgPath, 200, Object{"body": "我收到了你的请求。"})
	pending := teacher.call("POST", "/transfers", 200, Object{"service_id": service, "staff_id": next.ID, "note": "请协助跟进"})
	assertValue(t, pending, "status", "pending")
	next.call("GET", msgPath, 404, nil)
	transfer := "/transfers/" + getStr(t, pending, "id")
	teacher.call("POST", transfer+"/accept", 404, Object{})
	assertValue(t, next.call("POST", transfer+"/accept", 200, Object{}), "status", "accepted")
	teacher.call("GET", msgPath, 404, nil)
	teacher.call("POST", msgPath, 404, Object{"body": "旧负责人不可再发"})
	if items := getItems(t, next.call("GET", msgPath, 200, nil)); len(items) != 1 {
		t.Fatalf("new assignee could not see former messages: %+v", items)
	}
	assertValue(t, next.call("POST", hp+"/contact", 200, Object{"note": "已联系学生", "student_note": "可以继续在这里交流"}), "status", "contacting")
	assertValue(t, next.call("POST", hp+"/close", 200, Object{"note": "已完成跟进", "student_note": "已结束"}), "status", "closed")
}

func TestCommunityModerationDMAndBlock(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	a := public.authenticate("student-he", "何同学")
	b := public.authenticate("student-ma", "马同学")
	outsider := public.authenticate("student-peng", "彭同学")
	post := a.call("POST", "/posts", 200, Object{"body": "我今天休息了一会", "tags": []string{"疲惫", "平静"}})
	p := "/posts/" + getStr(t, post, "id")
	b.call("PUT", p+"/resonance", 200, Object{"active": true})
	loved := b.call("PUT", p+"/resonance", 200, Object{"active": true})
	assertValue(t, loved, "resonances", float64(1))
	assertValue(t, loved, "resonated", true)
	comment := b.call("POST", p+"/comments", 200, Object{"body": "谢谢你的分享"})
	a.call("POST", p+"/comments", 200, Object{"body": "也谢谢你", "parent_id": getStr(t, comment, "id")})
	if n := len(getItems(t, a.call("GET", p+"/comments", 200, nil))); n != 2 {
		t.Fatalf("expected two comments, got %d", n)
	}

	req := a.call("POST", "/chat-requests", 200, Object{"recipient_id": b.ID, "note": "想私下交流"})
	request := "/chat-requests/" + getStr(t, req, "id")
	bc := b.call("POST", request+"/accept", 200, Object{})
	assertValue(t, bc, "status", "accepted")
	msg := "/conversations/" + getStr(t, bc, "conversation_id") + "/messages"
	sent := a.call("POST", msg, 200, Object{"body": "这是同学私聊的一条消息"})
	mid := getStr(t, sent, "id")
	outsider.call("GET", msg, 404, nil)
	outsider.call("POST", "/reports", 404, Object{"target_type": "message", "target_id": mid, "reason": "不当内容"})
	report := b.call("POST", "/reports", 200, Object{"target_type": "message", "target_id": mid, "reason": "不当内容"})
	rp := "/admin/reports/" + getStr(t, report, "id") + "/resolve"
	outsider.call("POST", rp, 403, Object{"action": "remove", "result": "无权处理"})
	admin.call("POST", rp, 200, Object{"action": "remove", "result": "已移除"})
	if n := len(getItems(t, b.call("GET", msg, 200, nil))); n != 0 {
		t.Fatalf("hidden message still visible: %d", n)
	}
	b.call("POST", "/blocks/"+a.ID, 204, nil)
	a.call("POST", msg, 409, Object{"body": "屏蔽后不可再发"})
	a.call("POST", "/chat-requests", 403, Object{"recipient_id": b.ID, "note": "屏蔽后不可申请"})
	if n := len(getItems(t, b.call("GET", "/blocks", 200, nil))); n != 1 {
		t.Fatalf("missing block: %d", n)
	}
}

func TestAvatarRevisionAndSessionRevocation(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	teacher := newWorker(t, public, admin, "teacher-meng", "teacher", "")
	student := public.authenticate("student-yan", "严同学")
	public.call("GET", "/me", 401, nil)
	initial := student.call("GET", "/avatars/me", 200, nil)
	assertValue(t, initial, "revision", float64(0))
	config := initial["config"].(map[string]any)
	config["preset"] = "soft"
	first := student.call("PUT", "/avatars/me", 200, Object{"revision": 0, "config": config})
	assertValue(t, first, "revision", float64(1))
	anotherDevice := public.authenticate("student-yan", "")
	assertValue(t, anotherDevice.call("GET", "/avatars/me", 200, nil), "revision", float64(1))
	config["outfit"] = 2
	second := anotherDevice.call("PUT", "/avatars/me", 200, Object{"revision": 1, "config": config})
	assertValue(t, second, "revision", float64(2))
	student.call("PUT", "/avatars/me", 409, Object{"revision": 1, "config": config})
	assertValue(t, student.call("GET", "/avatars/me", 200, nil)["config"].(map[string]any), "outfit", float64(2))

	// Authorization is re-evaluated from the current business roles.
	teacher.call("GET", "/appointments?scope=work", 200, nil)
	admin.call("PATCH", "/admin/users/"+teacher.ID, 200, Object{"roles": []string{"student"}})
	teacher.call("GET", "/appointments?scope=work", 403, nil)
	admin.call("PATCH", "/admin/users/"+teacher.ID, 200, Object{"active": false})
	teacher.call("GET", "/me", 401, nil)
	student.call("POST", "/auth/logout", 204, nil)
	student.call("GET", "/me", 401, nil)
	anotherDevice.call("GET", "/me", 200, nil)
}

func TestSharePermissionAndAppointmentExpiry(t *testing.T) {
	server, public, admin := newBusinessTest(t)
	s := public.authenticate("share-student", "分享学生")
	outsider := public.authenticate("other-student", "另一位学生")
	staff := newWorker(t, public, admin, "sharing-teacher", "teacher", "")
	replacement := newWorker(t, public, admin, "replacement-teacher", "teacher", "")
	when := time.Now().Add(48 * time.Hour).Truncate(time.Minute)
	sid := slot(t, staff, when)
	a := s.call("POST", "/appointments", 200, Object{"slot_id": sid})
	aid := getStr(t, a, "id")
	a = staff.call("POST", "/appointments/"+aid+"/confirm", 200, Object{})
	service := getStr(t, a, "service_id")
	var conv string
	// A student-authored draft needs an existing AI conversation, while sharing
	// selected model messages is covered with Astral in the AI HTTP suite.
	err := server.DB.QueryRow(context.Background(), `INSERT INTO app.ai_conversations(id,user_id,session_id,title)
 VALUES(gen_random_uuid(),$1,'test-share-session','会话') RETURNING id`, s.ID).Scan(&conv)
	if err != nil {
		t.Fatal(err)
	}
	share := s.call("POST", "/services/"+service+"/shares", 200, Object{"conversation_id": conv, "summary": "这是本人确认的摘要", "expected_staff_id": staff.ID})
	shareID := getStr(t, share, "id")
	if rows := getItems(t, staff.call("GET", "/services/"+service+"/shares", 200, nil)); len(rows) != 1 || rows[0]["body"] != "这是本人确认的摘要" {
		t.Fatalf("unexpected share list %+v", rows)
	}
	if rows := getItems(t, outsider.call("GET", "/services/"+service+"/shares", 200, nil)); len(rows) != 0 {
		t.Fatalf("outsider read share %+v", rows)
	}
	s.call("DELETE", "/shares/"+shareID, 204, nil)
	if rows := getItems(t, staff.call("GET", "/services/"+service+"/shares", 200, nil)); len(rows) != 0 {
		t.Fatal("revoked summary still readable")
	}
	s.call("POST", "/services/"+service+"/shares", 200, Object{"conversation_id": conv, "summary": "交接后需要新的授权", "expected_staff_id": staff.ID})
	admin.call("POST", "/appointments/"+aid+"/reassign", 200, Object{"staff_id": replacement.ID})
	staff.call("GET", "/services/"+service, 404, nil)
	if rows := getItems(t, replacement.call("GET", "/services/"+service+"/shares", 200, nil)); len(rows) != 0 {
		t.Fatal("previous approval leaked to replacement")
	}
	s.call("POST", "/services/"+service+"/shares", 409, Object{"conversation_id": conv, "summary": "交接前确认", "expected_staff_id": staff.ID})
	s.call("POST", "/services/"+service+"/shares", 200, Object{"conversation_id": conv, "summary": "学生重新授权", "expected_staff_id": replacement.ID})
	if _, err := server.DB.Exec(context.Background(), "DELETE FROM app.ai_conversations WHERE id=$1", conv); err != nil {
		t.Fatal(err)
	}
	if rows := getItems(t, replacement.call("GET", "/services/"+service+"/shares", 200, nil)); len(rows) != 0 {
		t.Fatal("deleted conversation still shared")
	}
	s.call("POST", "/appointments/"+aid+"/cancel", 200, Object{})
	outsider.call("POST", "/appointments", 200, Object{"slot_id": sid})
	second := slot(t, staff, when.Add(3*time.Hour))
	pending := outsider.call("POST", "/appointments", 200, Object{"slot_id": second})
	pid := getStr(t, pending, "id")
	if _, err := server.DB.Exec(context.Background(), "UPDATE app.appointments SET start_at=now()-interval '1 minute' WHERE id=$1", pid); err != nil {
		t.Fatal(err)
	}
	if err := server.ProcessDue(context.Background()); err != nil {
		t.Fatal(err)
	}
	assertValue(t, outsider.call("GET", "/appointments/"+pid, 200, nil), "status", "expired")
}

func TestSchoolInvitationAndAIConsent(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	admin.call("PATCH", "/admin/settings", 400, Object{"timezone": "Local"})
	admin.call("PATCH", "/admin/settings", 400, Object{"registration_mode": "invite"})
	settings := admin.call("PATCH", "/admin/settings", 200, Object{"registration_mode": "invite", "invite_code": "one-school-only", "timezone": "Asia/Shanghai"})
	assertValue(t, settings, "invite_configured", true)
	if _, ok := settings["invite_hash"]; ok {
		t.Fatal("settings exposed password hash")
	}
	opts := Object{"account": "invited-student", "nickname": "本校学生", "password": businessPassword}
	public.call("POST", "/auth/register", 403, opts)
	opts["invite_code"] = "one-school-only"
	logged := public.call("POST", "/auth/register", 200, opts)
	public.token = getStr(t, logged, "token")
	assertValue(t, public.call("GET", "/me/ai-consent", 200, nil), "agreed", false)
	public.call("POST", "/me/ai-consent", 400, Object{"agreed": false})
	assertValue(t, public.call("POST", "/me/ai-consent", 200, Object{"agreed": true}), "agreed", true)
	assertValue(t, public.call("GET", "/me/ai-consent", 200, nil), "agreed", true)
}
