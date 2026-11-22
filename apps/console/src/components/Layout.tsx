import { useState } from "react";
import { NavLink, Outlet, useNavigate } from "react-router-dom";
import {
  BarChart3,
  Bell,
  CalendarDays,
  ChevronDown,
  CircleHelp,
  ClipboardCheck,
  HeartHandshake,
  LayoutDashboard,
  LogOut,
  Menu,
  MessageSquare,
  Settings2,
  ShieldCheck,
  Users,
  Waves,
  BookOpen,
  Cpu,
} from "lucide-react";
import { useSession } from "../lib/session";
import { useList, useWrite } from "../lib/data";
import { dateTime, roles, text, type Row } from "../lib/api";
import { Avatar, Button, Drawer, Empty, ErrorNotice, useToast } from "./ui";

const links = [
  { path: "/", name: "工作概览", icon: LayoutDashboard, group: "接待与服务" },
  { path: "/appointments", name: "预约与排班", icon: CalendarDays },
  { path: "/inbox", name: "服务消息", icon: MessageSquare },
  { path: "/followups", name: "回访与跟进", icon: ClipboardCheck },
  { path: "/help", name: "人工求助", icon: HeartHandshake },
  {
    path: "/people",
    name: "成员与人员",
    icon: Users,
    admin: true,
    group: "校园运营",
  },
  { path: "/moderation", name: "社区与反馈", icon: ShieldCheck, admin: true },
  { path: "/resources", name: "内容与活动", icon: BookOpen, admin: true },
  { path: "/statistics", name: "使用与服务统计", icon: BarChart3, admin: true },
  {
    path: "/models",
    name: "模型与用量",
    icon: Cpu,
    admin: true,
    group: "系统管理",
  },
  { path: "/settings", name: "学校设置", icon: Settings2, admin: true },
  {
    path: "/profile",
    name: "我的接待资料",
    icon: CircleHelp,
    staff: true,
    group: "个人",
  },
];

export function Layout() {
  const { user, school, logout } = useSession();
  const [mobileOpen, setMobileOpen] = useState(false);
  const [notificationsOpen, setNotificationsOpen] = useState(false);
  const [accountOpen, setAccountOpen] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const notifications = useList("/notifications?scope=work", true, true);
  const mutation = useWrite();
  const navigate = useNavigate();
  const toast = useToast();
  const admin = user?.roles.includes("admin");
  const staff = user?.roles.some((role) => ["teacher", "peer"].includes(role));
  const unseen =
    notifications.data?.items.filter((item) => !item.read).length ?? 0;
  const visibleLinks = links.filter(
    (link) => (!link.admin || admin) && (!link.staff || staff),
  );
  const currentRoles = user?.roles
    .filter((role) => role !== "student")
    .map((role) => roles[role] || role)
    .join(" / ");
  async function openNotification(item: Row) {
    try {
      if (!item.read)
        await mutation.mutateAsync({ path: `/notifications/${item.id}/read` });
      setNotificationsOpen(false);
      const type = text(item, "target_type");
      const target = text(item, "target_id");
      const routes: Record<string, string> = {
        appointment: "/appointments",
        followup: "/followups",
        help_request: "/help",
        transfer: "/help",
        conversation: "/inbox",
        feedback: "/moderation",
        report: "/moderation",
      };
      navigate(
        `${routes[type] || "/"}${target ? `?selected=${encodeURIComponent(target)}` : ""}`,
      );
    } catch (caught) {
      setError(caught as Error);
    }
  }
  return (
    <div className="app-shell">
      {mobileOpen && (
        <button
          className="nav-backdrop"
          aria-label="关闭导航"
          onClick={() => setMobileOpen(false)}
        />
      )}
      <aside className={`sidebar ${mobileOpen ? "is-open" : ""}`}>
        <NavLink to="/" className="brand" onClick={() => setMobileOpen(false)}>
          <span className="brand-mark">
            <Waves size={24} />
          </span>
          <span>
            <strong>心灵港湾</strong>
            <small>校园支持工作台</small>
          </span>
        </NavLink>
        <nav aria-label="主导航">
          {visibleLinks.map((link, index) => (
            <div key={link.path}>
              {(link.group || index === 0) && (
                <div className="nav-section">{link.group}</div>
              )}
              <NavLink
                to={link.path}
                end={link.path === "/"}
                onClick={() => setMobileOpen(false)}
                className={({ isActive }) =>
                  `nav-item ${isActive ? "active" : ""}`
                }
              >
                <link.icon size={19} strokeWidth={1.7} />
                <span>
                  {link.path === "/help" &&
                  !user?.roles.some((role) =>
                    ["teacher", "admin"].includes(role),
                  )
                    ? "服务转交"
                    : link.name}
                </span>
              </NavLink>
            </div>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="school-monogram">
            {(school?.name || "校").slice(0, 1)}
          </div>
          <div>
            <strong>{school?.name || "学校工作空间"}</strong>
            <small>校内支持与陪伴</small>
          </div>
        </div>
      </aside>
      <div className="main-shell">
        <header className="topbar">
          <div className="topbar-left">
            <button
              className="icon-button nav-toggle"
              aria-label="打开导航"
              onClick={() => setMobileOpen(true)}
            >
              <Menu size={21} />
            </button>
            <span className="workspace-name">{school?.name || "心灵港湾"}</span>
            <span className="topbar-divider" />
            <span className="topbar-label">工作空间</span>
          </div>
          <div className="topbar-actions">
            <button
              className="icon-button notification-trigger"
              aria-label={`工作通知${unseen ? `，${unseen}条未读` : ""}`}
              onClick={() => setNotificationsOpen(true)}
            >
              <Bell size={19} />
              {unseen > 0 && <span className="unread-dot" />}
            </button>
            <div className="account-menu">
              <button
                className="account-trigger"
                onClick={() => setAccountOpen(!accountOpen)}
                aria-expanded={accountOpen}
              >
                <Avatar name={user?.nickname || ""} size={32} />
                <span>
                  <strong>{user?.nickname}</strong>
                  <small>{currentRoles}</small>
                </span>
                <ChevronDown size={14} />
              </button>
              {accountOpen && (
                <div className="account-popover">
                  <strong>{user?.account}</strong>
                  <small>{currentRoles}</small>
                  {
                    <Button
                      tone="ghost"
                      onClick={() => {
                        navigate("/profile");
                        setAccountOpen(false);
                      }}
                    >
                      接待资料与账号设置
                    </Button>
                  }
                  <Button
                    tone="ghost"
                    onClick={async () => {
                      try {
                        await logout();
                        toast("已退出登录");
                      } catch (caught) {
                        setError(caught as Error);
                      }
                    }}
                  >
                    <LogOut size={15} />
                    退出登录
                  </Button>
                </div>
              )}
            </div>
          </div>
        </header>
        <main id="main-content" className="page-content">
          <ErrorNotice error={error} />
          <Outlet />
        </main>
        <footer className="app-footer">
          <span>心灵港湾 · 校园支持</span>
          <span>让每一次需要，都有人回应</span>
        </footer>
      </div>
      {notificationsOpen && (
        <Drawer
          title="工作通知"
          subtitle={unseen ? `${unseen} 条未读通知` : "预约、回访与服务进展"}
          onClose={() => setNotificationsOpen(false)}
          footer={
            <Button
              disabled={!unseen}
              busy={mutation.isPending}
              onClick={async () => {
                try {
                  await mutation.mutateAsync({
                    path: "/notifications/read-all",
                    data: { scope: "work" },
                  });
                } catch (caught) {
                  setError(caught as Error);
                }
              }}
            >
              全部标为已读
            </Button>
          }
        >
          <ErrorNotice
            error={notifications.error}
            retry={() => void notifications.refetch()}
          />
          {notifications.data?.items.length ? (
            <div className="notification-list">
              {notifications.data.items.map((item) => (
                <button
                  key={item.id}
                  className={`notification-item ${item.read ? "" : "is-unread"}`}
                  onClick={() => void openNotification(item)}
                >
                  <span className="notification-dot" />
                  <div>
                    <strong>{text(item, "title")}</strong>
                    <p>{text(item, "body")}</p>
                    <time>{dateTime(item.created_at)}</time>
                  </div>
                </button>
              ))}
            </div>
          ) : (
            <Empty
              title="暂无工作通知"
              description="收到预约或回访后，会在这里提醒你。"
            />
          )}
        </Drawer>
      )}
    </div>
  );
}
