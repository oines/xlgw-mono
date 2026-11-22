import { useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  ArrowLeft,
  ArrowUpRight,
  ChevronRight,
  FileText,
  Info,
  LockKeyhole,
  MessageSquare,
  Send,
  Users,
} from "lucide-react";
import {
  api,
  dateTime,
  text,
  write,
  type ListResult,
  type Row,
} from "../lib/api";
import { useList, useObject, useWrite } from "../lib/data";
import { useSession } from "../lib/session";
import {
  Avatar,
  Button,
  DetailList,
  Drawer,
  Empty,
  ErrorNotice,
  Field,
  Loading,
  PageHeader,
  SearchInput,
  Status,
  useToast,
} from "../components/ui";

export function InboxPage() {
  const { user } = useSession();
  const [params, setParams] = useSearchParams();
  const [search, setSearch] = useState("");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<Error | null>(null);
  const [infoOpen, setInfoOpen] = useState(false);
  const [transferOpen, setTransferOpen] = useState(false);
  const [target, setTarget] = useState("");
  const [transferNote, setTransferNote] = useState("");
  const pendingInput = useRef<{
    id: string;
    body: string;
    conversation: string;
  } | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const atBottom = useRef(true);
  const readCursor = useRef("");
  const client = useQueryClient();
  const toast = useToast();
  const mutation = useWrite();
  const conversations = useList("/conversations?scope=work", true, true);
  const id = params.get("selected") || "";
  const conversation = useObject(`/conversations/${id}`, Boolean(id));
  const current =
    conversation.data || conversations.data?.items.find((row) => row.id === id);
  const serviceId = text(current, "service_id");
  const service = useObject(`/services/${serviceId}`, Boolean(serviceId));
  const staff = useList("/staff?role=teacher", transferOpen);
  const messages = useQuery({
    queryKey: ["messages", id],
    queryFn: () => api<ListResult<Row>>(`/conversations/${id}/messages`),
    enabled: Boolean(id),
    refetchInterval: id ? 3000 : false,
  });
  const list = messages.data?.items || [];
  const latest = list[list.length - 1]?.id;
  useEffect(() => {
    if (atBottom.current)
      scrollRef.current?.scrollTo({
        top: scrollRef.current.scrollHeight,
        behavior: "smooth",
      });
  }, [latest, id]);
  useEffect(() => {
    atBottom.current = true;
    readCursor.current = "";
    setSendError(null);
  }, [id]);
  useEffect(() => {
    if (!id || !latest || readCursor.current === `${id}:${latest}`) return;
    readCursor.current = `${id}:${latest}`;
    void write(`/conversations/${id}/read`)
      .then(() =>
        client.invalidateQueries({
          queryKey: ["list", "/conversations?scope=work"],
        }),
      )
      .catch(() => {
        readCursor.current = "";
      });
  }, [id, latest, client]);
  async function send() {
    const body = (drafts[id] || "").trim();
    if (!id || !body || sending || current?.read_only) return;
    if (
      !pendingInput.current ||
      pendingInput.current.body !== body ||
      pendingInput.current.conversation !== id
    )
      pendingInput.current = {
        id: crypto.randomUUID(),
        body,
        conversation: id,
      };
    const request = pendingInput.current;
    setSending(true);
    setSendError(null);
    try {
      await write(`/conversations/${id}/messages`, {
        id: request.id,
        body: request.body,
      });
      setDrafts((previous) => ({
        ...previous,
        [id]: previous[id] === body ? "" : previous[id],
      }));
      pendingInput.current = null;
      atBottom.current = true;
      await client.invalidateQueries({ queryKey: ["messages", id] });
      await client.invalidateQueries({
        queryKey: ["list", "/conversations?scope=work"],
      });
    } catch (caught) {
      setSendError(caught as Error);
    } finally {
      setSending(false);
    }
  }
  const serviceInfo = (
    <>
      <div className="service-info-heading">
        <Avatar
          name={text(service.data, "student_name") || text(current, "name")}
          size={52}
        />
        <h3>{text(service.data, "student_name") || text(current, "name")}</h3>
        <Status value={service.data?.status} />
      </div>
      <DetailList
        items={[
          { label: "服务人员", value: text(service.data, "staff_name") },
          { label: "创建时间", value: dateTime(service.data?.created_at) },
          {
            label: "服务方式",
            value: current?.kind === "care" ? "校内支持" : "同学交流",
          },
        ]}
      />
      {service.data?.appointment_id ? (
        <Link
          className="button"
          to={`/appointments?selected=${service.data.appointment_id}`}
        >
          打开预约详情 <ArrowUpRight size={15} />
        </Link>
      ) : null}
      {service.data?.help_id ? (
        <Link className="button" to={`/help?selected=${service.data.help_id}`}>
          查看求助记录 <ArrowUpRight size={15} />
        </Link>
      ) : null}
      <section className="shared-content">
        <h3>
          <FileText size={16} />
          学生分享的内容
        </h3>
        {Array.isArray(service.data?.shares) && service.data.shares.length ? (
          (service.data.shares as Row[]).map((share) => (
            <article key={share.id}>
              <p>{text(share, "body")}</p>
              <small>{dateTime(share.created_at)}</small>
            </article>
          ))
        ) : (
          <p className="muted">当前没有有效的分享资料。</p>
        )}
      </section>
      {text(service.data, "internal_note") && (
        <section className="shared-content">
          <h3>
            <LockKeyhole size={16} />
            内部服务记录
          </h3>
          <p>{text(service.data, "internal_note")}</p>
        </section>
      )}
      {text(service.data, "student_note") && (
        <section className="shared-content">
          <h3>给同学的安排</h3>
          <p>{text(service.data, "student_note")}</p>
        </section>
      )}
      {serviceId && (
        <Button
          onClick={() => {
            mutation.reset();
            setTransferOpen(true);
          }}
        >
          <Users size={16} />
          转交给心理老师
        </Button>
      )}
    </>
  );
  return (
    <>
      <PageHeader
        title="服务消息"
        description="接着上次的话题，认真听完这一次。"
      />
      <div className={`inbox-layout panel ${id ? "has-selection" : ""}`}>
        <aside className="conversation-list">
          <div className="conversation-search">
            <SearchInput
              value={search}
              onChange={setSearch}
              placeholder="搜索会话"
            />
          </div>
          <ErrorNotice
            error={conversations.error}
            retry={() => void conversations.refetch()}
          />
          {conversations.isLoading ? (
            <Loading rows={3} />
          ) : conversations.data?.items.length ? (
            conversations.data.items
              .filter((row) => text(row, "name").includes(search))
              .map((row) => (
                <button
                  className={`conversation-row ${id === row.id ? "selected" : ""}`}
                  key={row.id}
                  onClick={() => setParams({ selected: row.id })}
                >
                  <Avatar name={text(row, "name")} size={42} />
                  <div>
                    <div className="conversation-title">
                      <strong>{text(row, "name") || "服务会话"}</strong>
                      <time>{dateTime(row.updated_at, true)}</time>
                    </div>
                    <p>{text(row, "last_message") || "会话已建立"}</p>
                    <small>
                      {row.kind === "care" ? "校内服务" : "同学交流"}
                      {row.read_only ? " · 已结束" : ""}
                    </small>
                  </div>
                  {Number(row.unread) > 0 && (
                    <span className="unread-count">
                      {Math.min(Number(row.unread), 99)}
                    </span>
                  )}
                </button>
              ))
          ) : (
            <Empty
              title="暂无服务会话"
              description="预约确认后，双方会话将在这里出现。"
            />
          )}
        </aside>
        <section className="chat-pane">
          {current ? (
            <>
              <header className="chat-heading">
                <button
                  className="icon-button conversation-back"
                  aria-label="返回会话列表"
                  onClick={() => setParams({})}
                >
                  <ArrowLeft size={18} />
                </button>
                <Avatar name={text(current, "name")} />
                <div>
                  <strong>{text(current, "name") || "服务会话"}</strong>
                  <small>
                    {current.kind === "care"
                      ? "校内支持 · 服务会话"
                      : "同学交流"}
                  </small>
                </div>
                <button
                  className="icon-button info-toggle"
                  aria-label="查看服务资料"
                  onClick={() => setInfoOpen(true)}
                >
                  <Info size={19} />
                </button>
              </header>
              {current.appointment_id ? (
                <Link
                  className="appointment-banner"
                  to={`/appointments?selected=${current.appointment_id}`}
                >
                  <span>查看关联预约与接待安排</span>
                  <ChevronRight size={16} />
                </Link>
              ) : null}
              <div
                className="chat-messages"
                ref={scrollRef}
                onScroll={() => {
                  const box = scrollRef.current;
                  if (box)
                    atBottom.current =
                      box.scrollHeight - box.scrollTop - box.clientHeight < 90;
                }}
              >
                <ErrorNotice
                  error={messages.error || conversation.error}
                  retry={() => void messages.refetch()}
                />
                {messages.isLoading ? (
                  <Loading rows={3} />
                ) : !list.length ? (
                  <Empty
                    title="从一句问候开始"
                    description="你与同学的交流仅向参与本次服务的人员开放。"
                    icon={<MessageSquare size={26} />}
                  />
                ) : (
                  list.map((message) => (
                    <article
                      key={message.id}
                      className={`chat-message ${message.sender_id === user?.id ? "is-self" : ""}`}
                    >
                      <div className="message-meta">
                        <span>{text(message, "sender_name")}</span>
                        <time>{dateTime(message.created_at)}</time>
                      </div>
                      <div className="message-bubble">
                        {text(message, "body")}
                      </div>
                    </article>
                  ))
                )}
              </div>
              {current.read_only ? (
                <div className="readonly-message">
                  <LockKeyhole size={16} />
                  本次会话已结束，历史消息仍可查阅。
                </div>
              ) : (
                <form
                  className="message-composer"
                  onSubmit={(event) => {
                    event.preventDefault();
                    void send();
                  }}
                >
                  <ErrorNotice error={sendError} />
                  <textarea
                    aria-label="回复同学"
                    maxLength={2000}
                    placeholder="写下你的回复…"
                    value={drafts[id] || ""}
                    onChange={(event) =>
                      setDrafts((previous) => ({
                        ...previous,
                        [id]: event.target.value,
                      }))
                    }
                    onKeyDown={(event) => {
                      if (
                        event.key === "Enter" &&
                        !event.shiftKey &&
                        !event.nativeEvent.isComposing
                      ) {
                        event.preventDefault();
                        void send();
                      }
                    }}
                  />
                  <div>
                    <span>Enter 发送 · Shift + Enter 换行</span>
                    <Button
                      type="submit"
                      tone="primary"
                      disabled={!(drafts[id] || "").trim()}
                      busy={sending}
                    >
                      <Send size={16} />
                      发送
                    </Button>
                  </div>
                </form>
              )}
            </>
          ) : (
            <Empty
              title="选择一段会话"
              description="在左侧打开服务消息，继续与同学交流。"
              icon={<MessageSquare size={32} strokeWidth={1.3} />}
            />
          )}
        </section>
        {current && (
          <aside className="service-info">
            <ErrorNotice error={service.error} />
            {serviceInfo}
          </aside>
        )}
      </div>
      {infoOpen && (
        <Drawer title="本次服务" onClose={() => setInfoOpen(false)}>
          {serviceInfo}
        </Drawer>
      )}
      {transferOpen && (
        <Drawer
          title="转交服务"
          subtitle="接收老师确认后，服务负责人会更新。"
          onClose={() => setTransferOpen(false)}
          footer={
            <Button
              tone="primary"
              disabled={!target || !transferNote.trim()}
              busy={mutation.isPending}
              onClick={async () => {
                try {
                  await mutation.mutateAsync({
                    path: "/transfers",
                    data: {
                      service_id: serviceId,
                      staff_id: target,
                      note: transferNote,
                    },
                  });
                  setTransferOpen(false);
                  toast("转交申请已发送");
                } catch {
                  /* Inline error. */
                }
              }}
            >
              发送转交申请
            </Button>
          }
        >
          <ErrorNotice error={mutation.error || staff.error} />
          <Field label="接收老师" required>
            <select
              value={target}
              onChange={(event) => setTarget(event.target.value)}
            >
              <option value="">请选择心理老师</option>
              {staff.data?.items
                .filter((row) => row.id !== service.data?.staff_id)
                .map((row) => (
                  <option key={row.id} value={row.id}>
                    {text(row, "nickname")}
                  </option>
                ))}
            </select>
          </Field>
          <Field
            label="交接说明"
            required
            hint="说明需要老师接手的事项，学生的 AI 分享需要重新授权。"
          >
            <textarea
              rows={5}
              value={transferNote}
              onChange={(event) => setTransferNote(event.target.value)}
            />
          </Field>
        </Drawer>
      )}
    </>
  );
}
