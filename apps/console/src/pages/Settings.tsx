import { useState } from "react";
import { Building2, LockKeyhole, UserRound } from "lucide-react";
import { useObject, useWrite } from "../lib/data";
import { useSession } from "../lib/session";
import { text } from "../lib/api";
import {
  EntityForm,
  ErrorNotice,
  Loading,
  PageHeader,
  useToast,
} from "../components/ui";

export function SettingsPage() {
  const settings = useObject("/admin/settings");
  const mutation = useWrite();
  const toast = useToast();
  const [savedAt, setSavedAt] = useState("");
  return (
    <>
      <PageHeader
        title="学校设置"
        description="同学看到的服务信息，与工作人员共同使用的默认规则。"
      />
      <ErrorNotice
        error={settings.error}
        retry={() => void settings.refetch()}
      />
      {settings.isLoading ? (
        <Loading />
      ) : (
        settings.data && (
          <section className="settings-layout">
            <aside className="settings-intro">
              <Building2 size={30} strokeWidth={1.4} />
              <h2>学校的服务信息</h2>
              <p>
                联系方式、接待时间与地点会展示在学生 App。请保持真实、清楚。
              </p>
              {savedAt && <small>最近保存于 {savedAt}</small>}
            </aside>
            <div className="panel settings-form">
              <EntityForm
                initial={settings.data}
                error={mutation.error}
                pending={mutation.isPending}
                fields={[
                  { name: "name", label: "学校名称", required: true },
                  { name: "intro", label: "服务介绍", type: "textarea" },
                  {
                    name: "logo_url",
                    label: "学校 Logo 链接（选填）",
                    type: "url",
                  },
                  { name: "location", label: "服务地点" },
                  { name: "contact", label: "联系信息" },
                  {
                    name: "service_hours",
                    label: "服务时间",
                    hint: "例如：周一至周五 09:00–12:00、14:00–17:00。",
                  },
                  {
                    name: "timezone",
                    label: "时区",
                    required: true,
                    hint: "使用 IANA 时区，如 Asia/Shanghai。",
                  },
                  {
                    name: "registered_open",
                    label: "允许学生注册",
                    type: "checkbox",
                  },
                  {
                    name: "registration_mode",
                    label: "学生注册方式",
                    type: "select",
                    required: true,
                    options: [
                      { value: "open", label: "开放注册" },
                      { value: "invite", label: "凭学校邀请码注册" },
                    ],
                  },
                  {
                    name: "invite_code",
                    label: "设置或更换入校邀请码",
                    type: "password",
                    hint: settings.data.invite_configured
                      ? "已设置邀请码。留空可保留当前邀请码。"
                      : "邀请码至少 6 位，仅由学校发给允许加入的学生。",
                  },
                  {
                    name: "teacher_minutes",
                    label: "老师单次服务时长（分钟）",
                    type: "number",
                    min: 10,
                    max: 180,
                    required: true,
                  },
                  {
                    name: "peer_minutes",
                    label: "朋辈单次服务时长（分钟）",
                    type: "number",
                    min: 10,
                    max: 180,
                    required: true,
                  },
                  {
                    name: "slot_gap_minutes",
                    label: "时段间隔（分钟）",
                    type: "number",
                    min: 0,
                    max: 60,
                    required: true,
                  },
                  {
                    name: "followup_delay_hours",
                    label: "服务完成后发送回访的间隔（小时）",
                    type: "number",
                    min: 0,
                    max: 720,
                    required: true,
                    hint: "设为 0 时，服务完成后立即生成填写通知。",
                  },
                ]}
                onSubmit={async (values) => {
                  try {
                    await mutation.mutateAsync({
                      path: "/admin/settings",
                      method: "PATCH",
                      data: values,
                    });
                    setSavedAt(
                      new Date().toLocaleTimeString("zh-CN", {
                        hour: "2-digit",
                        minute: "2-digit",
                      }),
                    );
                    toast("学校设置已保存");
                  } catch {
                    /* Inline error. */
                  }
                }}
              />
            </div>
          </section>
        )
      )}
    </>
  );
}

export function ProfilePage() {
  const { user } = useSession();
  const isStaff = user?.roles.some((role) =>
    ["teacher", "peer"].includes(role),
  );
  const profile = useObject("/staff/me", Boolean(isStaff));
  const profileMutation = useWrite();
  const passwordMutation = useWrite();
  const userMutation = useWrite();
  const toast = useToast();
  const [passwordKey, setPasswordKey] = useState(0);
  return (
    <>
      <PageHeader
        title="我的资料与账号"
        description="清楚介绍你能提供的支持，让同学更放心地迈出第一步。"
      />
      {isStaff && (
        <section className="settings-layout">
          <aside className="settings-intro">
            <UserRound size={28} strokeWidth={1.4} />
            <h2>接待资料</h2>
            <p>这部分信息会展示在校内支持人员列表中。</p>
            {text(profile.data, "supervisor_name") && (
              <p>指导老师 · {text(profile.data, "supervisor_name")}</p>
            )}
          </aside>
          <div className="panel settings-form">
            <ErrorNotice
              error={profile.error}
              retry={() => void profile.refetch()}
            />
            {profile.isLoading ? (
              <Loading rows={3} />
            ) : (
              profile.data && (
                <EntityForm
                  initial={{
                    bio: profile.data.bio,
                    location: profile.data.location,
                    mode:
                      Array.isArray(profile.data.modes) &&
                      profile.data.modes.length > 1
                        ? "both"
                        : Array.isArray(profile.data.modes)
                          ? profile.data.modes[0]
                          : "online",
                  }}
                  error={profileMutation.error}
                  pending={profileMutation.isPending}
                  fields={[
                    { name: "bio", label: "个人与服务介绍", type: "textarea" },
                    {
                      name: "mode",
                      label: "接待方式",
                      type: "select",
                      required: true,
                      options: [
                        { value: "online", label: "线上文字交流" },
                        { value: "onsite", label: "线下见面" },
                        { value: "both", label: "线上与线下" },
                      ],
                    },
                    { name: "location", label: "线下接待地点" },
                  ]}
                  onSubmit={async (values) => {
                    try {
                      await profileMutation.mutateAsync({
                        path: "/staff/me",
                        method: "PATCH",
                        data: {
                          bio: values.bio,
                          location: values.location,
                          modes:
                            values.mode === "both"
                              ? ["online", "onsite"]
                              : [values.mode],
                        },
                      });
                      toast("接待资料已更新");
                    } catch {
                      /* Inline error. */
                    }
                  }}
                />
              )
            )}
          </div>
        </section>
      )}
      <section className="settings-layout">
        <aside className="settings-intro">
          <UserRound size={28} strokeWidth={1.4} />
          <h2>显示姓名</h2>
          <p>当前账号为 {user?.account}。</p>
        </aside>
        <div className="panel settings-form">
          <EntityForm
            initial={{ nickname: user?.nickname || "" }}
            fields={[{ name: "nickname", label: "姓名或昵称", required: true }]}
            error={userMutation.error}
            pending={userMutation.isPending}
            onSubmit={async (values) => {
              try {
                await userMutation.mutateAsync({
                  path: "/me",
                  method: "PATCH",
                  data: values,
                });
                toast("显示姓名已更新");
              } catch {
                /* Inline error. */
              }
            }}
          />
        </div>
      </section>
      <section className="settings-layout">
        <aside className="settings-intro">
          <LockKeyhole size={28} strokeWidth={1.4} />
          <h2>修改密码</h2>
          <p>选择至少 8 位的密码，并与其他网站使用的密码区分。</p>
        </aside>
        <div className="panel settings-form">
          <EntityForm
            key={passwordKey}
            fields={[
              {
                name: "old_password",
                label: "当前密码",
                type: "password",
                required: true,
              },
              {
                name: "new_password",
                label: "新密码",
                type: "password",
                required: true,
              },
            ]}
            submitLabel="更新密码"
            error={passwordMutation.error}
            pending={passwordMutation.isPending}
            onSubmit={async (values) => {
              try {
                await passwordMutation.mutateAsync({
                  path: "/me/password",
                  data: values,
                });
                setPasswordKey(passwordKey + 1);
                toast("密码已更新");
              } catch {
                /* Inline error. */
              }
            }}
          />
        </div>
      </section>
    </>
  );
}
