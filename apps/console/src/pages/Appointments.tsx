import { useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { ChevronLeft, ChevronRight, Plus, Trash2 } from "lucide-react";
import { useList, useWrite } from "../lib/data";
import { useSession } from "../lib/session";
import { dateTime, localInput, text, type Row } from "../lib/api";
import {
  Button,
  DetailList,
  Drawer,
  EntityForm,
  ErrorNotice,
  Field,
  Loading,
  PageHeader,
  Person,
  SearchInput,
  Status,
  Table,
  Tabs,
  TimeCell,
  useToast,
} from "../components/ui";

export function AppointmentsPage() {
  const { user } = useSession();
  const [params, setParams] = useSearchParams();
  const [tab, setTab] = useState(params.get("tab") || "appointments");
  const [filter, setFilter] = useState("all");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<Row | null>(null);
  const [create, setCreate] = useState(false);
  const [action, setAction] = useState("");
  const [reason, setReason] = useState("");
  const [internalNote, setInternalNote] = useState("");
  const [studentNote, setStudentNote] = useState("");
  const [staffId, setStaffId] = useState("");
  const [weekOffset, setWeekOffset] = useState(0);
  const appointments = useList("/appointments?scope=work");
  const slots = useList("/slots?scope=work");
  const staff = useList("/staff");
  const mutation = useWrite();
  const toast = useToast();
  const isStaff = user?.roles.some((role) =>
    ["teacher", "peer"].includes(role),
  );
  const rows = appointments.data?.items || [];
  const effectiveSelected = selected
    ? rows.find((row) => row.id === selected.id) || selected
    : rows.find((row) => row.id === params.get("selected")) || null;
  const close = () => {
    setSelected(null);
    setAction("");
    mutation.reset();
    if (params.has("selected")) {
      const next = new URLSearchParams(params);
      next.delete("selected");
      setParams(next);
    }
  };
  const visible = rows.filter(
    (row) =>
      (filter === "all" || row.status === filter) &&
      `${text(row, "student_name")} ${text(row, "staff_name")}`.includes(query),
  );
  const weekStart = new Date();
  weekStart.setDate(
    weekStart.getDate() - ((weekStart.getDay() + 6) % 7) + weekOffset * 7,
  );
  weekStart.setHours(0, 0, 0, 0);
  const days = Array.from({ length: 7 }, (_, index) => {
    const date = new Date(weekStart);
    date.setDate(date.getDate() + index);
    return date;
  });
  async function runAction() {
    if (!effectiveSelected) return;
    try {
      await mutation.mutateAsync({
        path: `/appointments/${effectiveSelected.id}/${action}`,
        data: {
          reason,
          internal_note: internalNote,
          student_note: studentNote,
          staff_id: staffId || undefined,
        },
      });
      toast("预约状态已更新");
      setAction("");
      setReason("");
      setInternalNote("");
      setStudentNote("");
    } catch {
      /* Inline error remains visible. */
    }
  }
  return (
    <>
      <PageHeader
        title="预约与排班"
        description="把时间安排清楚，给每次见面留好位置。"
        action={
          isStaff && (
            <Button
              tone="primary"
              onClick={() => {
                mutation.reset();
                setCreate(true);
              }}
            >
              <Plus size={17} />
              发布可约时段
            </Button>
          )
        }
      />
      <Tabs
        value={tab}
        onChange={setTab}
        items={[
          { value: "appointments", label: "预约列表", count: rows.length },
          { value: "calendar", label: "每周安排" },
          ...(isStaff ? [{ value: "slots", label: "我的可约时间" }] : []),
        ]}
      />
      <ErrorNotice
        error={appointments.error || (tab === "slots" ? slots.error : null)}
        retry={() => {
          void appointments.refetch();
          void slots.refetch();
        }}
      />
      {tab === "appointments" && (
        <section className="panel">
          <div className="toolbar">
            <div className="filter-buttons">
              {[
                { value: "all", label: "全部预约" },
                { value: "pending", label: "待确认" },
                { value: "confirmed", label: "已确认" },
                { value: "in_progress", label: "服务中" },
                { value: "completed", label: "已完成" },
              ].map((item) => (
                <button
                  key={item.value}
                  className={filter === item.value ? "selected" : ""}
                  onClick={() => setFilter(item.value)}
                >
                  {item.label}
                </button>
              ))}
            </div>
            <SearchInput
              value={query}
              onChange={setQuery}
              placeholder="搜索同学或服务人员"
            />
          </div>
          {appointments.isLoading ? (
            <Loading />
          ) : (
            <Table
              rows={visible}
              onRow={setSelected}
              emptyTitle="还没有对应的预约"
              emptyDescription="学生提交申请后，会在这里等待你确认。"
              columns={[
                {
                  key: "student",
                  label: "预约同学",
                  render: (row) => <Person row={row} />,
                },
                {
                  key: "start",
                  label: "预约时间",
                  render: (row) => (
                    <TimeCell start={row.start_at} end={row.end_at} />
                  ),
                },
                { key: "staff_name", label: "接待人员" },
                {
                  key: "mode",
                  label: "方式",
                  render: (row) =>
                    row.mode === "onsite" ? "线下接待" : "线上交流",
                },
                {
                  key: "status",
                  label: "状态",
                  render: (row) => <Status value={row.status} />,
                },
              ]}
            />
          )}
        </section>
      )}
      {tab === "calendar" && (
        <section className="panel calendar-panel">
          <div className="toolbar">
            <h2>
              {dateTime(days[0].toISOString(), true)} —{" "}
              {dateTime(days[6].toISOString(), true)}
            </h2>
            <div className="button-group">
              <Button onClick={() => setWeekOffset(0)}>本周</Button>
              <button
                className="icon-button"
                aria-label="前一周"
                onClick={() => setWeekOffset(weekOffset - 1)}
              >
                <ChevronLeft size={18} />
              </button>
              <button
                className="icon-button"
                aria-label="后一周"
                onClick={() => setWeekOffset(weekOffset + 1)}
              >
                <ChevronRight size={18} />
              </button>
            </div>
          </div>
          <div className="week-grid">
            {days.map((day) => (
              <div className="day-column" key={day.toISOString()}>
                <header
                  className={
                    day.toDateString() === new Date().toDateString()
                      ? "today"
                      : ""
                  }
                >
                  <span>
                    {day.toLocaleDateString("zh-CN", { weekday: "short" })}
                  </span>
                  <strong>{day.getDate()}</strong>
                </header>
                <div>
                  {rows
                    .filter(
                      (row) =>
                        new Date(text(row, "start_at")).toDateString() ===
                        day.toDateString(),
                    )
                    .map((row) => (
                      <button
                        className="calendar-event"
                        key={row.id}
                        onClick={() => setSelected(row)}
                      >
                        <time>
                          {new Date(text(row, "start_at")).toLocaleTimeString(
                            "zh-CN",
                            { hour: "2-digit", minute: "2-digit" },
                          )}
                        </time>
                        <strong>{text(row, "student_name")}</strong>
                        <small>{text(row, "staff_name")}</small>
                        <Status value={row.status} />
                      </button>
                    ))}
                </div>
              </div>
            ))}
          </div>
        </section>
      )}
      {tab === "slots" && (
        <section className="panel">
          <div className="section-heading">
            <div>
              <h2>已发布的可约时间</h2>
              <p>被预约的时段保留，空闲时段可以撤下。</p>
            </div>
          </div>
          {slots.isLoading ? (
            <Loading />
          ) : (
            <Table
              rows={slots.data?.items || []}
              emptyTitle="还没有发布可约时间"
              emptyDescription="设置好接待时间，同学就能在 App 中预约你。"
              columns={[
                {
                  key: "start",
                  label: "开始与结束",
                  render: (row) => (
                    <TimeCell start={row.start_at} end={row.end_at} />
                  ),
                },
                {
                  key: "mode",
                  label: "接待方式",
                  render: (row) =>
                    row.mode === "onsite" ? "线下接待" : "线上交流",
                },
                {
                  key: "available",
                  label: "状态",
                  render: (row) => (
                    <span
                      className={`status status-${row.available ? "brand" : "muted"}`}
                    >
                      {row.available ? "可预约" : "已占用"}
                    </span>
                  ),
                },
                {
                  key: "action",
                  label: "操作",
                  render: (row) =>
                    row.available ? (
                      <Button
                        tone="ghost"
                        onClick={() => {
                          setSelected(row);
                          setAction("delete-slot");
                        }}
                      >
                        <Trash2 size={15} />
                        撤下时段
                      </Button>
                    ) : (
                      <span className="muted">已关联预约</span>
                    ),
                },
              ]}
            />
          )}
        </section>
      )}
      {create && (
        <Drawer
          title="发布可约时间"
          subtitle="同学可以通过 App 申请这个时段"
          onClose={() => setCreate(false)}
        >
          <EntityForm
            initial={{ start_at: localInput(), mode: "online" }}
            fields={[
              {
                name: "start_at",
                label: "开始时间",
                type: "datetime-local",
                required: true,
              },
              {
                name: "end_at",
                label: "结束时间",
                type: "datetime-local",
                hint: "留空时使用学校设置中的默认服务时长。",
              },
              {
                name: "mode",
                label: "接待方式",
                type: "select",
                required: true,
                options: [
                  { value: "online", label: "线上文字交流" },
                  { value: "onsite", label: "线下见面" },
                ],
              },
            ]}
            submitLabel="发布时段"
            pending={mutation.isPending}
            error={mutation.error}
            onSubmit={async (values) => {
              try {
                await mutation.mutateAsync({
                  path: "/slots",
                  data: {
                    ...values,
                    start_at: new Date(String(values.start_at)).toISOString(),
                    end_at: values.end_at
                      ? new Date(String(values.end_at)).toISOString()
                      : undefined,
                  },
                });
                setCreate(false);
                toast("可约时段已发布");
              } catch {
                /* Error shown in form. */
              }
            }}
          />
        </Drawer>
      )}
      {effectiveSelected && action !== "delete-slot" && (
        <Drawer
          title="预约详情"
          subtitle={text(effectiveSelected, "student_name")}
          onClose={close}
          footer={
            action ? (
              <>
                <Button onClick={() => setAction("")}>返回</Button>
                <Button
                  tone={
                    ["cancel", "reject"].includes(action) ? "danger" : "primary"
                  }
                  busy={mutation.isPending}
                  onClick={() => void runAction()}
                  disabled={
                    (["cancel", "reject"].includes(action) && !reason.trim()) ||
                    (action === "reassign" && !staffId)
                  }
                >
                  确认操作
                </Button>
              </>
            ) : (
              <div className="drawer-actions">
                {effectiveSelected.status === "pending" && (
                  <>
                    <Button onClick={() => setAction("reject")}>
                      拒绝申请
                    </Button>
                    <Button tone="primary" onClick={() => setAction("confirm")}>
                      确认预约
                    </Button>
                  </>
                )}
                {effectiveSelected.status === "confirmed" && (
                  <>
                    <Button onClick={() => setAction("cancel")}>
                      取消预约
                    </Button>
                    <Button onClick={() => setAction("no-show")}>
                      标记未到场
                    </Button>
                    <Button tone="primary" onClick={() => setAction("start")}>
                      开始服务
                    </Button>
                  </>
                )}
                {effectiveSelected.status === "in_progress" && (
                  <Button tone="primary" onClick={() => setAction("complete")}>
                    结束服务
                  </Button>
                )}
                {user?.roles.includes("admin") &&
                  ["pending", "confirmed"].includes(
                    text(effectiveSelected, "status"),
                  ) && (
                    <Button onClick={() => setAction("reassign")}>
                      重新分配
                    </Button>
                  )}
              </div>
            )
          }
        >
          <ErrorNotice error={mutation.error} />
          <div className="detail-status">
            <Status value={effectiveSelected.status} />
            {effectiveSelected.conversation_id ? (
              <Link
                className="text-button"
                to={`/inbox?selected=${effectiveSelected.conversation_id}`}
              >
                进入服务会话
              </Link>
            ) : null}
          </div>
          <DetailList
            items={[
              { label: "同学", value: text(effectiveSelected, "student_name") },
              {
                label: "接待人员",
                value: text(effectiveSelected, "staff_name"),
              },
              {
                label: "开始时间",
                value: dateTime(effectiveSelected.start_at),
              },
              { label: "结束时间", value: dateTime(effectiveSelected.end_at) },
              {
                label: "接待方式",
                value:
                  effectiveSelected.mode === "onsite" ? "线下接待" : "线上交流",
              },
              { label: "地点", value: text(effectiveSelected, "location") },
            ]}
          />
          {effectiveSelected.note ? (
            <div className="detail-note">
              <h3>同学的预约说明</h3>
              <p>{text(effectiveSelected, "note")}</p>
            </div>
          ) : null}
          {effectiveSelected.reason ? (
            <div className="detail-note">
              <h3>处理说明</h3>
              <p>{text(effectiveSelected, "reason")}</p>
            </div>
          ) : null}
          {action && (
            <div className="action-form">
              <h3>
                {
                  {
                    confirm: "确认这个预约",
                    reject: "说明拒绝原因",
                    cancel: "说明取消原因",
                    start: "准备开始服务",
                    complete: "记录本次服务结果",
                    "no-show": "确认同学未到场",
                    reassign: "选择接待人员",
                  }[action]
                }
              </h3>
              {["cancel", "reject", "no-show"].includes(action) && (
                <Field label="原因" required>
                  <textarea
                    rows={3}
                    value={reason}
                    onChange={(event) => setReason(event.target.value)}
                  />
                </Field>
              )}
              {action === "complete" && (
                <>
                  <Field label="内部服务记录" hint="仅授权工作人员可见。">
                    <textarea
                      rows={4}
                      value={internalNote}
                      onChange={(event) => setInternalNote(event.target.value)}
                    />
                  </Field>
                  <Field label="给同学的下一步安排">
                    <textarea
                      rows={3}
                      value={studentNote}
                      onChange={(event) => setStudentNote(event.target.value)}
                    />
                  </Field>
                  <p className="field-hint">结束后系统会发出关联回访。</p>
                </>
              )}
              {action === "reassign" && (
                <Field label="接待人员">
                  <select
                    value={staffId}
                    onChange={(event) => setStaffId(event.target.value)}
                  >
                    <option value="">选择人员</option>
                    {staff.data?.items.map((person) => (
                      <option key={person.id} value={person.id}>
                        {text(person, "nickname")}
                      </option>
                    ))}
                  </select>
                </Field>
              )}
            </div>
          )}
          {Array.isArray(effectiveSelected.history) && (
            <div className="timeline">
              <h3>预约进度</h3>
              {(effectiveSelected.history as Row[]).map((item, index) => (
                <div key={index}>
                  <span />
                  <section>
                    <strong>{text(item, "action")}</strong>
                    <p>{text(item, "note")}</p>
                    <small>{dateTime(item.created_at)}</small>
                  </section>
                </div>
              ))}
            </div>
          )}
        </Drawer>
      )}
      {selected && action === "delete-slot" && (
        <Drawer
          title="撤下可约时段"
          onClose={close}
          footer={
            <>
              <Button onClick={close}>保留</Button>
              <Button
                tone="danger"
                busy={mutation.isPending}
                onClick={async () => {
                  try {
                    await mutation.mutateAsync({
                      path: `/slots/${selected.id}`,
                      method: "DELETE",
                    });
                    close();
                    toast("时段已撤下");
                  } catch {
                    /* Inline error. */
                  }
                }}
              >
                确认撤下
              </Button>
            </>
          }
        >
          <ErrorNotice error={mutation.error} />
          <p>
            撤下 {dateTime(selected.start_at)}{" "}
            的时段后，同学将无法再预约该时间。
          </p>
        </Drawer>
      )}
    </>
  );
}
