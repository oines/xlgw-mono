import { Link } from "react-router-dom";
import {
  ArrowRight,
  CalendarDays,
  ChevronRight,
  ClipboardCheck,
  HeartHandshake,
  MessageSquare,
  Plus,
} from "lucide-react";
import { useSession } from "../lib/session";
import { useList, useObject } from "../lib/data";
import { dateTime, text, type Row } from "../lib/api";
import {
  Avatar,
  Empty,
  ErrorNotice,
  Loading,
  PageHeader,
  Status,
} from "../components/ui";

export function Dashboard() {
  const { user, school } = useSession();
  const appointments = useList("/appointments?scope=work");
  const followups = useList("/followups?scope=work");
  const canHandleHelp = Boolean(
    user?.roles.some((role) => ["teacher", "admin"].includes(role)),
  );
  const help = useList("/help-requests?scope=work", canHandleHelp);
  const transfers = useList("/transfers");
  const admin = user?.roles.includes("admin");
  const isStaff = user?.roles.some((role) =>
    ["teacher", "peer"].includes(role),
  );
  const stats = useObject<Record<string, unknown>>(
    "/admin/stats",
    Boolean(admin),
  );
  const today = new Date().toLocaleDateString("zh-CN", {
    month: "long",
    day: "numeric",
    weekday: "long",
  });
  const todayKey = new Date().toDateString();
  const todayAppointments =
    appointments.data?.items.filter(
      (item) =>
        new Date(text(item, "start_at")).toDateString() === todayKey &&
        !["canceled", "rejected", "expired"].includes(text(item, "status")),
    ) ?? [];
  const tasks: (Row & { taskType: string; path: string })[] = [
    ...(appointments.data?.items
      .filter((item) => item.status === "pending")
      .map((item) => ({
        ...item,
        taskType: "预约申请",
        path: "/appointments",
      })) || []),
    ...(followups.data?.items
      .filter((item) =>
        ["pending_review", "pending_contact", "following"].includes(
          text(item, "status"),
        ),
      )
      .map((item) => ({ ...item, taskType: "咨询回访", path: "/followups" })) ||
      []),
    ...(help.data?.items
      .filter((item) => item.status !== "closed")
      .map((item) => ({ ...item, taskType: "人工求助", path: "/help" })) || []),
    ...(transfers.data?.items
      .filter((item) => item.status === "pending")
      .map((item) => ({ ...item, taskType: "服务转交", path: "/help" })) || []),
  ];
  const loading =
    appointments.isLoading || followups.isLoading || help.isLoading;
  const metrics = [
    {
      label: "今日预约",
      value: appointments.data ? todayAppointments.length : undefined,
      icon: CalendarDays,
      caption: "与你相关的今日安排",
    },
    {
      label: "待确认申请",
      value: appointments.data?.items.filter(
        (item) => item.status === "pending",
      ).length,
      icon: MessageSquare,
      caption: "等待工作人员确认",
    },
    {
      label: "回访待处理",
      value: followups.data?.items.filter((item) =>
        ["pending_review", "pending_contact", "following"].includes(
          text(item, "status"),
        ),
      ).length,
      icon: ClipboardCheck,
      caption: "来自服务后的真实反馈",
    },
    {
      label: canHandleHelp ? "人工联系" : "待接收转交",
      value: canHandleHelp
        ? help.data?.items.filter((item) => item.status !== "closed").length
        : transfers.data?.items.filter(
            (item) => item.status === "pending" && item.to_id === user?.id,
          ).length,
      icon: HeartHandshake,
      caption: "保持跟进，直到有回应",
    },
  ];
  return (
    <>
      <PageHeader
        title={`${user?.nickname || "你好"}，工作顺利`}
        description="从眼前的一件小事开始，让每份关心都有着落。"
        eyebrow={today}
        action={
          <Link
            className="button button-primary"
            to={isStaff ? "/appointments?tab=slots" : "/people"}
          >
            <Plus size={17} />
            {isStaff ? "安排可约时间" : "管理服务人员"}
          </Link>
        }
      />
      <ErrorNotice
        error={
          appointments.error || followups.error || help.error || transfers.error
        }
        retry={() => {
          void appointments.refetch();
          void followups.refetch();
          void help.refetch();
          void transfers.refetch();
        }}
      />
      <section className="metrics-grid" aria-label="服务概况">
        {metrics.map((item) => (
          <div className="metric" key={item.label}>
            <div className="metric-label">
              <span>{item.label}</span>
              <item.icon size={18} />
            </div>
            <strong className="metric-value">{item.value ?? "—"}</strong>
            <small>{item.caption}</small>
          </div>
        ))}
      </section>
      <div className="dashboard-grid">
        <section className="panel task-panel">
          <div className="section-heading">
            <div>
              <h2>需要你留意</h2>
              <p>预约、回访和联系请求，集中在这里。</p>
            </div>
            <span className="count-label">{tasks.length} 项</span>
          </div>
          {loading ? (
            <Loading />
          ) : tasks.length ? (
            <div className="task-list">
              {tasks.slice(0, 8).map((task) => (
                <Link
                  key={`${task.taskType}-${task.id}`}
                  className="task-item"
                  to={`${task.path}?selected=${task.id}`}
                >
                  <Avatar
                    name={text(task, "student_name", "from_name")}
                    size={40}
                  />
                  <div className="task-main">
                    <div>
                      <strong>
                        {text(task, "student_name") || "服务请求"}
                      </strong>
                      <span className="task-type">{task.taskType}</span>
                    </div>
                    <p>
                      {text(task, "note", "body") ||
                        (task.start_at
                          ? dateTime(task.start_at)
                          : "查看详情并处理")}
                    </p>
                  </div>
                  <Status value={task.status} />
                  <ChevronRight size={17} />
                </Link>
              ))}
            </div>
          ) : (
            <Empty
              title="当前没有待处理事项"
              description="新的预约、回访和求助会出现在这里。"
              action={
                <Link className="text-button" to="/appointments">
                  查看预约安排 <ArrowRight size={15} />
                </Link>
              }
            />
          )}
        </section>
        <aside className="dashboard-aside">
          <section className="panel agenda-panel">
            <div className="section-heading">
              <h2>今天的安排</h2>
              <Link
                to="/appointments"
                className="icon-button"
                aria-label="查看所有预约"
              >
                <ArrowRight size={17} />
              </Link>
            </div>
            {todayAppointments.length ? (
              <div className="agenda-list">
                {todayAppointments.map((item) => (
                  <Link key={item.id} to={`/appointments?selected=${item.id}`}>
                    <time>
                      {new Date(text(item, "start_at")).toLocaleTimeString(
                        "zh-CN",
                        { hour: "2-digit", minute: "2-digit" },
                      )}
                    </time>
                    <div>
                      <strong>{text(item, "student_name")}</strong>
                      <small>
                        {item.mode === "onsite" ? "线下接待" : "线上交流"}
                      </small>
                    </div>
                    <Status value={item.status} />
                  </Link>
                ))}
              </div>
            ) : (
              <div className="agenda-empty">
                <CalendarDays size={25} strokeWidth={1.4} />
                <p>今天暂无预约</p>
                <small>你可以提前安排接下来的时间。</small>
              </div>
            )}
          </section>
          <section className="school-note">
            <span className="note-label">校内服务</span>
            <h3>{school?.name || "学校服务信息"}</h3>
            <p>{school?.service_hours || "服务时间尚未设置"}</p>
            {school?.contact && <p>{school.contact}</p>}
            <Link to={admin ? "/settings" : "/profile"} className="text-button">
              {admin ? "管理服务信息" : "我的接待资料"} <ArrowRight size={15} />
            </Link>
          </section>
        </aside>
      </div>
      {admin && (
        <section className="panel operating-overview">
          <div className="section-heading">
            <div>
              <h2>校园使用概况</h2>
              <p>来自真实账号和业务记录。</p>
            </div>
          </div>
          <ErrorNotice error={stats.error} retry={() => void stats.refetch()} />
          <div className="stat-strip">
            {[
              { label: "注册人数", key: "registered" },
              { label: "活跃人数", key: "active" },
              { label: "AI 对话输入", key: "ai_inputs" },
              { label: "完成的服务", key: "appointments_completed" },
            ].map((item) => (
              <div key={item.key}>
                <span>{item.label}</span>
                <strong>
                  {stats.data?.[item.key] === undefined
                    ? "—"
                    : String(stats.data[item.key])}
                </strong>
              </div>
            ))}
          </div>
        </section>
      )}
    </>
  );
}
