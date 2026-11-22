package harbor

import "net/http"

func (s *Server) Register(m *http.ServeMux) {
	const p = "/api/v1"
	m.HandleFunc("GET /healthz", handle(func(r *http.Request) (any, error) { return Object{"status": "ok"}, s.DB.Ping(r.Context()) }))
	m.HandleFunc("GET "+p+"/school", handle(s.school))
	m.HandleFunc("GET "+p+"/resources", handle(s.resources))
	m.HandleFunc("POST "+p+"/auth/register", s.authenticate(true))
	m.HandleFunc("POST "+p+"/auth/login", s.authenticate(false))
	m.HandleFunc("POST "+p+"/auth/logout", s.Auth(s.logout))
	for route, fn := range map[string]endpoint{
		"GET /me": s.me, "PATCH /me": s.updateMe, "POST /me/password": s.password, "GET /me/shares": s.myShares,
		"GET /me/ai-consent": s.aiConsent, "POST /me/ai-consent": s.aiConsent,
		"GET /avatars/catalog": s.catalog, "GET /avatars/me": s.avatar, "PUT /avatars/me": s.saveAvatar,
		"GET /staff": s.staffList, "GET /staff/{id}": s.staffDetail, "GET /staff/me": s.myStaff, "PATCH /staff/me": s.editStaff,
		"GET /slots": s.slots, "POST /slots": s.addSlots, "DELETE /slots/{id}": s.deleteSlot,
		"GET /appointments": s.appointments, "GET /appointments/{id}": s.appointmentDetail, "POST /appointments": s.book,
		"POST /appointments/{id}/{action}": s.appointmentAction,
		"GET /services":                    s.services, "GET /services/{id}": s.serviceDetail, "GET /services/{id}/shares": s.serviceShares,
		"POST /services/{id}/shares": s.createShare, "DELETE /shares/{id}": s.deleteShare,
		"GET /followups": s.followups, "GET /followups/{id}": s.followupDetail, "PUT /followups/{id}/draft": s.followupDraft,
		"POST /followups/{id}/{action}": s.followupAction,
		"GET /help-requests":            s.helpRequests, "GET /help-requests/{id}": s.helpDetail, "POST /help-requests": s.createHelp, "POST /help-requests/{id}/{action}": s.helpAction,
		"GET /transfers": s.transfers, "POST /transfers": s.createTransfer, "POST /transfers/{id}/{action}": s.transferAction,
		"GET /conversations": s.conversations, "GET /conversations/{id}": s.conversationDetail, "GET /conversations/{id}/messages": s.messages,
		"POST /conversations/{id}/messages": s.sendMessage, "POST /conversations/{id}/read": s.readConversation, "POST /conversations/{id}/close": s.closeConversation,
		"GET /chat-requests": s.chatRequests, "POST /chat-requests": s.createChatRequest, "POST /chat-requests/{id}/{action}": s.chatAction,
		"GET /notifications": s.notifications, "POST /notifications/{id}/read": s.readNotice, "POST /notifications/read-all": s.readAllNotices,
		"GET /posts": s.posts, "GET /posts/{id}": s.postDetail, "POST /posts": s.createPost, "PATCH /posts/{id}": s.editPost, "DELETE /posts/{id}": s.deletePost,
		"GET /posts/{id}/comments": s.comments, "POST /posts/{id}/comments": s.createComment, "GET /comments": s.myComments, "DELETE /comments/{id}": s.deleteComment,
		"PUT /posts/{id}/resonance": s.resonance, "GET /people/{id}": s.person, "GET /blocks": s.blocks, "POST /blocks/{id}": s.block, "DELETE /blocks/{id}": s.unblock,
		"POST /reports": s.report, "GET /feedback": s.feedback, "POST /feedback": s.createFeedback,
	} {
		for i, c := range route {
			if c == ' ' {
				m.HandleFunc(route[:i+1]+p+route[i+1:], s.Auth(handle(fn)))
				break
			}
		}
	}
	for route, fn := range map[string]endpoint{
		"GET /users": s.adminUsers, "POST /users": s.adminCreateUser, "PATCH /users/{id}": s.adminUpdateUser, "PUT /staff/{id}": s.adminStaff,
		"GET /reports": s.adminReports, "POST /reports/{id}/resolve": s.resolveReport, "GET /feedback": s.adminFeedback, "PATCH /feedback/{id}": s.updateFeedback,
		"GET /settings": s.school, "PATCH /settings": s.updateSchool, "GET /stats": s.stats, "GET /operations": s.operations,
		"GET /resources": s.adminResources, "POST /resources": s.createResource, "PATCH /resources/{id}": s.editResource, "DELETE /resources/{id}": s.deleteResource,
	} {
		for i, c := range route {
			if c == ' ' {
				m.HandleFunc(route[:i+1]+p+"/admin"+route[i+1:], s.Admin(handle(fn)))
				break
			}
		}
	}
}
