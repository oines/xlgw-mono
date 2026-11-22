import { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { Check, Phone, Send, UserRoundCheck } from "lucide-react";
import { useSession } from "../lib/session";
import { useList, useObject, useWrite } from "../lib/data";
import { dateTime, text, type Row } from "../lib/api";
import {
  Button,
  DetailList,
  Drawer,
  Empty,
  ErrorNotice,
  Field,
  Loading,
  PageHeader,
  Person,
  SearchInput,
  Status,
  Table,
  Tabs,
  useToast,
} from "../components/ui";

const answerNames: Record<string, string> = {
  mood: "当前状态",
  helpfulness: "咨询帮助程度",
  recommendation: "推荐意愿",
  note: "其他反馈",
  contact_requested: "希望继续联系",
};
const answerValues: Record<string, string> = {
  better: "有所好转",
  same: "与之前相同",
  worse: "感到更困扰",
  helpful: "有帮助",
  neutral: "一般",
  unhelpful: "没有帮助",
  true: "是",
  false: "否",
};

export function FollowupsPage() {
  const { user } = useSession();
  const [params, setParams] = useSearchParams();
  const [filter, setFilter] = useState("all");
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState("");
  const [action, setAction] = useState("");
  const [note, setNote] = useState("");
  const [studentNote, setStudentNote] = useState("");
  const [staffId, setStaffId] = useState("");
  const list = useList("/followups?scope=work");
  const id = selectedId || params.get("selected") || "";
  const detail = useObject(`/followups/${id}`, Boolean(id));
  const staff = useList("/staff?role=teacher", action === "reassign");
  const mutation = useWrite();
  const toast = useToast();
  const row = detail.data || list.data?.items.find((item) => item.id === id);
  const rows = (list.data?.items || []).filter(
    (item) =>
      (filter === "all" || item.status === filter) &&
      `${text(item, "student_name")} ${text(item, "staff_name")}`.includes(
        query,
      ),
  );
  const close = () => {
    setSelectedId("");
    setParams({});
    setAction("");
    setNote("");
    setStudentNote("");
    mutation.reset();
  };
  const process = async () => {
    try {
      await mutation.mutateAsync({
        path: `/followups/${id}/${action}`,
        data: {
          note,
          student_note: studentNote,
          staff_id: staffId || undefined,
        },
      });
      toast(action === "resend" ? "回访通知已补发" : "回访处理已更新");
      setAction("");
      setNote("");
      setStudentNote("");
    } catch {
      /* Error shown beside form. */
    }
  };
  return (
    <>
      <PageHeader
        title="回访与跟进"
        description="服务之后的感受，也值得被认真听见。"
      />
      <Tabs
        value={filter}
        onChange={setFilter}
        items={[
          { value: "all", label: "全部回访" },
          { value: "pending_review", label: "等待查看" },
          { value: "pending_contact", label: "需要联系" },
          { value: "following", label: "跟进中" },
          { value: "closed", label: "已结案" },
        ]}
      />
      <ErrorNotice error={list.error} retry={() => void list.refetch()} />
      <section className="panel">
        <div className="toolbar">
          <p className="muted">提交问卷后，处理进度会持续保留。</p>
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="搜索同学或负责人员"
          />
        </div>
        {list.isLoading ? (
          <Loading />
        ) : (
          <Table
            rows={rows}
            emptyTitle="这里还没有回访"
            emptyDescription="完成一次人工服务后，系统会为同学创建回访问卷。"
            onRow={(item) => {
              setSelectedId(item.id);
              mutation.reset();
            }}
            columns={[
              {
                key: "student",
                label: "同学",
                render: (item) => <Person row={item} />,
              },
              { key: "staff_name", label: "负责人员" },
              {
                key: "submitted",
                label: "提交时间",
                render: (item) =>
                  item.submitted_at ? dateTime(item.submitted_at) : "尚未提交",
              },
              {
                key: "status",
                label: "处理状态",
                render: (item) => <Status value={item.status} />,
              },
            ]}
          />
        )}
      </section>
      {id && (
        <Drawer
          title="咨询回访"
          subtitle={text(row, "student_name")}
          onClose={close}
          footer={
            row &&
            (action ? (
              <>
                <Button onClick={() => setAction("")}>返回</Button>
                <Button
                  tone="primary"
                  busy={mutation.isPending}
                  disabled={
                    (action === "contact" && !note.trim()) ||
                    (action === "reassign" && !staffId)
                  }
                  onClick={() => void process()}
                >
                  确认{action === "resend" ? "补发" : "保存"}
                </Button>
              </>
            ) : (
              <div className="drawer-actions">
                {row.status === "awaiting" && (
                  <Button onClick={() => setAction("resend")}>
                    <Send size={15} />
                    补发通知
                  </Button>
                )}
                {row.submitted_at && row.status !== "closed" ? (
                  <>
                    <Button onClick={() => setAction("review")}>
                      标记已阅
                    </Button>
                    <Button tone="primary" onClick={() => setAction("contact")}>
                      <Phone size={15} />
                      记录联系
                    </Button>
                    <Button onClick={() => setAction("close")}>
                      <Check size={15} />
                      结案
                    </Button>
                  </>
                ) : null}
                {user?.roles.includes("admin") && row.status !== "closed" && (
                  <Button onClick={() => setAction("reassign")}>
                    重新分配
                  </Button>
                )}
              </div>
            ))
          }
        >
          <ErrorNotice error={detail.error || mutation.error} />
          {detail.isLoading ? (
            <Loading />
          ) : (
            row && (
              <>
                <div className="detail-status">
                  <Status value={row.status} />
                  <span className="muted">{dateTime(row.created_at)}</span>
                </div>
                <DetailList
                  items={[
                    { label: "同学", value: text(row, "student_name") },
                    { label: "负责人员", value: text(row, "staff_name") },
                    { label: "提交时间", value: dateTime(row.submitted_at) },
                  ]}
                />
                {row.answers && typeof row.answers === "object" ? (
                  <div className="answers">
                    {Object.entries(row.answers as Record<string, unknown>).map(
                      ([key, value]) => (
                        <div key={key}>
                          <h3>{answerNames[key] || key}</h3>
                          <p>
                            {answerValues[String(value)] ||
                              String(value || "未填写")}
                          </p>
                        </div>
                      ),
                    )}
                  </div>
                ) : (
                  <Empty
                    title="同学尚未提交回答"
                    description="可以补发一次通知，提醒同学有空时填写。"
                  />
                )}
                {action && (
                  <div className="action-form">
                    <h3>
                      {
                        {
                          review: "查看情况",
                          contact: "记录本次联系",
                          close: "完成本次跟进",
                          resend: "补发填写提醒",
                          reassign: "更新负责人员",
                        }[action]
                      }
                    </h3>
                    {action === "reassign" ? (
                      <Field label="负责老师">
                        <select
                          value={staffId}
                          onChange={(event) => setStaffId(event.target.value)}
                        >
                          <option value="">选择老师</option>
                          {staff.data?.items.map((item) => (
                            <option key={item.id} value={item.id}>
                              {text(item, "nickname")}
                            </option>
                          ))}
                        </select>
                      </Field>
                    ) : action !== "resend" ? (
                      <>
                        <Field label="处理记录" required={action === "contact"}>
                          <textarea
                            rows={4}
                            value={note}
                            onChange={(event) => setNote(event.target.value)}
                          />
                        </Field>
                        <Field label="发给同学的安排（选填）">
                          <textarea
                            rows={3}
                            value={studentNote}
                            onChange={(event) =>
                              setStudentNote(event.target.value)
                            }
                          />
                        </Field>
                      </>
                    ) : (
                      <p className="muted">
                        同学会收到指向原问卷的通知，已有回答和草稿会保留。
                      </p>
                    )}
                  </div>
                )}
                <History row={row} />
              </>
            )
          )}
        </Drawer>
      )}
    </>
  );
}

export function HelpPage() {
  const { user } = useSession();
  const [params, setParams] = useSearchParams();
  const canHandleHelp = Boolean(
    user?.roles.some((role) => ["teacher", "admin"].includes(role)),
  );
  const [tab, setTab] = useState(canHandleHelp ? "help" : "transfers");
  const [filter, setFilter] = useState("open");
  const [selected, setSelected] = useState<Row | null>(null);
  const [action, setAction] = useState("");
  const [note, setNote] = useState("");
  const [studentNote, setStudentNote] = useState("");
  const [staffId, setStaffId] = useState("");
  const help = useList("/help-requests?scope=work", canHandleHelp);
  const transfers = useList("/transfers");
  const staff = useList("/staff?role=teacher", action === "assign");
  const mutation = useWrite();
  const toast = useToast();
  const helpRows = help.data?.items || [];
  const transferRows = transfers.data?.items || [];
  const row = selected
    ? (tab === "transfers" ? transferRows : helpRows).find(
        (item) => item.id === selected.id,
      ) || selected
    : [...helpRows, ...transferRows].find(
        (item) => item.id === params.get("selected"),
      );
  const isTransfer = Boolean(row && "from_id" in row);
  const close = () => {
    setSelected(null);
    setParams({});
    setAction("");
    setNote("");
    setStudentNote("");
    mutation.reset();
  };
  const process = async () => {
    if (!row) return;
    try {
      await mutation.mutateAsync({
        path: `/${isTransfer ? "transfers" : "help-requests"}/${row.id}/${action}`,
        data: {
          staff_id: staffId || undefined,
          note,
          student_note: studentNote,
        },
      });
      toast("处理进度已更新");
      setAction("");
      setNote("");
      setStudentNote("");
    } catch {
      /* Inline error. */
    }
  };
  const rows = (tab === "transfers" ? transferRows : helpRows).filter(
    (item) =>
      filter === "all" ||
      !["closed", "accepted", "rejected"].includes(text(item, "status")),
  );
  return (
    <>
      <PageHeader
        title={canHandleHelp ? "人工求助" : "服务转交"}
        description="从接收请求，到联系和回应，让每件事情都有负责人。"
      />
      <Tabs
        value={tab}
        onChange={setTab}
        items={[
          ...(canHandleHelp
            ? [
                {
                  value: "help",
                  label: "联系请求",
                  count: helpRows.filter((item) => item.status !== "closed")
                    .length,
                },
              ]
            : []),
          {
            value: "transfers",
            label: "服务转交",
            count: transferRows.filter((item) => item.status === "pending")
              .length,
          },
        ]}
      />
      <ErrorNotice
        error={help.error || transfers.error}
        retry={() => {
          void help.refetch();
          void transfers.refetch();
        }}
      />
      <section className="panel">
        <div className="toolbar">
          <div className="filter-buttons">
            <button
              className={filter === "open" ? "selected" : ""}
              onClick={() => setFilter("open")}
            >
              未结束
            </button>
            <button
              className={filter === "all" ? "selected" : ""}
              onClick={() => setFilter("all")}
            >
              全部记录
            </button>
          </div>
        </div>
        {help.isLoading || transfers.isLoading ? (
          <Loading />
        ) : (
          <Table
            rows={rows}
            emptyTitle={
              tab === "transfers"
                ? "暂无待接收的转交"
                : "当前没有待处理的联系请求"
            }
            emptyDescription="新的请求会显示在这里，请留意工作通知。"
            onRow={(item) => {
              setSelected(item);
              mutation.reset();
            }}
            columns={[
              {
                key: "student",
                label: "同学",
                render: (item) => <Person row={item} />,
              },
              {
                key: "body",
                label: tab === "transfers" ? "转交说明" : "联系说明",
                render: (item) => (
                  <span className="truncate-cell">
                    {text(item, "body", "note") || "—"}
                  </span>
                ),
              },
              {
                key: "staff",
                label: tab === "transfers" ? "接收人" : "负责人员",
                render: (item) =>
                  text(item, "staff_name", "to_name") || "等待分配",
              },
              {
                key: "created",
                label: "提交时间",
                render: (item) => dateTime(item.created_at),
              },
              {
                key: "status",
                label: "状态",
                render: (item) => <Status value={item.status} />,
              },
            ]}
          />
        )}
      </section>
      {row && (
        <Drawer
          title={isTransfer ? "服务转交" : "联系请求"}
          subtitle={text(row, "student_name")}
          onClose={close}
          footer={
            action ? (
              <>
                <Button onClick={() => setAction("")}>返回</Button>
                <Button
                  tone="primary"
                  busy={mutation.isPending}
                  onClick={() => void process()}
                  disabled={
                    (action === "assign" && !staffId) ||
                    (action === "contact" && !note.trim())
                  }
                >
                  确认{action === "accept" ? "接收" : "保存"}
                </Button>
              </>
            ) : (
              <div className="drawer-actions">
                {isTransfer &&
                  row.status === "pending" &&
                  (row.to_id === user?.id || user?.roles.includes("admin")) && (
                    <>
                      <Button onClick={() => setAction("reject")}>
                        拒绝转交
                      </Button>
                      <Button
                        tone="primary"
                        onClick={() => setAction("accept")}
                      >
                        接收服务
                      </Button>
                    </>
                  )}
                {!isTransfer && row.status !== "closed" && (
                  <>
                    {user?.roles.includes("admin") && (
                      <Button onClick={() => setAction("assign")}>
                        <UserRoundCheck size={15} />
                        分配老师
                      </Button>
                    )}
                    {user?.roles.includes("teacher") &&
                      row.status === "assigned" && (
                        <Button
                          tone="primary"
                          onClick={() => setAction("claim")}
                        >
                          认领请求
                        </Button>
                      )}
                    {["assigned", "contacting"].includes(
                      text(row, "status"),
                    ) && (
                      <>
                        <Button
                          tone="primary"
                          onClick={() => setAction("contact")}
                        >
                          <Phone size={15} />
                          记录联系
                        </Button>
                        <Button onClick={() => setAction("close")}>结案</Button>
                      </>
                    )}
                  </>
                )}
              </div>
            )
          }
        >
          <ErrorNotice error={mutation.error} />
          <div className="detail-status">
            <Status value={row.status} />
            {row.conversation_id ? (
              <Link
                className="text-button"
                to={`/inbox?selected=${row.conversation_id}`}
              >
                打开服务会话
              </Link>
            ) : null}
          </div>
          <DetailList
            items={[
              { label: "同学", value: text(row, "student_name") },
              { label: "联系方式", value: text(row, "contact") },
              { label: "方便联系时间", value: text(row, "preferred_time") },
              {
                label: isTransfer ? "转出人员" : "负责人员",
                value: text(row, "staff_name", "from_name") || "等待分配",
              },
              ...(isTransfer
                ? [{ label: "接收人员", value: text(row, "to_name") }]
                : []),
              { label: "提交时间", value: dateTime(row.created_at) },
            ]}
          />
          <div className="detail-note">
            <h3>{isTransfer ? "交接说明" : "同学想说的话"}</h3>
            <p>{text(row, "body", "note")}</p>
          </div>
          {action && (
            <div className="action-form">
              <h3>
                {
                  {
                    assign: "安排负责老师",
                    claim: "认领这项请求",
                    contact: "记录联系结果",
                    close: "结束本次跟进",
                    accept: "接收这项服务",
                    reject: "说明拒绝原因",
                  }[action]
                }
              </h3>
              {action === "assign" && (
                <Field label="负责老师">
                  <select
                    value={staffId}
                    onChange={(event) => setStaffId(event.target.value)}
                  >
                    <option value="">请选择老师</option>
                    {staff.data?.items.map((person) => (
                      <option key={person.id} value={person.id}>
                        {text(person, "nickname")}
                      </option>
                    ))}
                  </select>
                </Field>
              )}
              <Field label="处理说明" required={action === "contact"}>
                <textarea
                  rows={4}
                  value={note}
                  onChange={(event) => setNote(event.target.value)}
                />
              </Field>
              {!isTransfer && (
                <Field label="发给同学的安排（选填）">
                  <textarea
                    rows={3}
                    value={studentNote}
                    onChange={(event) => setStudentNote(event.target.value)}
                  />
                </Field>
              )}
            </div>
          )}
          <History row={row} />
        </Drawer>
      )}
    </>
  );
}

function History({ row }: { row: Row }) {
  if (!Array.isArray(row.history) || !row.history.length) return null;
  return (
    <div className="timeline">
      <h3>处理记录</h3>
      {(row.history as Row[]).map((item, index) => (
        <div key={index}>
          <span />
          <section>
            <strong>
              {text(item, "actor_name") || "工作人员"} · {text(item, "action")}
            </strong>
            {item.note ? <p>{text(item, "note")}</p> : null}
            {item.student_note ? (
              <p className="student-note">
                给同学的安排 · {text(item, "student_note")}
              </p>
            ) : null}
            <small>{dateTime(item.created_at)}</small>
          </section>
        </div>
      ))}
    </div>
  );
}
