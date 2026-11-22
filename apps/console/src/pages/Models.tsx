import { useState } from "react";
import {
  Activity,
  ArrowUpRight,
  CheckCircle2,
  CircleHelp,
  Cpu,
  KeyRound,
  Plus,
  SlidersHorizontal,
  XCircle,
} from "lucide-react";
import { useList, useObject, useWrite } from "../lib/data";
import { dateTime, text, type ListResult, type Row } from "../lib/api";
import {
  Button,
  Drawer,
  Empty,
  EntityForm,
  ErrorNotice,
  Field,
  Loading,
  PageHeader,
  SearchInput,
  Status,
  Table,
  Tabs,
  useToast,
} from "../components/ui";

const purposes = [
  {
    purpose: "chat",
    label: "日常对话",
    description: "学生与 AI 伙伴交流时使用的模型。",
  },
  {
    purpose: "summary",
    label: "内容摘要",
    description: "用于历史压缩与学生主动生成的分享摘要。",
  },
  {
    purpose: "title",
    label: "会话标题",
    description: "根据首次输入为新会话生成标题。",
  },
];

export function ModelsPage() {
  const [tab, setTab] = useState("connections");
  return (
    <>
      <PageHeader
        title="模型与用量"
        description="管理模型连接，让每次调用、额度和费用都有清楚的去向。"
      />
      <Tabs
        value={tab}
        onChange={setTab}
        items={[
          { value: "connections", label: "模型连接" },
          { value: "routes", label: "用途配置" },
          { value: "calls", label: "实际调用" },
          { value: "limits", label: "额度与限流" },
        ]}
      />
      {tab === "connections" && <Connections />}
      {tab === "routes" && <Routes />}
      {tab === "calls" && <Calls />}
      {tab === "limits" && <Limits />}
    </>
  );
}

function Connections() {
  const list = useList("/admin/ai/connections");
  const [editing, setEditing] = useState<Row | "new" | null>(null);
  const [testingId, setTestingId] = useState("");
  const [error, setError] = useState<Error | null>(null);
  const mutation = useWrite();
  const toast = useToast();
  async function test(row: Row) {
    setTestingId(row.id);
    setError(null);
    try {
      const result = await mutation.mutateAsync({
        path: `/admin/ai/connections/${row.id}/test`,
      });
      if (result.last_test_status === "success") toast("连接测试成功");
      else
        setError(
          new Error(
            text(result, "last_test_error") ||
              "连接测试未成功，请查看连接配置。",
          ),
        );
    } catch (caught) {
      setError(caught as Error);
    } finally {
      setTestingId("");
    }
  }
  return (
    <>
      <div className="toolbar plain-toolbar">
        <p className="muted">供应商密钥仅保存在服务端。</p>
        <Button
          tone="primary"
          onClick={() => {
            mutation.reset();
            setEditing("new");
          }}
        >
          <Plus size={16} />
          添加连接
        </Button>
      </div>
      <ErrorNotice
        error={list.error || error}
        retry={() => void list.refetch()}
      />
      {list.isLoading ? (
        <Loading />
      ) : list.data?.items.length ? (
        <div className="connections-grid">
          {list.data.items.map((row) => (
            <article className="connection-card panel" key={row.id}>
              <header>
                <div className="connection-icon">
                  <Cpu size={23} strokeWidth={1.5} />
                </div>
                <div>
                  <h2>{text(row, "name")}</h2>
                  <small>
                    {text(row, "provider", "protocol") || "OpenAI 兼容连接"}
                  </small>
                </div>
                <span
                  className={`status status-${row.enabled ? "brand" : "muted"}`}
                >
                  {row.enabled ? "已启用" : "已停用"}
                </span>
              </header>
              <dl>
                <div>
                  <dt>服务地址</dt>
                  <dd title={text(row, "base_url")}>{text(row, "base_url")}</dd>
                </div>
                <div>
                  <dt>可用模型</dt>
                  <dd>
                    {Array.isArray(row.models) ? row.models.join("、") : "—"}
                  </dd>
                </div>
                <div>
                  <dt>认证密钥</dt>
                  <dd>
                    <KeyRound size={13} />
                    {row.has_key ? "已配置 · ••••••••" : "使用服务端配置"}
                  </dd>
                </div>
              </dl>
              {row.last_test_at ? (
                <div
                  className={`connection-test-result ${row.last_test_status === "success" ? "" : "is-error"}`}
                >
                  {row.last_test_status === "success" ? (
                    <CheckCircle2 size={15} />
                  ) : (
                    <XCircle size={15} />
                  )}
                  <span>
                    {row.last_test_status === "success"
                      ? "连接测试通过"
                      : text(row, "last_test_error") || "连接测试未通过"}
                  </span>
                  <time>{dateTime(row.last_test_at)}</time>
                </div>
              ) : (
                <div className="connection-test-result">
                  <CircleHelp size={15} />
                  <span>尚未测试连接</span>
                </div>
              )}
              <footer>
                <Button
                  tone="ghost"
                  busy={testingId === row.id}
                  disabled={Boolean(testingId)}
                  onClick={() => void test(row)}
                >
                  测试连接
                </Button>
                <Button
                  onClick={() => {
                    mutation.reset();
                    setEditing(row);
                  }}
                >
                  编辑连接 <ArrowUpRight size={14} />
                </Button>
              </footer>
            </article>
          ))}
        </div>
      ) : (
        <section className="panel">
          <Empty
            title="还没有模型连接"
            description="配置模型服务后，学生即可与 AI 伙伴展开真实对话。"
            action={
              <Button tone="primary" onClick={() => setEditing("new")}>
                <Plus size={16} />
                添加连接
              </Button>
            }
          />
        </section>
      )}
      {editing && (
        <Drawer
          title={editing === "new" ? "添加模型连接" : "编辑模型连接"}
          subtitle="连接测试会发起一次真实模型请求，并记录用量。"
          onClose={() => setEditing(null)}
        >
          <EntityForm
            initial={
              editing === "new"
                ? {
                    enabled: true,
                    base_url: "https://api.deepseek.com/v1",
                    models_text: "deepseek-chat",
                    provider: "DeepSeek",
                  }
                : {
                    ...editing,
                    models_text: Array.isArray(editing.models)
                      ? editing.models.join("\n")
                      : "",
                    api_key: "",
                  }
            }
            fields={[
              { name: "name", label: "连接名称", required: true },
              { name: "provider", label: "供应商名称" },
              {
                name: "base_url",
                label: "API 服务地址",
                type: "url",
                required: true,
              },
              {
                name: "api_key",
                label: "API 密钥",
                type: "password",
                hint:
                  editing === "new"
                    ? "留空时使用后端已配置的服务密钥。"
                    : "留空保留原密钥，填写新值将替换。",
              },
              {
                name: "models_text",
                label: "模型名称",
                type: "textarea",
                required: true,
                hint: "每行一个模型名称，如 deepseek-chat。",
              },
              { name: "enabled", label: "启用连接", type: "checkbox" },
            ]}
            error={mutation.error}
            pending={mutation.isPending}
            submitLabel="保存连接"
            onSubmit={async (values) => {
              const { models_text, api_key, ...rest } = values;
              try {
                await mutation.mutateAsync({
                  path:
                    editing === "new"
                      ? "/admin/ai/connections"
                      : `/admin/ai/connections/${editing.id}`,
                  method: editing === "new" ? "POST" : "PATCH",
                  data: {
                    ...rest,
                    api_key: api_key || undefined,
                    protocol: "openai-completions",
                    models: String(models_text)
                      .split(/[\n,，]/)
                      .map((value) => value.trim())
                      .filter(Boolean),
                  },
                });
                setEditing(null);
                toast("模型连接已保存");
              } catch {
                /* Inline error. */
              }
            }}
          />
        </Drawer>
      )}
    </>
  );
}

function Routes() {
  const routes = useObject<ListResult<Row>>("/admin/ai/routes");
  const connections = useList("/admin/ai/connections");
  const mutation = useWrite();
  const toast = useToast();
  const [editing, setEditing] = useState<string | null>(null);
  const selected = purposes.find((item) => item.purpose === editing);
  const route = routes.data?.items.find((row) => row.purpose === editing);
  const choices = (connections.data?.items || []).map((row) => ({
    value: row.id,
    label: text(row, "name") + (row.enabled ? "" : "（已停用）"),
  }));
  return (
    <section className="panel">
      <div className="section-heading">
        <div>
          <h2>按用途选择模型</h2>
          <p>保存后用于新请求，已经开始的回复保持原配置。</p>
        </div>
        <SlidersHorizontal size={20} />
      </div>
      <ErrorNotice
        error={routes.error || connections.error}
        retry={() => {
          void routes.refetch();
          void connections.refetch();
        }}
      />
      {routes.isLoading ? (
        <Loading rows={3} />
      ) : (
        <div className="route-list">
          {purposes.map((purpose) => {
            const item = routes.data?.items.find(
              (row) => row.purpose === purpose.purpose,
            );
            const connection = connections.data?.items.find(
              (row) => row.id === item?.connection_id,
            );
            return (
              <div className="route-row" key={purpose.purpose}>
                <div>
                  <h3>{purpose.label}</h3>
                  <p>{purpose.description}</p>
                </div>
                <div className="route-target">
                  <strong>
                    {item?.model ? text(item, "model") : "尚未配置"}
                  </strong>
                  <small>{text(connection, "name") || "选择连接与模型"}</small>
                </div>
                <Button
                  onClick={() => {
                    mutation.reset();
                    setEditing(purpose.purpose);
                  }}
                >
                  配置
                </Button>
              </div>
            );
          })}
        </div>
      )}
      {selected && (
        <Drawer
          title={`配置${selected.label}`}
          onClose={() => setEditing(null)}
        >
          <EntityForm
            initial={
              route || {
                purpose: editing,
                temperature: 0.7,
                max_output_tokens: editing === "title" ? 64 : 2048,
                context_window: 16384,
              }
            }
            fields={[
              {
                name: "connection_id",
                label: "模型连接",
                type: "select",
                required: true,
                options: choices,
              },
              { name: "model", label: "模型名称", required: true },
              {
                name: "temperature",
                label: "温度",
                type: "number",
                min: 0,
                max: 2,
              },
              {
                name: "max_output_tokens",
                label: "最大输出 token",
                type: "number",
                min: 16,
                max: 131072,
                required: true,
              },
              {
                name: "context_window",
                label: "上下文 token 预算",
                type: "number",
                min: 1024,
                max: 1048576,
                required: true,
              },
              {
                name: "fallback_connection_id",
                label: "备用连接（选填）",
                type: "select",
                options: choices,
              },
              { name: "fallback_model", label: "备用模型（选填）" },
            ]}
            error={mutation.error}
            pending={mutation.isPending}
            onSubmit={async (values) => {
              try {
                const items = [
                  ...(routes.data?.items || []).filter(
                    (item) => item.purpose !== editing,
                  ),
                  { ...values, purpose: editing },
                ];
                await mutation.mutateAsync({
                  path: "/admin/ai/routes",
                  method: "PUT",
                  data: { items },
                });
                setEditing(null);
                toast("模型用途已更新");
              } catch {
                /* Inline error. */
              }
            }}
          />
        </Drawer>
      )}
    </section>
  );
}

function Calls() {
  const list = useList("/admin/ai/calls?limit=100", true, true);
  const [query, setQuery] = useState("");
  const rows = (list.data?.items || []).filter((row) =>
    `${text(row, "model")} ${text(row, "user_id")}`.includes(query),
  );
  const succeeded = rows.filter((row) => row.status === "success").length;
  const inputKnown = rows.every((row) => typeof row.input_tokens === "number");
  const outputKnown = rows.every(
    (row) => typeof row.output_tokens === "number",
  );
  return (
    <>
      <div className="usage-summary">
        <div>
          <Activity size={19} />
          <span>最近调用</span>
          <strong>{list.data ? rows.length : "—"}</strong>
        </div>
        <div>
          <span>成功请求</span>
          <strong>{list.data ? succeeded : "—"}</strong>
        </div>
        <div>
          <span>输入 token</span>
          <strong>
            {list.data
              ? inputKnown
                ? rows
                    .reduce((total, row) => total + Number(row.input_tokens), 0)
                    .toLocaleString()
                : "部分未知"
              : "—"}
          </strong>
        </div>
        <div>
          <span>输出 token</span>
          <strong>
            {list.data
              ? outputKnown
                ? rows
                    .reduce(
                      (total, row) => total + Number(row.output_tokens),
                      0,
                    )
                    .toLocaleString()
                : "部分未知"
              : "—"}
          </strong>
        </div>
      </div>
      <ErrorNotice error={list.error} retry={() => void list.refetch()} />
      <section className="panel">
        <div className="toolbar">
          <p className="muted">显示最近 100 次真实出站请求，包含重试。</p>
          <SearchInput
            value={query}
            onChange={setQuery}
            placeholder="搜索模型或账号 ID"
          />
        </div>
        {list.isLoading ? (
          <Loading />
        ) : (
          <Table
            rows={rows}
            emptyTitle="暂时没有模型调用"
            emptyDescription="真实聊天或连接测试发起后，用量会记录在这里。"
            columns={[
              {
                key: "time",
                label: "时间",
                render: (row) => dateTime(row.created_at),
              },
              { key: "model", label: "模型" },
              {
                key: "purpose",
                label: "用途",
                render: (row) =>
                  purposes.find((item) => item.purpose === row.purpose)
                    ?.label || text(row, "purpose"),
              },
              {
                key: "latency",
                label: "耗时",
                numeric: true,
                render: (row) =>
                  typeof row.latency_ms === "number"
                    ? `${(row.latency_ms / 1000).toFixed(2)}s`
                    : "—",
              },
              {
                key: "input",
                label: "输入 token",
                numeric: true,
                render: (row) =>
                  typeof row.input_tokens === "number"
                    ? row.input_tokens.toLocaleString()
                    : "未知",
              },
              {
                key: "output",
                label: "输出 token",
                numeric: true,
                render: (row) =>
                  typeof row.output_tokens === "number"
                    ? row.output_tokens.toLocaleString()
                    : "未知",
              },
              {
                key: "status",
                label: "结果",
                render: (row) => (
                  <div>
                    <Status value={row.status} />
                    {row.error_code ? (
                      <small className="cell-hint">
                        {text(row, "error_code")}
                      </small>
                    ) : null}
                  </div>
                ),
              },
            ]}
          />
        )}
      </section>
    </>
  );
}

function Limits() {
  const limits = useObject("/admin/ai/limits");
  const overrides = useList("/admin/ai/limits/users");
  const users = useList("/admin/users");
  const mutation = useWrite();
  const toast = useToast();
  const [editing, setEditing] = useState(false);
  const [userId, setUserId] = useState("");
  const [enabled, setEnabled] = useState("inherit");
  const [daily, setDaily] = useState("");
  const [perMinute, setPerMinute] = useState("");
  const rows: Row[] = (overrides.data?.items || []).map((row) => ({
    ...row,
    id: row.id || text(row, "user_id"),
  }));
  return (
    <>
      <section className="settings-layout">
        <aside className="settings-intro">
          <SlidersHorizontal size={28} strokeWidth={1.4} />
          <h2>全局默认额度</h2>
          <p>每天按学校时区重置。被频率或并发限制拒绝的请求不占每日次数。</p>
          <p>设置为零时，该账号无法发起新的 AI 请求。</p>
        </aside>
        <div className="panel settings-form">
          <ErrorNotice
            error={limits.error}
            retry={() => void limits.refetch()}
          />
          {limits.isLoading ? (
            <Loading rows={3} />
          ) : (
            limits.data && (
              <EntityForm
                initial={limits.data}
                fields={[
                  { name: "enabled", label: "开放 AI 服务", type: "checkbox" },
                  {
                    name: "daily_limit",
                    label: "每人每日消息数",
                    type: "number",
                    required: true,
                    min: 0,
                    max: 100000,
                  },
                  {
                    name: "per_minute",
                    label: "每人每分钟发送上限",
                    type: "number",
                    required: true,
                    min: 1,
                    max: 10000,
                  },
                  {
                    name: "global_concurrency",
                    label: "全局模型并发上限",
                    type: "number",
                    required: true,
                    min: 1,
                    max: 1000,
                  },
                ]}
                error={!editing ? mutation.error : null}
                pending={mutation.isPending}
                onSubmit={async (values) => {
                  try {
                    await mutation.mutateAsync({
                      path: "/admin/ai/limits",
                      method: "PUT",
                      data: values,
                    });
                    toast("默认额度已保存");
                  } catch {
                    /* Inline error. */
                  }
                }}
              />
            )
          )}
        </div>
      </section>
      <section className="panel">
        <div className="section-heading">
          <div>
            <h2>个人额度</h2>
            <p>为需要的账号覆盖默认设置，其余账号继续使用全局额度。</p>
          </div>
          <Button
            onClick={() => {
              mutation.reset();
              setUserId("");
              setDaily("");
              setPerMinute("");
              setEnabled("inherit");
              setEditing(true);
            }}
          >
            <Plus size={16} />
            设置个人额度
          </Button>
        </div>
        <ErrorNotice
          error={overrides.error}
          retry={() => void overrides.refetch()}
        />
        <Table
          rows={rows}
          emptyTitle="所有账号使用默认额度"
          columns={[
            {
              key: "user",
              label: "账号",
              render: (row) =>
                text(
                  users.data?.items.find(
                    (item) => item.id === (row.user_id || row.id),
                  ),
                  "nickname",
                  "account",
                ) || text(row, "user_id", "id"),
            },
            {
              key: "enabled",
              label: "AI 状态",
              render: (row) =>
                row.enabled === null || row.enabled === undefined
                  ? "继承默认"
                  : row.enabled
                    ? "开放"
                    : "暂停",
            },
            {
              key: "daily",
              label: "每日条数",
              render: (row) =>
                row.daily_limit === null || row.daily_limit === undefined
                  ? "继承默认"
                  : String(row.daily_limit),
            },
            {
              key: "minute",
              label: "每分钟",
              render: (row) =>
                row.per_minute === null || row.per_minute === undefined
                  ? "继承默认"
                  : String(row.per_minute),
            },
          ]}
          onRow={(row) => {
            setUserId(text(row, "user_id", "id"));
            setEnabled(
              typeof row.enabled === "boolean"
                ? String(row.enabled)
                : "inherit",
            );
            setDaily(
              row.daily_limit === null || row.daily_limit === undefined
                ? ""
                : String(row.daily_limit),
            );
            setPerMinute(
              row.per_minute === null || row.per_minute === undefined
                ? ""
                : String(row.per_minute),
            );
            mutation.reset();
            setEditing(true);
          }}
        />
      </section>
      {editing && (
        <Drawer
          title="个人 AI 额度"
          subtitle="留空的数字项继承全局默认值。"
          onClose={() => setEditing(false)}
        >
          <form
            className="entity-form"
            onSubmit={async (event) => {
              event.preventDefault();
              try {
                await mutation.mutateAsync({
                  path: `/admin/ai/limits/users/${userId}`,
                  method: "PUT",
                  data: {
                    enabled: enabled === "inherit" ? null : enabled === "true",
                    daily_limit: daily === "" ? null : Number(daily),
                    per_minute: perMinute === "" ? null : Number(perMinute),
                  },
                });
                setEditing(false);
                toast("个人额度已保存");
              } catch {
                /* Inline error. */
              }
            }}
          >
            <ErrorNotice error={mutation.error || users.error} />
            <Field label="账号" required>
              <select
                required
                value={userId}
                onChange={(event) => setUserId(event.target.value)}
              >
                <option value="">选择账号</option>
                {users.data?.items.map((row) => (
                  <option key={row.id} value={row.id}>
                    {text(row, "nickname")}（{text(row, "account")}）
                  </option>
                ))}
              </select>
            </Field>
            <Field label="AI 状态">
              <select
                value={enabled}
                onChange={(event) => setEnabled(event.target.value)}
              >
                <option value="inherit">继承默认</option>
                <option value="true">开放</option>
                <option value="false">暂停</option>
              </select>
            </Field>
            <Field label="每日消息数">
              <input
                type="number"
                min={0}
                value={daily}
                onChange={(event) => setDaily(event.target.value)}
                placeholder="继承全局默认"
              />
            </Field>
            <Field label="每分钟上限">
              <input
                type="number"
                min={1}
                value={perMinute}
                onChange={(event) => setPerMinute(event.target.value)}
                placeholder="继承全局默认"
              />
            </Field>
            <Button tone="primary" type="submit" busy={mutation.isPending}>
              保存个人额度
            </Button>
          </form>
        </Drawer>
      )}
    </>
  );
}
