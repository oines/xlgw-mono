package harbor

import "testing"

func TestExplicitCommunitySignalsQueuePrivateReview(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	author := public.authenticate("review-author", "内容作者")
	reader := public.authenticate("review-reader", "同学")
	tags := []string{"树洞"}
	const flagged = "我不想活了"
	post := author.call("POST", "/posts", 200, Object{"mode": "anonymous", "body": flagged, "tags": tags})
	assertValue(t, post, "review_pending", true)
	assertValue(t, post, "author_id", nil)
	pid := getStr(t, post, "id")
	path := "/posts/" + pid
	reader.call("GET", path, 404, nil)
	reader.call("GET", path+"/comments", 404, nil)
	reader.call("POST", path+"/comments", 404, Object{"body": "评论这条帖子"})
	reader.call("PUT", path+"/resonance", 404, Object{"active": true})
	reader.call("GET", "/admin/reports", 403, nil)
	if rows := getItems(t, reader.call("GET", "/posts", 200, nil)); len(rows) != 0 {
		t.Fatal("public feed showed a post held for review")
	}

	pending := func(target string) Object {
		t.Helper()
		rows := getItems(t, admin.call("GET", "/admin/reports?status=pending", 200, nil))
		if len(rows) != 1 {
			t.Fatalf("expected one pending review, got %d", len(rows))
		}
		row := lookupItem(t, rows, "target_id", target)
		assertValue(t, row, "source", "safety")
		assertValue(t, row, "reporter_id", nil)
		assertValue(t, row, "reporter_name", "系统初筛")
		return row
	}
	first := pending(pid)
	assertValue(t, first, "evidence", flagged)
	assertValue(t, first, "author_id", author.ID)
	firstID := getStr(t, first, "id")
	results := make(chan response, 2)
	for range 2 {
		go func() { results <- author.request("PATCH", path, Object{"body": flagged, "tags": tags}) }()
	}
	for range 2 {
		assertValue(t, getResponse(t, <-results, 200, "repeat flagged edit"), "review_pending", true)
	}
	assertValue(t, pending(pid), "id", firstID)
	const edited = flagged + "，刚才有点难过。"
	assertValue(t, author.call("PATCH", path, 200, Object{"body": edited, "tags": tags}), "review_pending", true)
	latest := pending(pid)
	assertValue(t, latest, "evidence", edited)
	admin.call("POST", "/admin/reports/"+firstID+"/resolve", 404, Object{"action": "dismiss", "result": "旧审核页面"})
	admin.call("POST", "/admin/reports/"+getStr(t, latest, "id")+"/resolve", 200, Object{"action": "dismiss", "result": "已核阅"})
	assertValue(t, reader.call("GET", path, 200, nil), "review_pending", false)
	assertValue(t, author.call("PATCH", path, 200, Object{"body": edited, "tags": []string{"关系"}}), "review_pending", false)

	comment := reader.call("POST", path+"/comments", 200, Object{"body": flagged})
	assertValue(t, comment, "review_pending", true)
	cid := getStr(t, comment, "id")
	assertValue(t, author.call("GET", path, 200, nil), "comments", float64(0))
	if rows := getItems(t, author.call("GET", path+"/comments", 200, nil)); len(rows) != 0 {
		t.Fatal("post author saw someone else's held comment")
	}
	author.call("POST", path+"/comments", 404, Object{"body": "回复评论", "parent_id": cid})
	assertValue(t, lookupItem(t, getItems(t, reader.call("GET", path+"/comments", 200, nil)), "id", cid), "review_pending", true)
	review := pending(cid)
	assertValue(t, review, "target_type", "comment")
	admin.call("POST", "/admin/reports/"+getStr(t, review, "id")+"/resolve", 200, Object{"action": "remove", "result": "已移除"})
	if rows := getItems(t, reader.call("GET", path+"/comments", 200, nil)); len(rows) != 0 {
		t.Fatal("held comment was visible after removal")
	}

	resonance := author.call("POST", "/posts", 200, Object{"mode": "resonance", "body": flagged})
	assertValue(t, resonance, "review_pending", true)
	assertValue(t, pending(getStr(t, resonance, "id")), "target_type", "post")
}
