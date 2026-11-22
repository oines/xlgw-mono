import { useEffect, useState } from "react";
import { Plus, ShieldCheck, UserRound } from "lucide-react";
import { useList, useObject, useWrite } from "../lib/data";
import { dateTime, roles, text, type Row } from "../lib/api";
import {
  Avatar,
  Button,
  Drawer,
  ErrorNotice,
  Field,
  Loading,
  PageHeader,
  SearchInput,
  Table,
  useToast,
} from "../components/ui";

export function PeoplePage() {
  const [query, setQuery] = useState("");
  const [role, setRole] = useState("all");
  const [editing, setEditing] = useState<Row | "new" | null>(null);
  const list = useList("/admin/users");
  const rows = (list.data?.items || []).filter(
    (row) =>
      (role === "all" ||
        (Array.isArray(row.roles) && row.roles.includes(role))) &&
      `${text(row, "nickname")} ${text(row, "account")}`
        .toLowerCase()
        .includes(query.toLowerCase()),
  );
  return (
    <>
      <PageHeader
        title="成员与服务人员"
        description="维护校园成员、接待身份和人员资料。"
        action={
          <Button tone="primary" onClick={() => setEditing("new")}>
            <Plus size={17} />
            创建账号
          </Button>
        }
      />
      <ErrorNotice error={list.error} retry={() => void list.refetch()} />
      <section className="panel">
        <div className="toolbar">
          <div className="filter-buttons">
            {[
              { value: "all", label: "全部成员" },
              { value: "teacher", label: "心理老师" },
              { value: "peer", label: "朋辈同学" },
              { value: "student", label: "学生" },
              { value: "admin", label: "管理员" },
            ].map((item) => (
              <button
                key={item.value}
                className={role === item.value ? "selected" : ""}
                onClick={() => setRole(item.value)}
              >
                {item.label}
              </button>
            ))}
          </div>
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="搜索账号或昵称"
          />
        </div>
        {list.isLoading ? (
          <Loading />
        ) : (
          <Table
            rows={rows}
            onRow={setEditing}
            emptyTitle="没有找到对应成员"
            emptyDescription="修改搜索条件，或创建一个新的工作账号。"
            columns={[
              {
                key: "nickname",
                label: "成员",
                render: (row) => (
                  <div className="person">
                    <Avatar name={text(row, "nickname")} />
                    <div>
                      <strong>{text(row, "nickname")}</strong>
                      <small>{text(row, "account")}</small>
                    </div>
                  </div>
                ),
              },
              {
                key: "roles",
                label: "已授权身份",
                render: (row) => (
                  <div className="role-tags">
                    {(Array.isArray(row.roles) ? row.roles : []).map(
                      (item: string) => (
                        <span key={item}>{roles[item] || item}</span>
                      ),
                    )}
                  </div>
                ),
              },
              {
                key: "active",
                label: "账号状态",
                render: (row) => (
                  <span
                    className={`status status-${row.active ? "brand" : "muted"}`}
                  >
                    {row.active ? "可用" : "已停用"}
                  </span>
                ),
              },
              {
                key: "open_items",
                label: "未完成事项",
                render: (row) =>
                  typeof row.open_items === "number" ? row.open_items : "—",
                numeric: true,
              },
              {
                key: "created_at",
                label: "加入时间",
                render: (row) => dateTime(row.created_at, true),
              },
            ]}
          />
        )}
      </section>
      {editing && (
        <UserEditor
          row={editing === "new" ? undefined : editing}
          onClose={() => setEditing(null)}
        />
      )}
    </>
  );
}

function UserEditor({ row, onClose }: { row?: Row; onClose: () => void }) {
  const memberRoles = (Array.isArray(row?.roles) ? row.roles : []) as string[];
  const [account, setAccount] = useState(text(row, "account"));
  const [password, setPassword] = useState("");
  const [nickname, setNickname] = useState(text(row, "nickname"));
  const [student, setStudent] = useState(
    !row || memberRoles.includes("student"),
  );
  const [admin, setAdmin] = useState(memberRoles.includes("admin"));
  const [workRole, setWorkRole] = useState(
    memberRoles.includes("teacher")
      ? "teacher"
      : memberRoles.includes("peer")
        ? "peer"
        : "",
  );
  const [active, setActive] = useState(row?.active !== false);
  const [bio, setBio] = useState("");
  const [location, setLocation] = useState("");
  const [supervisor, setSupervisor] = useState("");
  const [online, setOnline] = useState(true);
  const [onsite, setOnsite] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const [savedId, setSavedId] = useState(row?.id || "");
  const [resetOpen, setResetOpen] = useState(false);
  const [temporaryPassword, setTemporaryPassword] = useState("");
  const [resetSuccess, setResetSuccess] = useState(false);
  const resetMutation = useWrite();
  const profile = useObject(
    `/staff/${row?.id}`,
    Boolean(
      row && memberRoles.some((item) => ["teacher", "peer"].includes(item)),
    ),
  );
  const teachers = useList("/staff?role=teacher", workRole === "peer");
  const mutation = useWrite();
  const toast = useToast();
  useEffect(() => {
    if (profile.data) {
      setBio(text(profile.data, "bio"));
      setLocation(text(profile.data, "location"));
      setSupervisor(text(profile.data, "supervisor_id"));
      setOnline(
        Array.isArray(profile.data.modes) &&
          profile.data.modes.includes("online"),
      );
      setOnsite(
        Array.isArray(profile.data.modes) &&
          profile.data.modes.includes("onsite"),
      );
    }
  }, [profile.data]);
  async function save() {
    setError(null);
    const nextRoles = [
      ...(student ? ["student"] : []),
      ...(workRole ? [workRole] : []),
      ...(admin ? ["admin"] : []),
    ];
    if (!nextRoles.length) {
      setError(new Error("请至少保留一个账号身份。"));
      return;
    }
    if (workRole && !online && !onsite) {
      setError(new Error("请选择至少一种接待方式。"));
      return;
    }
    try {
      let id = savedId;
      if (id)
        await mutation.mutateAsync({
          path: `/admin/users/${id}`,
          method: "PATCH",
          data: { nickname, roles: nextRoles, active },
        });
      else {
        const created = await mutation.mutateAsync({
          path: "/admin/users",
          data: { account, password, nickname, roles: nextRoles },
        });
        id = created.id;
        setSavedId(id);
      }
      if (workRole) {
        try {
          await mutation.mutateAsync({
            path: `/admin/staff/${id}`,
            method: "PUT",
            data: {
              role: workRole,
              bio,
              location,
              supervisor_id: supervisor || undefined,
              modes: [
                ...(online ? ["online"] : []),
                ...(onsite ? ["onsite"] : []),
              ],
              active,
            },
          });
        } catch (caught) {
          setError(
            new Error(
              `账号已保存，接待资料尚未保存：${(caught as Error).message}。请修正后再次保存。`,
            ),
          );
          return;
        }
      }
      toast(row ? "成员资料已更新" : "账号已创建");
      onClose();
    } catch (caught) {
      setError(caught as Error);
    }
  }
  return (
    <Drawer
      title={row ? "成员与身份" : "创建账号"}
      subtitle={row ? text(row, "account") : "账号保存后，成员即可登录使用。"}
      onClose={onClose}
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void save();
        }}
        className="entity-form"
      >
        <ErrorNotice error={error || profile.error} />
        {!row && (
          <>
            <Field label="账号" required>
              <input
                required
                minLength={4}
                maxLength={32}
                value={account}
                onChange={(event) => setAccount(event.target.value)}
                disabled={Boolean(savedId)}
                autoComplete="off"
              />
            </Field>
            <Field label="初始密码" required>
              <input
                required
                minLength={8}
                maxLength={64}
                type="password"
                autoComplete="new-password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
              />
            </Field>
          </>
        )}
        <Field label="昵称或姓名" required>
          <input
            required
            minLength={2}
            maxLength={20}
            value={nickname}
            onChange={(event) => setNickname(event.target.value)}
          />
        </Field>
        <div className="form-section">
          <h3>
            <ShieldCheck size={16} />
            身份与权限
          </h3>
          <label className="check-field">
            <input
              type="checkbox"
              checked={student}
              onChange={(event) => setStudent(event.target.checked)}
            />
            学生个人空间
          </label>
          <label className="check-field">
            <input
              type="checkbox"
              checked={admin}
              onChange={(event) => setAdmin(event.target.checked)}
            />
            运营管理员
          </label>
          <Field label="接待身份">
            <select
              value={workRole}
              onChange={(event) => setWorkRole(event.target.value)}
            >
              <option value="">无工作身份</option>
              <option value="teacher">心理老师</option>
              <option value="peer">朋辈同学</option>
            </select>
          </Field>
        </div>
        {workRole && (
          <div className="form-section">
            <h3>
              <UserRound size={16} />
              接待资料
            </h3>
            <Field label="介绍">
              <textarea
                rows={4}
                value={bio}
                onChange={(event) => setBio(event.target.value)}
              />
            </Field>
            <div className="field">
              <span className="field-label">接待方式</span>
              <div className="checkbox-row">
                <label className="check-field">
                  <input
                    type="checkbox"
                    checked={online}
                    onChange={(event) => setOnline(event.target.checked)}
                  />
                  线上文字
                </label>
                <label className="check-field">
                  <input
                    type="checkbox"
                    checked={onsite}
                    onChange={(event) => setOnsite(event.target.checked)}
                  />
                  线下见面
                </label>
              </div>
            </div>
            {onsite && (
              <Field label="接待地点">
                <input
                  value={location}
                  onChange={(event) => setLocation(event.target.value)}
                />
              </Field>
            )}
            {workRole === "peer" && (
              <Field label="指导老师" required>
                <select
                  value={supervisor}
                  required
                  onChange={(event) => setSupervisor(event.target.value)}
                >
                  <option value="">请选择指导老师</option>
                  {teachers.data?.items
                    .filter((item) => item.id !== row?.id)
                    .map((item) => (
                      <option key={item.id} value={item.id}>
                        {text(item, "nickname")}
                      </option>
                    ))}
                </select>
              </Field>
            )}
          </div>
        )}
        {row && (
          <div className="form-section">
            <Field label="账号状态">
              <select
                value={active ? "active" : "disabled"}
                onChange={(event) => setActive(event.target.value === "active")}
              >
                <option value="active">可用</option>
                <option value="disabled">停用</option>
              </select>
            </Field>
            {!active && (
              <p className="field-hint">
                停用后将无法继续访问。未完成服务会进入重新分配列表。
              </p>
            )}
          </div>
        )}
        {row && (
          <div className="form-section">
            <h3>重置登录密码</h3>
            <ErrorNotice error={resetMutation.error} />
            {resetOpen ? (
              <>
                <Field
                  label="临时密码"
                  hint="重置后旧登录会话将退出。请将临时密码安全交给账号本人，并提醒登录后修改。"
                >
                  <input
                    type="text"
                    autoComplete="off"
                    value={temporaryPassword}
                    onChange={(event) => {
                      setTemporaryPassword(event.target.value);
                      setResetSuccess(false);
                    }}
                  />
                </Field>
                <div className="button-group">
                  <Button
                    type="button"
                    onClick={() => {
                      setTemporaryPassword(
                        `Harbor-${crypto.randomUUID().slice(0, 12)}`,
                      );
                      setResetSuccess(false);
                    }}
                  >
                    生成临时密码
                  </Button>
                  <Button
                    type="button"
                    disabled={temporaryPassword.length < 8}
                    busy={resetMutation.isPending}
                    onClick={async () => {
                      try {
                        await resetMutation.mutateAsync({
                          path: `/admin/users/${row.id}`,
                          method: "PATCH",
                          data: { password: temporaryPassword },
                        });
                        setResetSuccess(true);
                      } catch {
                        /* Inline error. */
                      }
                    }}
                  >
                    确认重置
                  </Button>
                </div>
                {resetSuccess && (
                  <p className="field-hint">
                    密码已重置，账号原有登录会话已退出。
                  </p>
                )}
              </>
            ) : (
              <Button type="button" onClick={() => setResetOpen(true)}>
                重置密码
              </Button>
            )}
          </div>
        )}
        <div className="form-submit">
          <Button type="submit" tone="primary" busy={mutation.isPending}>
            保存成员资料
          </Button>
        </div>
      </form>
    </Drawer>
  );
}
