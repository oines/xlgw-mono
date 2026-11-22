import React, { type ReactNode } from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter, Navigate, Route, Routes, Link } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ArrowRight, LoaderCircle, LockKeyhole, Waves } from "lucide-react";
import { SessionProvider, useSession } from "./lib/session";
import { Button, Empty, ErrorNotice, ToastProvider } from "./components/ui";
import { Layout } from "./components/Layout";
import { LoginPage } from "./pages/Login";
import { Dashboard } from "./pages/Dashboard";
import { AppointmentsPage } from "./pages/Appointments";
import { InboxPage } from "./pages/Inbox";
import { FollowupsPage, HelpPage } from "./pages/CareTasks";
import { PeoplePage } from "./pages/People";
import { ModerationPage } from "./pages/Moderation";
import { ResourcesPage } from "./pages/Resources";
import { StatisticsPage } from "./pages/Statistics";
import { ModelsPage } from "./pages/Models";
import { ProfilePage, SettingsPage } from "./pages/Settings";
import "./styles.css";

const client = new QueryClient({
  defaultOptions: {
    queries: { retry: 1, staleTime: 15000, refetchOnWindowFocus: true },
    mutations: { retry: false },
  },
});

function AdminOnly({ children }: { children: ReactNode }) {
  const { user } = useSession();
  if (!user?.roles.includes("admin"))
    return (
      <Empty
        title="该页面需要运营权限"
        description="你的接待与回访入口仍然可以正常使用。"
        icon={<LockKeyhole size={28} />}
        action={
          <Link to="/" className="button">
            返回工作概览
          </Link>
        }
      />
    );
  return children;
}

function App() {
  const { user, loading, error, refresh, logout, school } = useSession();
  if (loading)
    return (
      <div className="boot-screen">
        <Waves size={32} />
        <h1>心灵港湾</h1>
        <LoaderCircle className="spin" size={21} />
        <p>正在连接工作空间</p>
      </div>
    );
  if (error && !user)
    return (
      <div className="connection-error-page">
        <Waves size={32} />
        <h1>暂时无法连接工作空间</h1>
        <p>请检查服务是否已启动，然后重新连接。</p>
        <ErrorNotice error={error} />
        <Button tone="primary" onClick={refresh}>
          重新连接
        </Button>
      </div>
    );
  if (!user) return <LoginPage />;
  if (!user.roles.some((role) => ["teacher", "peer", "admin"].includes(role)))
    return (
      <div className="connection-error-page">
        <LockKeyhole size={32} />
        <h1>当前账号属于学生空间</h1>
        <p>
          请使用心灵港湾 App
          访问个人服务。若需要工作人员身份，请联系学校管理人员。
        </p>
        {school?.contact && <p>{school.contact}</p>}
        <Button onClick={() => void logout()}>
          退出并使用工作账号登录 <ArrowRight size={16} />
        </Button>
      </div>
    );
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Dashboard />} />
        <Route path="appointments" element={<AppointmentsPage />} />
        <Route path="inbox" element={<InboxPage />} />
        <Route path="followups" element={<FollowupsPage />} />
        <Route path="help" element={<HelpPage />} />
        <Route
          path="people"
          element={
            <AdminOnly>
              <PeoplePage />
            </AdminOnly>
          }
        />
        <Route
          path="moderation"
          element={
            <AdminOnly>
              <ModerationPage />
            </AdminOnly>
          }
        />
        <Route
          path="resources"
          element={
            <AdminOnly>
              <ResourcesPage />
            </AdminOnly>
          }
        />
        <Route
          path="statistics"
          element={
            <AdminOnly>
              <StatisticsPage />
            </AdminOnly>
          }
        />
        <Route
          path="models"
          element={
            <AdminOnly>
              <ModelsPage />
            </AdminOnly>
          }
        />
        <Route
          path="settings"
          element={
            <AdminOnly>
              <SettingsPage />
            </AdminOnly>
          }
        />
        <Route path="profile" element={<ProfilePage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={client}>
      <BrowserRouter>
        <SessionProvider>
          <ToastProvider>
            <App />
          </ToastProvider>
        </SessionProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>,
);
