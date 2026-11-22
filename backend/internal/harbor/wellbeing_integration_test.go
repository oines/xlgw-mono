package harbor

import (
	"strings"
	"testing"
)

func TestWellbeingRecordsArePrivateAndDeletable(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	owner := public.authenticate("wellbeing-owner", "小夏")
	other := public.authenticate("wellbeing-other", "小秋")

	const day = "2026-11-22"
	const previous = "2026-11-21"
	const journal = "/wellbeing/journal/" + day
	const sleep = "/wellbeing/sleep/" + day
	const export = "/wellbeing/export"
	const all = "/wellbeing/data"

	public.call("GET", export, 401, nil)
	public.call("DELETE", all, 401, nil)
	owner.call("PUT", "/wellbeing/journal/2026-02-30", 400, Object{"mood": "calm"})
	owner.call("PUT", journal, 400, Object{"mood": "unknown"})
	owner.call("PUT", journal, 400, Object{"mood": "calm", "note": strings.Repeat("好", 501)})
	owner.call("PUT", sleep, 400, Object{})
	owner.call("PUT", sleep, 400, Object{"minutes_after_midnight": 1440})
	owner.call("PUT", sleep, 400, Object{"minutes_after_midnight": 1.5})

	assertValue(t, owner.call("PUT", journal, 200, Object{"mood": "tired"}), "note", "")
	assertValue(t, owner.call("PUT", journal, 200, Object{"mood": "calm", "note": " 今天很好 "}), "note", "今天很好")
	owner.call("PUT", "/wellbeing/journal/"+previous, 200, Object{"mood": "happy"})
	other.call("PUT", journal, 200, Object{"mood": "sad"})
	owner.call("PUT", sleep, 200, Object{"minutes_after_midnight": 1439})
	assertValue(t, owner.call("PUT", sleep, 200, Object{"minutes_after_midnight": 0}), "minutes_after_midnight", float64(0))
	other.call("PUT", sleep, 200, Object{"minutes_after_midnight": 120})

	rows := getItems(t, owner.call("GET", "/wellbeing/journal?limit=1", 200, nil))
	if len(rows) != 1 {
		t.Fatalf("limited journal returned %d records; want 1", len(rows))
	}
	assertValue(t, rows[0], "day", day)
	assertValue(t, rows[0], "mood", "calm")
	assertValue(t, rows[0], "note", "今天很好")
	rows = getItems(t, owner.call("GET", "/wellbeing/sleep", 200, nil))
	if len(rows) != 1 {
		t.Fatalf("sleep returned %d records; want 1", len(rows))
	}
	assertValue(t, rows[0], "day", day)
	assertValue(t, rows[0], "minutes_after_midnight", float64(0))

	verifyExport := func(c businessClient, journalCount, sleepCount int) {
		t.Helper()
		dump := c.call("GET", export, 200, nil)
		for field, want := range map[string]int{"journal": journalCount, "sleep": sleepCount} {
			entries, ok := dump[field].([]any)
			if !ok || len(entries) != want {
				t.Fatalf("exported %s = %#v; want %d records", field, dump[field], want)
			}
		}
	}
	verifyExport(owner, 2, 1)
	verifyExport(other, 1, 1)
	verifyExport(admin, 0, 0)

	owner.call("DELETE", "/wellbeing/journal/"+previous, 204, nil)
	owner.call("DELETE", "/wellbeing/journal/"+previous, 204, nil)
	verifyExport(owner, 1, 1)
	owner.call("DELETE", all, 204, nil)
	owner.call("DELETE", all, 204, nil)
	verifyExport(owner, 0, 0)
	verifyExport(other, 1, 1)
	assertValue(t, getItems(t, other.call("GET", "/wellbeing/journal", 200, nil))[0], "mood", "sad")
	assertValue(t, getItems(t, other.call("GET", "/wellbeing/sleep", 200, nil))[0], "minutes_after_midnight", float64(120))
}
