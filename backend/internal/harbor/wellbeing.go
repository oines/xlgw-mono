package harbor

import (
	"net/http"
	"strings"
	"time"
)

func wellbeingDay(r *http.Request) (time.Time, error) {
	raw := r.PathValue("day")
	day, err := time.Parse(time.DateOnly, raw)
	if err != nil || day.Year() == 0 || day.Format(time.DateOnly) != raw {
		return time.Time{}, invalid("日期须为有效的 YYYY-MM-DD")
	}
	return day, nil
}

func (s *Server) wellbeingJournal(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, `SELECT day,mood,note FROM app.wellbeing_journal
 WHERE user_id=$1 ORDER BY day DESC LIMIT $2 OFFSET $3`, UserID(r), n, o)
}

func (s *Server) saveWellbeingJournal(r *http.Request) (any, error) {
	day, err := wellbeingDay(r)
	if err != nil {
		return nil, err
	}
	var in struct{ Mood, Note string }
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if !oneOf(in.Mood, "calm", "happy", "tired", "sad", "anxious") {
		return nil, invalid("请选择一个情绪")
	}
	note, err := field(in.Note, "备注", 0, 500)
	if err != nil {
		return nil, err
	}
	if strings.ContainsRune(note, 0) {
		return nil, invalid("备注含有无效字符")
	}
	if _, err := s.DB.Exec(r.Context(), `INSERT INTO app.wellbeing_journal(user_id,day,mood,note)
 VALUES($1,$2,$3,$4) ON CONFLICT(user_id,day) DO UPDATE SET mood=EXCLUDED.mood,note=EXCLUDED.note`,
		UserID(r), day, in.Mood, note); err != nil {
		return nil, err
	}
	return Object{"day": day.Format(time.DateOnly), "mood": in.Mood, "note": note}, nil
}

func (s *Server) deleteWellbeingJournal(r *http.Request) (any, error) {
	day, err := wellbeingDay(r)
	if err != nil {
		return nil, err
	}
	_, err = s.DB.Exec(r.Context(), `DELETE FROM app.wellbeing_journal WHERE user_id=$1 AND day=$2`, UserID(r), day)
	return nil, err
}

func (s *Server) wellbeingSleep(r *http.Request) (any, error) {
	n, o := page(r)
	return items(r.Context(), s.DB, `SELECT day,minutes_after_midnight FROM app.wellbeing_sleep
 WHERE user_id=$1 ORDER BY day DESC LIMIT $2 OFFSET $3`, UserID(r), n, o)
}

func (s *Server) saveWellbeingSleep(r *http.Request) (any, error) {
	day, err := wellbeingDay(r)
	if err != nil {
		return nil, err
	}
	var in struct {
		Minutes *int `json:"minutes_after_midnight"`
	}
	if err := decode(r, &in); err != nil {
		return nil, err
	}
	if in.Minutes == nil || *in.Minutes < 0 || *in.Minutes > 1439 {
		return nil, invalid("入睡时间须为 0–1439 的整数分钟")
	}
	if _, err := s.DB.Exec(r.Context(), `INSERT INTO app.wellbeing_sleep(user_id,day,minutes_after_midnight)
 VALUES($1,$2,$3) ON CONFLICT(user_id,day) DO UPDATE SET minutes_after_midnight=EXCLUDED.minutes_after_midnight`,
		UserID(r), day, *in.Minutes); err != nil {
		return nil, err
	}
	return Object{"day": day.Format(time.DateOnly), "minutes_after_midnight": *in.Minutes}, nil
}

func (s *Server) exportWellbeing(r *http.Request) (any, error) {
	return object(r.Context(), s.DB, `SELECT
 (SELECT COALESCE(jsonb_agg(jsonb_build_object('day',day,'mood',mood,'note',note) ORDER BY day DESC),'[]'::jsonb)
  FROM app.wellbeing_journal WHERE user_id=$1) AS journal,
 (SELECT COALESCE(jsonb_agg(jsonb_build_object('day',day,'minutes_after_midnight',minutes_after_midnight) ORDER BY day DESC),'[]'::jsonb)
  FROM app.wellbeing_sleep WHERE user_id=$1) AS sleep`, UserID(r))
}

func (s *Server) deleteWellbeing(r *http.Request) (any, error) {
	_, err := s.DB.Exec(r.Context(), `WITH journal AS (DELETE FROM app.wellbeing_journal WHERE user_id=$1)
 DELETE FROM app.wellbeing_sleep WHERE user_id=$1`, UserID(r))
	return nil, err
}
