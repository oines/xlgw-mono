package harbor

import (
	"strings"
	"testing"
)

func TestAnonymousCommunityKeepsAuthorPrivate(t *testing.T) {
	_, public, admin := newBusinessTest(t)
	author := public.authenticate("community-author", "发帖同学")
	reader := public.authenticate("community-reader", "回帖同学")
	profile := "/posts?author_id=" + author.ID
	public.call("GET", "/posts?mode=anonymous", 401, nil)
	reader.call("GET", "/posts?mode=invalid", 400, nil)
	reader.call("POST", "/posts", 400, Object{"mode": "invalid", "body": "这条没有发布"})

	tags := []string{"平静"}
	named := author.call("POST", "/posts", 200, Object{"body": "实名讨论", "tags": tags})
	assertValue(t, named, "mode", "named")
	assertValue(t, named, "author_id", author.ID)
	assertValue(t, named, "author_name", "发帖同学")
	assertValue(t, named, "is_owner", true)

	assertAnonymous := func(item Object, own bool) {
		t.Helper()
		assertValue(t, item, "mode", "anonymous")
		assertValue(t, item, "is_owner", own)
		assertValue(t, item, "author_id", nil)
		assertValue(t, item, "author_avatar", nil)
		assertValue(t, item, "author_name", "匿名同学")
	}
	post := author.call("POST", "/posts", 200, Object{"mode": "anonymous", "body": "匿名讨论", "tags": []string{"睡眠", "关系", "树洞"}})
	assertAnonymous(post, true)
	pid := getStr(t, post, "id")
	path := "/posts/" + pid
	assertAnonymous(reader.call("GET", path, 200, nil), false)
	assertAnonymous(lookupItem(t, getItems(t, reader.call("GET", "/posts", 200, nil)), "id", pid), false)
	assertAnonymous(lookupItem(t, getItems(t, author.call("GET", profile, 200, nil)), "id", pid), true)
	profilePosts := getItems(t, reader.call("GET", profile, 200, nil))
	if len(profilePosts) != 1 {
		t.Fatalf("public profile showed %d posts; want 1 named post", len(profilePosts))
	}
	assertValue(t, profilePosts[0], "id", named["id"])
	if rows := getItems(t, reader.call("GET", profile+"&mode=anonymous", 200, nil)); len(rows) != 0 {
		t.Fatal("public profile exposed anonymous posts")
	}
	reader.call("PATCH", path, 404, Object{"body": "覆盖", "tags": tags})
	assertAnonymous(author.call("PATCH", path, 200, Object{"body": "匿名讨论已编辑", "tags": tags}), true)
	author.call("PATCH", path, 400, Object{"mode": "named", "body": "改变身份", "tags": tags})

	comment := reader.call("POST", path+"/comments", 200, Object{"body": "也这样想"})
	assertAnonymous(comment, true)
	cid := getStr(t, comment, "id")
	assertAnonymous(lookupItem(t, getItems(t, author.call("GET", path+"/comments", 200, nil)), "id", cid), false)
	assertAnonymous(lookupItem(t, getItems(t, reader.call("GET", "/comments?scope=mine", 200, nil)), "id", cid), true)
	author.call("DELETE", "/comments/"+cid, 404, nil)
	reader.call("DELETE", "/comments/"+cid, 204, nil)

	reader.call("POST", path+"/block", 204, nil)
	reader.call("POST", path+"/block", 204, nil)
	reader.call("GET", path, 404, nil)
	reader.call("GET", path+"/comments", 404, nil)
	assertAnonymous(author.call("GET", path, 200, nil), true)
	if rows := getItems(t, reader.call("GET", "/blocks", 200, nil)); len(rows) != 0 {
		t.Fatal("anonymous post block exposed its author in the user block list")
	}
	if rows := getItems(t, reader.call("GET", profile, 200, nil)); len(rows) != 1 {
		t.Fatal("anonymous post block changed named author visibility")
	}
	reader.call("DELETE", path+"/block", 204, nil)
	assertAnonymous(reader.call("GET", path, 200, nil), false)

	report := reader.call("POST", "/reports", 200, Object{"target_type": "post", "target_id": pid, "reason": "不当内容"})
	assertValue(t, report, "author_id", nil)
	reader.call("GET", "/admin/reports", 403, nil)
	rid := getStr(t, report, "id")
	moderation := lookupItem(t, getItems(t, admin.call("GET", "/admin/reports", 200, nil)), "id", rid)
	assertValue(t, moderation, "author_id", author.ID)
	admin.call("POST", "/admin/reports/"+rid+"/resolve", 200, Object{"action": "remove", "result": "已处理"})
	reader.call("GET", path, 404, nil)
}

func TestResonancePlazaDoesNotExposeRankingOrComments(t *testing.T) {
	_, public, _ := newBusinessTest(t)
	author := public.authenticate("plaza-author", "小春")
	reader := public.authenticate("plaza-reader", "小冬")

	author.call("POST", "/posts", 400, Object{"mode": "resonance", "body": strings.Repeat("好", 61)})
	older := author.call("POST", "/posts", 200, Object{"mode": "resonance", "body": "今天读了一会书"})
	olderID := getStr(t, older, "id")
	newer := author.call("POST", "/posts", 200, Object{"mode": "resonance", "body": strings.Repeat("好", 60)})
	newerID := getStr(t, newer, "id")
	path := "/posts/" + olderID
	assertValue(t, older, "mode", "resonance")
	assertValue(t, older, "is_owner", true)
	assertValue(t, older, "author_id", nil)
	assertValue(t, older, "author_avatar", nil)
	assertValue(t, older, "author_name", "匿名同学")
	author.call("PATCH", path, 400, Object{"body": strings.Repeat("好", 61)})
	assertValue(t, author.call("PATCH", path, 200, Object{"body": "今天看了一会书"}), "mode", "resonance")

	reader.call("GET", path+"/comments", 404, nil)
	reader.call("POST", path+"/comments", 404, Object{"body": "不能评论"})
	post := reader.call("PUT", path+"/resonance", 200, Object{"active": true})
	assertValue(t, post, "resonated", true)
	assertValue(t, post, "resonances", nil)
	assertValue(t, post, "comments", nil)
	assertValue(t, post, "is_owner", false)
	assertValue(t, post, "author_id", nil)
	if rows := getItems(t, reader.call("GET", "/posts", 200, nil)); len(rows) != 0 {
		t.Fatal("general community returned resonance-only posts")
	}
	for _, sort := range []string{"hot", "resonance"} {
		rows := getItems(t, reader.call("GET", "/posts?mode=resonance&sort="+sort, 200, nil))
		if len(rows) != 2 {
			t.Fatalf("plaza returned %d posts; want 2", len(rows))
		}
		assertValue(t, rows[0], "id", newerID)
		assertValue(t, rows[0], "resonances", nil)
		assertValue(t, rows[1], "id", olderID)
		assertValue(t, rows[1], "resonances", nil)
	}
	if rows := getItems(t, reader.call("GET", "/posts?mode=resonance&author_id="+author.ID, 200, nil)); len(rows) != 0 {
		t.Fatal("author filter exposed resonance post ownership")
	}
	assertValue(t, reader.call("PUT", path+"/resonance", 200, Object{"active": false}), "resonated", false)
}
