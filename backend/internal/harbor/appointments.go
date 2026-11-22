package harbor

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const staffSelect = `SELECT p.id,u.nickname,u.avatar_url,p.role,p.bio,p.modes,p.location,p.supervisor_id,su.nickname supervisor_name,p.active AND u.active AND p.role=ANY(u.roles) AS active,
 (SELECT min(s.start_at) FROM app.slots s WHERE s.staff_id=p.id AND s.start_at>now() AND NOT s.canceled AND NOT EXISTS(SELECT 1 FROM app.appointments a WHERE a.slot_id=s.id AND a.status IN ('pending','confirmed','in_progress','completed','no_show'))) next_slot
 FROM app.staff p JOIN app.users u ON u.id=p.id LEFT JOIN app.users su ON su.id=p.supervisor_id`
const staffActive = "p.active AND u.active AND p.role=ANY(u.roles)"

func (s *Server) staffList(r *http.Request) (any, error) {
	q := r.URL.Query()
	n, o := page(r)
	date := q.Get("date")
	if date != "" {
		if _, e := time.Parse("2006-01-02", date); e != nil {
			return nil, invalid("日期无效")
		}
	}
	return items(r.Context(), s.DB, staffSelect+" WHERE "+staffActive+` AND ($1='' OR p.role=$1) AND ($2='' OR $2=ANY(p.modes))
 AND ($3='' OR EXISTS(SELECT 1 FROM app.slots sl WHERE sl.staff_id=p.id AND sl.start_at>now() AND NOT sl.canceled AND (sl.start_at AT TIME ZONE (SELECT timezone FROM app.settings))::date=NULLIF($3,'')::date AND ($2='' OR sl.mode=$2) AND NOT EXISTS(SELECT 1 FROM app.appointments a WHERE a.slot_id=sl.id AND a.status IN ('pending','confirmed','in_progress','completed','no_show'))))
 ORDER BY next_slot NULLS LAST,u.nickname LIMIT $4 OFFSET $5`, q.Get("role"), q.Get("mode"), date, n, o)
}
func (s *Server) staffDetail(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	return object(r.Context(), s.DB, staffSelect+" WHERE p.id=$1 AND ("+staffActive+" OR $2 OR p.id=$3)", uid, actor(r).Has("admin"), UserID(r))
}
func (s *Server) myStaff(r *http.Request) (any, error) {
	return object(r.Context(), s.DB, staffSelect+" WHERE p.id=$1", UserID(r))
}

type staffInput struct {
	Role, Bio, Location string
	Modes               []string
	SupervisorID        string `json:"supervisor_id"`
	Active              *bool
}

func validateStaff(in staffInput) error {
	if len(in.Modes) < 1 || len(in.Modes) > 2 {
		return invalid("至少选择一种服务方式")
	}
	for i, v := range in.Modes {
		if !oneOf(v, "online", "onsite") || slices.Contains(in.Modes[:i], v) {
			return invalid("服务方式无效")
		}
	}
	if _, err := field(in.Bio, "介绍", 0, 1000); err != nil {
		return err
	}
	if _, err := field(in.Location, "服务地点", 0, 120); err != nil {
		return err
	}
	return nil
}
func (s *Server) editStaff(r *http.Request) (any, error) {
	if !actor(r).Work() {
		return nil, forbidden()
	}
	var in staffInput
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if err := validateStaff(in); err != nil {
		return nil, err
	}
	if _, err := s.DB.Exec(r.Context(), `UPDATE app.staff SET bio=$2,modes=$3,location=$4 WHERE id=$1`, UserID(r), in.Bio, in.Modes, in.Location); err != nil {
		return nil, err
	}
	return s.myStaff(r)
}
func (s *Server) adminStaff(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	var in staffInput
	if err = decode(r, &in); err != nil {
		return nil, err
	}
	if err = validateStaff(in); err != nil {
		return nil, err
	}
	if !oneOf(in.Role, "teacher", "peer") {
		return nil, invalid("请选择老师或朋辈")
	}
	active := in.Active == nil || *in.Active
	ctx := r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		u, err := getUser(ctx, tx, "WHERE u.id=$1 FOR UPDATE OF u", uid)
		if err != nil {
			return nil, err
		}
		if !u.Has(in.Role) {
			return nil, invalid("请先授予相应工作身份")
		}
		var supervisor any
		if in.Role == "peer" {
			v, err := id(in.SupervisorID)
			if err != nil || v == uid {
				return nil, invalid("请选择指导老师")
			}
			if err = eligibleStaff(ctx, tx, v, "teacher"); err != nil {
				return nil, err
			}
			supervisor = v
		}
		if _, err := tx.Exec(ctx, `INSERT INTO app.staff(id,role,bio,modes,location,supervisor_id,active)
   VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(id) DO UPDATE SET role=excluded.role,bio=excluded.bio,modes=excluded.modes,location=excluded.location,supervisor_id=excluded.supervisor_id,active=excluded.active`, uid, in.Role, in.Bio, in.Modes, in.Location, supervisor, active); err != nil {
			return nil, err
		}
		if err := record(ctx, tx, "operation", uid, UserID(r), "update_staff", "", ""); err != nil {
			return nil, err
		}
		return object(ctx, tx, staffSelect+" WHERE p.id=$1", uid)
	})
}
func eligibleStaff(ctx context.Context, q queryer, uid, role string) error {
	var eligible bool
	err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app.staff p JOIN app.users u ON u.id=p.id WHERE p.id=$1
 AND p.active AND u.active AND p.role=ANY(u.roles) AND ($2='' OR p.role=$2))`, uid, role).Scan(&eligible)
	if err != nil {
		return err
	}
	if !eligible {
		return invalid("请选择已启用的服务人员")
	}
	return nil
}
func (s *Server) dates(r *http.Request) (string, string, error) {
	from, to := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	var location *time.Location
	for _, value := range []*string{&from, &to} {
		if *value == "" {
			continue
		}
		if _, err := time.Parse(time.RFC3339, *value); err == nil {
			continue
		}
		if location == nil {
			var zone string
			if err := s.DB.QueryRow(r.Context(), "SELECT timezone FROM app.settings").Scan(&zone); err != nil {
				return "", "", err
			}
			var err error
			location, err = time.LoadLocation(zone)
			if err != nil {
				return "", "", err
			}
		}
		date, err := time.ParseInLocation("2006-01-02", *value, location)
		if err != nil {
			return "", "", invalid("日期无效")
		}
		*value = date.Format(time.RFC3339)
	}

	return from, to, nil
}

const slotSelect = `SELECT sl.id,sl.staff_id,u.nickname staff_name,p.role,sl.start_at,sl.end_at,sl.mode,
 NOT sl.canceled AND sl.start_at>now() AND a.id IS NULL AND occupied.id IS NULL available,coalesce(a.id,occupied.id) appointment_id
 FROM app.slots sl JOIN app.staff p ON p.id=sl.staff_id JOIN app.users u ON u.id=p.id
 LEFT JOIN app.appointments a ON a.slot_id=sl.id AND a.status IN ('pending','confirmed','in_progress','completed','no_show')
 LEFT JOIN LATERAL(SELECT b.id FROM app.appointments b WHERE b.staff_id=sl.staff_id
 AND b.status IN ('pending','confirmed','in_progress') AND b.start_at<sl.end_at AND b.end_at>sl.start_at
 ORDER BY b.start_at LIMIT 1) occupied ON true`

func (s *Server) slots(r *http.Request) (any, error) {
	from, to, err := s.dates(r)
	if err != nil {
		return nil, err
	}
	staff, err := optionalID(r.URL.Query().Get("staff_id"))
	if err != nil {
		return nil, err
	}
	work := r.URL.Query().Get("scope") == "work"
	if work && !actor(r).Has("admin") {
		if !actor(r).Work() {
			return nil, forbidden()
		}
		staff = UserID(r)
	}
	n, o := page(r)
	return items(r.Context(), s.DB, slotSelect+` WHERE NOT sl.canceled AND ($1::uuid IS NULL OR sl.staff_id=$1)
 AND (NULLIF($2,'') IS NULL OR sl.start_at>=NULLIF($2,'')::timestamptz) AND (NULLIF($3,'') IS NULL OR sl.start_at<NULLIF($3,'')::timestamptz)
 AND ($4 OR (`+staffActive+` AND sl.start_at>now() AND a.id IS NULL AND occupied.id IS NULL))
 ORDER BY sl.start_at LIMIT $5 OFFSET $6`, staff, from, to, work, n, o)
}

type slotInput struct {
	StartAt time.Time `json:"start_at"`
	EndAt   time.Time `json:"end_at"`
	Mode    string
}

func (s *Server) addSlots(r *http.Request) (any, error) {
	if !actor(r).Work() {
		return nil, forbidden()
	}
	var in struct {
		slotInput
		Items []slotInput
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if len(in.Items) == 0 {
		in.Items = []slotInput{in.slotInput}
	}
	if len(in.Items) > 40 {
		return nil, invalid("一次最多发布 40 个时段")
	}
	ctx, uid := r.Context(), UserID(r)
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		if err := lockedUsers(ctx, tx, uid); err != nil {
			return nil, err
		}
		if err := eligibleStaff(ctx, tx, uid, ""); err != nil {
			return nil, err
		}
		var minutes, gap int
		var modes []string
		if err := tx.QueryRow(ctx, `SELECT CASE p.role WHEN 'teacher' THEN t.teacher_minutes ELSE t.peer_minutes END,t.slot_gap_minutes,p.modes FROM app.staff p CROSS JOIN app.settings t WHERE p.id=$1`, uid).Scan(&minutes, &gap, &modes); err != nil {
			return nil, err
		}
		result := []Object{}
		for _, v := range in.Items {
			if !slices.Contains(modes, v.Mode) {
				return nil, invalid("请从当前支持的服务方式中选择")
			}
			now := time.Now()
			end := v.StartAt.Add(time.Duration(minutes) * time.Minute)
			if !v.StartAt.After(now) || v.StartAt.After(now.AddDate(0, 0, 14)) || !v.EndAt.IsZero() && !v.EndAt.Equal(end) {
				return nil, invalid("请选择未来十四天的时间和标准服务时长")
			}
			var overlap bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app.slots WHERE staff_id=$1 AND NOT canceled AND start_at<$3::timestamptz+$4::int*interval '1 minute' AND end_at>$2::timestamptz-$4::int*interval '1 minute')
      OR EXISTS(SELECT 1 FROM app.appointments WHERE staff_id=$1 AND status IN ('pending','confirmed','in_progress') AND start_at<$3::timestamptz+$4::int*interval '1 minute' AND end_at>$2::timestamptz-$4::int*interval '1 minute')`, uid, v.StartAt, end, gap).Scan(&overlap); err != nil {
				return nil, err
			}
			if overlap {
				return nil, stale("此时段与现有排班重叠，或间隔不足")
			}
			var sid string
			if err := tx.QueryRow(ctx, `INSERT INTO app.slots(staff_id,start_at,end_at,mode) VALUES($1,$2,$3,$4) RETURNING id`, uid, v.StartAt, end, v.Mode).Scan(&sid); err != nil {
				return nil, err
			}
			row, err := object(ctx, tx, slotSelect+" WHERE sl.id=$1", sid)
			if err != nil {
				return nil, err
			}
			result = append(result, row)
		}
		return Object{"items": result}, nil
	})
}
func (s *Server) deleteSlot(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var owner string
		if err := tx.QueryRow(ctx, `SELECT staff_id FROM app.slots WHERE id=$1`, uid).Scan(&owner); err != nil {
			return nil, err
		}
		if owner != UserID(r) && !actor(r).Has("admin") {
			return nil, forbidden()
		}
		if err := lockedUsers(ctx, tx, owner); err != nil {
			return nil, err
		}
		if !actor(r).Has("admin") {
			if err := eligibleStaff(ctx, tx, owner, ""); err != nil {
				return nil, forbidden()
			}
		}
		tag, err := tx.Exec(ctx, `UPDATE app.slots SET canceled=true WHERE id=$1 AND NOT EXISTS(SELECT 1 FROM app.appointments a WHERE (a.slot_id=$1 AND a.status IN ('pending','confirmed','in_progress','completed','no_show'))
 OR (a.staff_id=app.slots.staff_id AND a.status IN ('pending','confirmed','in_progress') AND a.start_at<app.slots.end_at AND a.end_at>app.slots.start_at))`, uid)
		if err != nil {
			return nil, err
		}
		if tag.RowsAffected() == 0 {
			return nil, stale("此时段已有预约")
		}
		return nil, nil
	})
}

const appointmentSelect = `SELECT a.id,a.slot_id,a.student_id,st.nickname student_name,a.staff_id,u.nickname staff_name,p.role,a.start_at,a.end_at,a.mode,a.location,a.note,a.status,a.reason,a.created_at,a.updated_at,
 sv.id service_id,c.id conversation_id,NOT (p.active AND u.active AND p.role=ANY(u.roles)) needs_assignment,
 coalesce((SELECT jsonb_agg(jsonb_build_object('action',h.action,'note',h.note,'created_at',h.created_at) ORDER BY h.id) FROM app.history h WHERE h.kind='appointment' AND h.object_id=a.id),'[]'::jsonb) history
 FROM app.appointments a JOIN app.users st ON st.id=a.student_id JOIN app.users u ON u.id=a.staff_id JOIN app.staff p ON p.id=a.staff_id
 LEFT JOIN app.services sv ON sv.appointment_id=a.id LEFT JOIN app.conversations c ON c.service_id=sv.id`

func (s *Server) appointments(r *http.Request) (any, error) {
	u := actor(r)
	q := r.URL.Query()
	n, o := page(r)
	work := q.Get("scope") == "work"
	if work && !u.Work() && !u.Has("admin") {
		return nil, forbidden()
	}
	filter, err := optionalID(q.Get("staff_id"))
	if err != nil {
		return nil, err
	}
	from, to, err := s.dates(r)
	if err != nil {
		return nil, err
	}
	return items(r.Context(), s.DB, appointmentSelect+` WHERE (CASE WHEN $2 THEN a.staff_id=$1 AND p.active AND u.active AND p.role=ANY(u.roles) OR $3 ELSE a.student_id=$1 END)
 AND ($4::uuid IS NULL OR a.staff_id=$4) AND ($5='' OR a.status=$5)
 AND (NULLIF($6,'') IS NULL OR a.start_at>=NULLIF($6,'')::timestamptz) AND (NULLIF($7,'') IS NULL OR a.start_at<NULLIF($7,'')::timestamptz)
 ORDER BY a.start_at DESC,a.created_at DESC LIMIT $8 OFFSET $9`, u.ID, work, u.Has("admin"), filter, q.Get("status"), from, to, n, o)
}
func (s *Server) appointmentDetail(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	return object(r.Context(), s.DB, appointmentSelect+` WHERE a.id=$1 AND (a.student_id=$2 OR a.staff_id=$2 AND $3 AND p.active AND u.active AND p.role=ANY(u.roles) OR $4)`, uid, UserID(r), actor(r).Work(), actor(r).Has("admin"))
}
func (s *Server) book(r *http.Request) (any, error) {
	if !actor(r).Has("student") {
		return nil, forbidden()
	}
	var in struct {
		ID, Note string
		SlotID   string `json:"slot_id"`
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	aid, err := clientID(in.ID)
	if err != nil {
		return nil, err
	}
	sid, err := id(in.SlotID)
	if err != nil {
		return nil, err
	}
	note, err := field(in.Note, "预约说明", 0, 500)
	if err != nil {
		return nil, err
	}
	ctx, student := r.Context(), UserID(r)
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var staff string
		if err := tx.QueryRow(ctx, `SELECT staff_id FROM app.slots WHERE id=$1`, sid).Scan(&staff); err != nil {
			return nil, err
		}
		if staff == student {
			return nil, invalid("不能预约自己")
		}
		if err := lockedUsers(ctx, tx, student, staff); err != nil {
			return nil, err
		}
		existing, err := object(ctx, tx, appointmentSelect+" WHERE a.id=$1 AND a.student_id=$2", aid, student)
		if err == nil {
			return existing, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		if err := eligibleStaff(ctx, tx, staff, ""); err != nil {
			return nil, err
		}
		var start, end time.Time
		var canceled bool
		var mode, location string
		if err := tx.QueryRow(ctx, `SELECT sl.start_at,sl.end_at,sl.canceled,sl.mode,coalesce(nullif(p.location,''),(SELECT location FROM app.settings))
    FROM app.slots sl JOIN app.staff p ON p.id=sl.staff_id WHERE sl.id=$1 FOR UPDATE OF sl`, sid).Scan(&start, &end, &canceled, &mode, &location); err != nil {
			return nil, err
		}
		if canceled || !start.After(time.Now()) {
			return nil, stale("此时段已不可预约")
		}
		if err := checkBookingTime(ctx, tx, student, staff, start, end, nil); err != nil {
			return nil, err
		}
		var count int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM app.appointments WHERE student_id=$1 AND status IN ('pending','confirmed','in_progress') AND (start_at>now() OR status<>'pending')`, student).Scan(&count); err != nil {
			return nil, err
		}
		if count >= 3 {
			return nil, stale("你已有三个未结束的预约")
		}
		if _, err := tx.Exec(ctx, `INSERT INTO app.appointments(id,slot_id,student_id,staff_id,start_at,end_at,mode,location,note) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`, aid, sid, student, staff, start, end, mode, location, note); err != nil {
			return nil, err
		}
		if err := record(ctx, tx, "appointment", aid, student, "book", note, ""); err != nil {
			return nil, err
		}
		if err := notice(ctx, tx, staff, true, "appointment", "收到新的预约申请", "", "appointment", aid); err != nil {
			return nil, err
		}
		return object(ctx, tx, appointmentSelect+" WHERE a.id=$1", aid)
	})
}
func checkBookingTime(ctx context.Context, tx pgx.Tx, student, staff string, start, end time.Time, exclude any) error {
	var conflict bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app.appointments WHERE ($1 IN (student_id,staff_id) OR $2 IN (student_id,staff_id))
 AND status IN ('pending','confirmed','in_progress') AND (status<>'pending' OR start_at>now())
 AND start_at<$4 AND end_at>$3 AND ($5::uuid IS NULL OR id<>$5))`, student, staff, start, end, exclude).Scan(&conflict); err != nil {
		return err
	}
	if conflict {
		return stale("此时间与已有预约冲突")
	}
	return nil
}

type careInput struct {
	Reason, Note string
	InternalNote string `json:"internal_note"`
	StudentNote  string `json:"student_note"`
	StaffID      string `json:"staff_id"`
}

func (s *Server) appointmentAction(r *http.Request) (any, error) {
	uid, err := pathID(r)
	if err != nil {
		return nil, err
	}
	action := r.PathValue("action")
	u := actor(r)
	ctx := r.Context()
	var in careInput
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	for _, value := range []string{in.Reason, in.Note, in.InternalNote, in.StudentNote} {
		if _, e := field(value, "说明", 0, 2000); e != nil {
			return nil, e
		}
	}
	if !oneOf(action, "confirm", "reject", "cancel", "start", "complete", "no-show", "reassign") {
		return nil, missing()
	}
	return transaction(ctx, s.DB, func(tx pgx.Tx) (any, error) {
		var student, staff, status string
		var start, end time.Time
		var service *string
		if err := tx.QueryRow(ctx, `SELECT student_id,staff_id FROM app.appointments WHERE id=$1`, uid).Scan(&student, &staff); err != nil {
			return nil, err
		}
		lock := []string{student, staff}
		if action == "reassign" {
			target, e := id(in.StaffID)
			if e != nil {
				return nil, e
			}
			in.StaffID = target
			lock = append(lock, target)
		}
		if err := lockedUsers(ctx, tx, lock...); err != nil {
			return nil, err
		}
		if err := tx.QueryRow(ctx, `SELECT a.staff_id,a.status,a.start_at,a.end_at,s.id FROM app.appointments a LEFT JOIN app.services s ON s.appointment_id=a.id WHERE a.id=$1 FOR UPDATE OF a`, uid).Scan(&staff, &status, &start, &end, &service); err != nil {
			return nil, err
		}
		if !slices.Contains(lock, staff) {
			return nil, stale("负责人员已经变化，请刷新")
		}
		worker := u.ID == staff && u.Work()
		admin := u.Has("admin")
		if !worker && u.ID != student && !admin {
			return nil, missing()
		}
		if action != "cancel" && action != "reassign" && !worker {
			return nil, forbidden()
		}
		if worker && !(action == "cancel" && admin) {
			if err := eligibleStaff(ctx, tx, staff, ""); err != nil {
				return nil, err
			}
		}
		view := func() (any, error) { return object(ctx, tx, appointmentSelect+" WHERE a.id=$1", uid) }
		next, title := status, "预约已更新"
		switch action {
		case "confirm":
			if status == "confirmed" {
				return view()
			}
			if status != "pending" || !start.After(time.Now()) {
				return nil, stale("此预约已无法确认")
			}
			if _, _, err := openCare(ctx, tx, student, staff, &uid, nil); err != nil {
				return nil, err
			}
			next, title = "confirmed", "你的预约已确认"
		case "reject":
			if status != "pending" {
				return nil, stale("此预约已无法拒绝")
			}
			if len(strings.TrimSpace(in.Reason)) == 0 {
				return nil, invalid("请填写拒绝原因")
			}
			next, title = "rejected", "预约申请未获确认"
		case "cancel":
			if status == "canceled" {
				return view()
			}
			if !oneOf(status, "pending", "confirmed") || !start.After(time.Now()) {
				return nil, stale("此预约已无法取消")
			}
			if u.ID != student && len(strings.TrimSpace(in.Reason)) == 0 {
				return nil, invalid("请填写取消原因")
			}
			next, title = "canceled", "你的预约已取消"
		case "start":
			if status == "in_progress" {
				return view()
			}
			if status != "confirmed" || service == nil {
				return nil, stale("请先确认预约")
			}
			if _, err := tx.Exec(ctx, `UPDATE app.services SET status='in_progress' WHERE id=$1`, *service); err != nil {
				return nil, err
			}
			next, title = "in_progress", "服务已开始"
		case "complete":
			if status == "completed" {
				return view()
			}
			if status != "in_progress" || service == nil {
				return nil, stale("请先开始服务")
			}
			if err := s.completeCare(ctx, tx, *service, student, staff, in); err != nil {
				return nil, err
			}
			next, title = "completed", "服务已结束"
		case "no-show":
			if status != "confirmed" || time.Now().Before(start.Add(10*time.Minute)) {
				return nil, stale("开始时间十分钟后可以标记未到场")
			}
			next, title = "no_show", "预约已标记未到场"
		case "reassign":
			if !admin {
				return nil, forbidden()
			}
			if !oneOf(status, "pending", "confirmed", "in_progress") {
				return nil, stale("此预约已经结束")
			}
			if in.StaffID == staff {
				return view()
			}
			if in.StaffID == student {
				return nil, invalid("不能分配给预约学生本人")
			}
			if err := eligibleStaff(ctx, tx, in.StaffID, ""); err != nil {
				return nil, err
			}
			if err := checkBookingTime(ctx, tx, student, in.StaffID, start, end, uid); err != nil {
				return nil, err
			}
			if _, err := tx.Exec(ctx, `UPDATE app.appointments SET staff_id=$2,
     location=coalesce(nullif((SELECT location FROM app.staff WHERE id=$2),''),(SELECT location FROM app.settings)) WHERE id=$1`, uid, in.StaffID); err != nil {
				return nil, err
			}
			if service != nil {
				if err := moveCare(ctx, tx, *service, staff, in.StaffID); err != nil {
					return nil, err
				}
			}
			staff, title = in.StaffID, "预约已重新分配"
		}
		if service != nil && oneOf(next, "canceled", "no_show", "rejected", "expired") {
			if _, err := tx.Exec(ctx, `UPDATE app.services SET status='closed' WHERE id=$1;
   `, *service); err != nil {
				return nil, err
			}
			if _, err := tx.Exec(ctx, `UPDATE app.conversations SET closed=true WHERE service_id=$1`, *service); err != nil {
				return nil, err
			}
			if _, err := tx.Exec(ctx, `UPDATE app.ai_shares SET revoked_at=now() WHERE service_id=$1 AND revoked_at IS NULL`, *service); err != nil {
				return nil, err
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE app.appointments SET status=$2,reason=$3,updated_at=now() WHERE id=$1`, uid, next, in.Reason); err != nil {
			return nil, err
		}
		if err := record(ctx, tx, "appointment", uid, u.ID, action, in.Reason, ""); err != nil {
			return nil, err
		}
		if u.ID != student {
			if err := notice(ctx, tx, student, false, "appointment", title, in.Reason, "appointment", uid); err != nil {
				return nil, err
			}
		}
		if u.ID != staff {
			if err := notice(ctx, tx, staff, true, "appointment", title, in.Reason, "appointment", uid); err != nil {
				return nil, err
			}
		}
		return view()
	})
}
