# 心灵港湾 HTTP API

统一前缀 /api/v1，JSON UTF-8，UUID 字符串，时间 RFC3339。Bearer token 供移动端使用，网页同源会话 Cookie 由登录设置。列表响应为 {items:[]}，对象直接返回。错误形如 {code,message,retry_at?}。资源不可见通常返回 404。列表默认最近 100 条，可筛选 offset、limit。

## 身份、学校与资源

- GET /school → {name,intro,logo_url,location,contact,service_hours,registered_open,initialized,timezone,followup_delay_hours,teacher_minutes,peer_minutes,slot_gap_minutes}。
- POST /auth/register {account,password,nickname}，POST /auth/login {account,password} → {user,token}。POST /auth/logout → 204。初始管理员由服务器环境变量创建。GET /me、PATCH /me {nickname?,avatar_url?,theme?,motion?} → user。
- user = {id,account,nickname,avatar_url,roles,active,school,theme,motion,created_at}。roles 为 student/teacher/peer/admin。POST /me/password {old_password,new_password}。GET /me/shares。
- GET /resources?kind=support|article|activity|announcement → [{id,kind,title,body,url,published,created_at}]。
- GET /avatars/catalog → {version,presets,moods}。GET /avatars/me → {revision,config}，PUT /avatars/me {revision,config} → 同形，409 为保存冲突。

## 校内支持与预约

- GET /staff?role=teacher|peer&mode=online|onsite&date=YYYY-MM-DD，GET /staff/{id}，GET/PATCH /staff/me。对象 {id,nickname,avatar_url,role,bio,modes,location,supervisor_id,supervisor_name,active,next_slot}，编辑支持 {bio,modes,location}。
- GET /slots?staff_id=&scope=work&from=&to=，POST /slots {start_at,end_at?,mode} 或 {items:[{start_at,end_at?,mode}]} → {items:[slot]}，DELETE /slots/{id}。slot = {id,staff_id,staff_name,role,start_at,end_at,mode,available,appointment_id?}，工作人员看到已占位时段。
- GET /appointments?scope=work&staff_id=&status=&from=&to=；GET /appointments/{id}；POST /appointments {id?,slot_id,note?}。对象 {id,slot_id,student_id,student_name,staff_id,staff_name,role,start_at,end_at,mode,location,note,status,reason,service_id,conversation_id,created_at,updated_at,history:[{action,note,created_at}]}。
- POST /appointments/{id}/confirm|reject|cancel|start|complete|no-show|reassign；参数 {reason?,internal_note?,student_note?,staff_id?}。状态 pending/confirmed/in_progress/completed/rejected/canceled/expired/no_show。
- GET /services?scope=work，GET /services/{id} → {id,student_id,student_name,staff_id,staff_name,role,appointment_id,help_id,conversation_id,status,internal_note?,student_note,completed_at,shares:[{id,body,created_at}],created_at}。GET /services/{id}/shares 按授权读取；POST /services/{id}/shares {conversation_id,message_ids,expected_staff_id} 或 {conversation_id,summary,expected_staff_id}，确认后负责人变化返回 409；DELETE /shares/{id} 撤回。

## 人工消息、通知与同学交流

- GET /conversations?scope=work，GET /conversations/{id} → {id,kind,participant_id,name,avatar_url,service_id,appointment_id,read_only,unread,last_message,updated_at}。kind 为 care/peer。GET /conversations/{id}/messages?before= 获取消息，POST 同路径 {id?,body}，消息为 {id,sender_id,sender_name,body,created_at}。POST /conversations/{id}/read；POST /conversations/{id}/close。
- GET /chat-requests；POST /chat-requests {recipient_id,note}；POST /chat-requests/{id}/accept|reject。对象 {id,sender_id,sender_name,recipient_id,recipient_name,note,status,conversation_id,created_at}。
- GET /notifications?scope=work，POST /notifications/{id}/read，POST /notifications/read-all {scope?}。对象 {id,kind,title,body,target_type,target_id,read,created_at}。
- POST /blocks/{user_id}、DELETE /blocks/{user_id}、GET /blocks，返回 {id,nickname,created_at}。

## 回访、求助与转交流程

- GET /followups?scope=work&status=&staff_id=，GET /followups/{id}，PUT /followups/{id}/draft、POST /followups/{id}/submit {mood,helpfulness,recommendation?,note?,contact_requested}。mood better/same/worse，helpfulness helpful/neutral/unhelpful。记录 {id,service_id,student_id,student_name,staff_id,staff_name,status,answers,created_at,available_at,submitted_at,history:[{action,note,student_note,actor_name,created_at}]}。
- POST /followups/{id}/resend|review|contact|close|reassign {note?,student_note?,staff_id?}。状态 awaiting/pending_review/pending_contact/following/closed。
- GET /help-requests?scope=work&status=&staff_id=，GET /help-requests/{id}，POST /help-requests {contact,body,preferred_time}。记录 {id,student_id,student_name,staff_id,staff_name,contact,body,preferred_time,status,service_id,conversation_id,created_at,history:[{action,note,student_note,actor_name,created_at}]}。
- POST /help-requests/{id}/assign|claim|contact|close {staff_id?,note?,student_note?}。状态 submitted/assigned/contacting/closed。
- GET /transfers，POST /transfers {service_id,staff_id,note}，POST /transfers/{id}/accept|reject {note?}。记录 {id,service_id,from_id,from_name,to_id,to_name,student_name,note,status,created_at}。

## 社区与反馈

- GET /posts?sort=latest|hot|resonance&author_id=，GET /posts/{id}，POST /posts {body,tags}，PATCH /posts/{id} {body,tags}，DELETE /posts/{id}。对象 {id,author_id,author_name,author_avatar,body,tags,resonances,comments,resonated,created_at,updated_at,edited}。
- GET /posts/{id}/comments，POST /posts/{id}/comments {body,parent_id?}，DELETE /comments/{id}。评论 {id,post_id,parent_id,author_id,author_name,author_avatar,body,created_at}。GET /comments?scope=mine。
- PUT /posts/{id}/resonance {active} → post。GET /people/{id} → {id,nickname,avatar_url,blocked}。
- POST /reports {target_type:'post'|'comment'|'message',target_id,reason,note?}。GET /admin/reports?status=，POST /admin/reports/{id}/resolve {action:'dismiss'|'remove'|'restrict',result}。对象 {id,target_type,target_id,reporter_id,reporter_name,author_id,author_name,reason,note,evidence,status,result,created_at}。
- GET /feedback、POST /feedback {category,body,contact?}。GET /admin/feedback?status=、PATCH /admin/feedback/{id} {status,reply?}。记录 {id,student_id,student_name,category,body,contact,status,reply,created_at}，状态 pending/processing/resolved。

## 运营

- GET /admin/users?q=&role=&active=，POST /admin/users {account,password,nickname,roles}，PATCH /admin/users/{id} {nickname?,roles?,active?}。返回 user，列表另有 open_items。PUT /admin/staff/{id} {role,bio,modes,location,supervisor_id,active} → staff。
- GET/PATCH /admin/settings 对应 school 字段，时区为 IANA 字符串。GET /admin/stats?from=YYYY-MM-DD&to=YYYY-MM-DD → {registered,active,ai_inputs,appointments_completed,followups_submitted,pending,series:[{date,registered,active,ai_inputs,appointments_completed,followups_submitted}]}。GET /admin/operations。
- GET /admin/resources、POST /admin/resources {kind,title,body,url,published}、PATCH /admin/resources/{id} 同形、DELETE /admin/resources/{id}。

## AI

- GET/POST /ai/conversations，GET/PATCH/DELETE /ai/conversations/{id}；POST/PATCH {title?}。列表项 {id,title,created_at,updated_at}。GET /ai/conversations/{id}/messages → {items:[{id,role,text,input_id?,created_at}],run?}。
- POST /ai/conversations/{id}/inputs {id,text}，GET /ai/runs/{id}，POST /ai/runs/{id}/cancel，POST /ai/inputs/{id}/retry {id}。run = {id,input_id,conversation_id,status,error?}，详见 AI 实现。
- GET /ai/runs/{id}/events → SSE snapshot|delta|state，data {run,text?,attempt_id?,reset?}。GET /ai/quota → {daily_limit,used,remaining,per_minute,enabled,reset_at}。
- GET/POST /admin/ai/connections，PATCH /admin/ai/connections/{id}，POST /admin/ai/connections/{id}/test。{name,provider?,protocol:'openai-completions',base_url,api_key?,models:[string],enabled}。返回省略 api_key，附上 {id,has_key,last_test_status,last_test_at,last_test_error}。
- GET/PUT /admin/ai/routes → {items:[{purpose:'chat'|'summary'|'title',connection_id,model,fallback_connection_id?,fallback_model?,temperature,max_output_tokens,context_window}]}。GET /admin/ai/calls → {items:[{id,connection_id,purpose,model,user_id,status,latency_ms,input_tokens?,output_tokens?,cost_estimate?,error_code,created_at}]}。
- GET/PUT /admin/ai/limits → {enabled,daily_limit,per_minute,global_concurrency}。GET /admin/ai/limits/users、PUT /admin/ai/limits/users/{id} → {enabled?,daily_limit?,per_minute?}，null 继承默认。

- POST /ai/conversations/{id}/share-summary {message_ids} → {summary}。所有人可请求模型整理最多 20 条选中消息，返回草稿供确认，实际授权仍调用服务分享入口。该模型请求计入网关真实用量。
- PUT /ai/conversations/{id}/messages/{message}/feedback {helpful,note?} → {helpful}。仅会话所有人可为已持久化的 AI 回复提交或修改反馈。

注册模式通过 /school 的 registration_mode 获取（open 或 invite）。管理员 PATCH /admin/settings 可设置 registration_mode 和 invite_code。响应只返回 invite_configured。邀请码模式下，POST /auth/register 发送 invite_code。学生 GET /me/ai-consent 获取 {agreed}，确认使用说明后 POST {agreed:true}。模型发送、重试和分享摘要需要确认记录。

## 伙伴资源

- GET /companion/assets → {current,bundles:[{release,version,files:[{path,size,sha256}]}]}。未部署资源目录时返回空清单。版本 1 使用公开伙伴的骨骼和预设命名。
- GET /companion-assets/{release}/{path} 读取不可变版本资源。模型和图像可热更，渲染代码随 App 发布。
