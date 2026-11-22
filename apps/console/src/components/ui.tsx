import {
  createContext,
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
  type ReactNode,
  type ButtonHTMLAttributes,
  type FormEvent,
} from "react";
import {
  AlertCircle,
  ArrowRight,
  Check,
  ChevronLeft,
  ChevronRight,
  Inbox,
  LoaderCircle,
  RefreshCw,
  Search,
  X,
} from "lucide-react";
import { dateTime, text, type Row } from "../lib/api";

export function Button({
  children,
  tone = "default",
  busy = false,
  className = "",
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  tone?: "default" | "primary" | "danger" | "ghost";
  busy?: boolean;
}) {
  return (
    <button
      className={`button button-${tone} ${className}`}
      {...props}
      disabled={props.disabled || busy}
    >
      {busy && <LoaderCircle size={16} className="spin" />}
      {children}
    </button>
  );
}

export function PageHeader({
  title,
  description,
  action,
  eyebrow,
}: {
  title: string;
  description?: string;
  action?: ReactNode;
  eyebrow?: string;
}) {
  return (
    <header className="page-heading">
      <div>
        {eyebrow && <div className="eyebrow">{eyebrow}</div>}
        <h1>{title}</h1>
        {description && <p>{description}</p>}
      </div>
      {action && <div className="page-action">{action}</div>}
    </header>
  );
}

export function ErrorNotice({
  error,
  retry,
}: {
  error?: Error | null;
  retry?: () => void;
}) {
  if (!error) return null;
  return (
    <div className="error-notice" role="alert">
      <AlertCircle size={18} />
      <div>
        <strong>暂时无法完成操作</strong>
        <p>{error.message}</p>
      </div>
      {retry && (
        <Button tone="ghost" onClick={retry}>
          <RefreshCw size={15} />
          重试
        </Button>
      )}
    </div>
  );
}

export function Loading({ rows = 4 }: { rows?: number }) {
  return (
    <div className="skeleton-list" aria-label="正在加载" role="status">
      {Array.from({ length: rows }, (_, index) => (
        <div className="skeleton-row" key={index}>
          <span className="skeleton-avatar" />
          <div>
            <span />
            <span />
          </div>
        </div>
      ))}
    </div>
  );
}

export function Empty({
  title = "暂时没有内容",
  description,
  action,
  icon,
}: {
  title?: string;
  description?: string;
  action?: ReactNode;
  icon?: ReactNode;
}) {
  return (
    <div className="empty-state">
      <div className="empty-symbol">
        {icon || <Inbox size={28} strokeWidth={1.4} />}
      </div>
      <h3>{title}</h3>
      {description && <p>{description}</p>}
      {action}
    </div>
  );
}

const statuses: Record<string, { label: string; tone: string }> = {
  pending: { label: "待确认", tone: "warning" },
  requested: { label: "待确认", tone: "warning" },
  pending_review: { label: "待查看", tone: "warning" },
  confirmed: { label: "已确认", tone: "brand" },
  in_progress: { label: "进行中", tone: "brand" },
  active: { label: "可用", tone: "brand" },
  completed: { label: "已完成", tone: "muted" },
  closed: { label: "已结案", tone: "muted" },
  awaiting: { label: "待填写", tone: "muted" },
  pending_contact: { label: "待联系", tone: "warning" },
  following: { label: "跟进中", tone: "brand" },
  processing: { label: "处理中", tone: "brand" },
  resolved: { label: "已解决", tone: "muted" },
  cancelled: { label: "已取消", tone: "muted" },
  canceled: { label: "已取消", tone: "muted" },
  rejected: { label: "已拒绝", tone: "muted" },
  expired: { label: "已过期", tone: "muted" },
  no_show: { label: "未到场", tone: "muted" },
  draft: { label: "草稿", tone: "muted" },
  submitted: { label: "已提交", tone: "warning" },
  reviewed: { label: "已阅", tone: "muted" },
  follow_up: { label: "跟进中", tone: "brand" },
  contacting: { label: "联系中", tone: "brand" },
  assigned: { label: "已分配", tone: "brand" },
  needs_contact: { label: "待联系", tone: "warning" },
  open: { label: "待处理", tone: "warning" },
  unassigned: { label: "待分配", tone: "warning" },
  accepted: { label: "已接受", tone: "brand" },
  success: { label: "成功", tone: "brand" },
  failed: { label: "失败", tone: "danger" },
  error: { label: "失败", tone: "danger" },
  disabled: { label: "已停用", tone: "muted" },
  enabled: { label: "已启用", tone: "brand" },
  published: { label: "已发布", tone: "brand" },
};
export function Status({ value }: { value: unknown }) {
  const key = typeof value === "string" ? value : "";
  const status = statuses[key] || { label: key || "—", tone: "muted" };
  return <span className={`status status-${status.tone}`}>{status.label}</span>;
}

export function Avatar({ name, size = 36 }: { name: string; size?: number }) {
  return (
    <span
      className="avatar"
      style={{ width: size, height: size, fontSize: size * 0.38 }}
      aria-hidden="true"
    >
      {name.trim().slice(0, 1) || "港"}
    </span>
  );
}

export function SearchInput({
  value,
  onChange,
  placeholder = "搜索",
}: {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
}) {
  return (
    <div className="search-input">
      <Search size={17} />
      <input
        aria-label={placeholder}
        placeholder={placeholder}
        value={value}
        onChange={(event) => onChange(event.target.value)}
      />
      {value && (
        <button
          className="icon-button"
          aria-label="清空搜索"
          onClick={() => onChange("")}
        >
          <X size={15} />
        </button>
      )}
    </div>
  );
}

export function Tabs({
  items,
  value,
  onChange,
}: {
  items: { value: string; label: string; count?: number }[];
  value: string;
  onChange: (value: string) => void;
}) {
  return (
    <div className="tabs" role="tablist">
      {items.map((item) => (
        <button
          key={item.value}
          role="tab"
          aria-selected={value === item.value}
          onClick={() => onChange(item.value)}
          className={value === item.value ? "active" : ""}
        >
          {item.label}
          {item.count !== undefined && <span>{item.count}</span>}
        </button>
      ))}
    </div>
  );
}

export type Column<T> = {
  label: string;
  key: string;
  render?: (row: T) => ReactNode;
  numeric?: boolean;
};
export function Table<T extends Row>({
  rows,
  columns,
  onRow,
  emptyTitle,
  emptyDescription,
}: {
  rows: T[];
  columns: Column<T>[];
  onRow?: (row: T) => void;
  emptyTitle?: string;
  emptyDescription?: string;
}) {
  const [page, setPage] = useState(0);
  const pageSize = 12;
  const lastPage = Math.max(0, Math.ceil(rows.length / pageSize) - 1);
  const currentPage = Math.min(page, lastPage);
  if (!rows.length)
    return <Empty title={emptyTitle} description={emptyDescription} />;
  return (
    <>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              {columns.map((column) => (
                <th
                  key={column.key}
                  className={column.numeric ? "numeric" : ""}
                >
                  {column.label}
                </th>
              ))}
              {onRow && (
                <th>
                  <span className="sr-only">操作</span>
                </th>
              )}
            </tr>
          </thead>
          <tbody>
            {rows
              .slice(currentPage * pageSize, (currentPage + 1) * pageSize)
              .map((row) => (
                <tr key={row.id}>
                  {columns.map((column) => (
                    <td
                      key={column.key}
                      className={column.numeric ? "numeric" : ""}
                    >
                      {column.render
                        ? column.render(row)
                        : text(row, column.key) || "—"}
                    </td>
                  ))}
                  {onRow && (
                    <td className="row-action">
                      <button
                        className="text-button"
                        onClick={() => onRow(row)}
                        aria-label={`查看${text(row, "nickname", "name", "title") || "详情"}`}
                      >
                        详情 <ArrowRight size={14} />
                      </button>
                    </td>
                  )}
                </tr>
              ))}
          </tbody>
        </table>
      </div>
      <div className="pagination">
        <span>共 {rows.length} 条</span>
        <div>
          <button
            aria-label="上一页"
            className="icon-button"
            disabled={currentPage === 0}
            onClick={() => setPage(currentPage - 1)}
          >
            <ChevronLeft size={17} />
          </button>
          <span>
            {currentPage + 1} / {lastPage + 1}
          </span>
          <button
            aria-label="下一页"
            className="icon-button"
            disabled={currentPage === lastPage}
            onClick={() => setPage(currentPage + 1)}
          >
            <ChevronRight size={17} />
          </button>
        </div>
      </div>
    </>
  );
}

export function Drawer({
  title,
  subtitle,
  children,
  footer,
  onClose,
}: {
  title: string;
  subtitle?: string;
  children: ReactNode;
  footer?: ReactNode;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const active = document.activeElement as HTMLElement;
    ref.current?.focus();
    const escape = (event: KeyboardEvent) => {
      if (event.key === "Escape") closeRef.current();
      if (event.key === "Tab") {
        const elements = ref.current?.querySelectorAll<HTMLElement>(
          'button:not(:disabled), input:not(:disabled), textarea, select, [tabindex="0"]',
        );
        if (!elements?.length) return;
        const first = elements[0];
        const last = elements[elements.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener("keydown", escape);
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", escape);
      document.body.style.overflow = previous;
      active?.focus();
    };
  }, []);
  return (
    <div className="drawer-layer">
      <div className="drawer-backdrop" onClick={onClose} />
      <div
        ref={ref}
        className="drawer"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
      >
        <header>
          <div>
            <h2 id={titleId}>{title}</h2>
            {subtitle && <p>{subtitle}</p>}
          </div>
          <button
            className="icon-button"
            aria-label="关闭详情"
            onClick={onClose}
          >
            <X size={20} />
          </button>
        </header>
        <div className="drawer-content">{children}</div>
        {footer && <footer>{footer}</footer>}
      </div>
    </div>
  );
}

export function Field({
  label,
  children,
  hint,
  required,
}: {
  label: string;
  children: ReactNode;
  hint?: string;
  required?: boolean;
}) {
  return (
    <label className="field">
      <span className="field-label">
        {label}
        {required && (
          <span className="required" aria-hidden="true">
            {" "}
            *
          </span>
        )}
      </span>
      {children}
      {hint && <span className="field-hint">{hint}</span>}
    </label>
  );
}

export function DetailList({
  items,
}: {
  items: { label: string; value: ReactNode }[];
}) {
  return (
    <dl className="detail-list">
      {items.map((item) => (
        <div key={item.label}>
          <dt>{item.label}</dt>
          <dd>{item.value || "—"}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Person({
  row,
  nameKey = "student_name",
  subtitle,
}: {
  row: Row;
  nameKey?: string;
  subtitle?: string;
}) {
  const name =
    text(row, nameKey, "student_nickname", "nickname", "name") || "未填写姓名";
  return (
    <div className="person">
      <Avatar name={name} />
      <div>
        <strong>{name}</strong>
        {subtitle && <small>{subtitle}</small>}
      </div>
    </div>
  );
}

export function TimeCell({ start, end }: { start: unknown; end?: unknown }) {
  return (
    <div className="time-cell">
      <strong>{dateTime(start)}</strong>
      {end && typeof end === "string" ? (
        <small>
          至{" "}
          {new Date(end).toLocaleTimeString("zh-CN", {
            hour: "2-digit",
            minute: "2-digit",
          })}
        </small>
      ) : null}
    </div>
  );
}

const ToastContext = createContext<(message: string) => void>(() => {});
export const useToast = () => useContext(ToastContext);
export function ToastProvider({ children }: { children: ReactNode }) {
  const [message, setMessage] = useState("");
  useEffect(() => {
    if (!message) return;
    const timer = window.setTimeout(() => setMessage(""), 3500);
    return () => clearTimeout(timer);
  }, [message]);
  return (
    <ToastContext.Provider value={setMessage}>
      {children}
      {message && (
        <div className="toast" role="status">
          <Check size={18} />
          {message}
          <button aria-label="关闭提示" onClick={() => setMessage("")}>
            <X size={15} />
          </button>
        </div>
      )}
    </ToastContext.Provider>
  );
}

export type FormField = {
  name: string;
  label: string;
  type?:
    | "text"
    | "password"
    | "textarea"
    | "number"
    | "datetime-local"
    | "select"
    | "checkbox"
    | "url";
  required?: boolean;
  hint?: string;
  options?: { value: string; label: string }[];
  min?: number;
  max?: number;
};
export function EntityForm({
  fields,
  initial = {},
  onSubmit,
  submitLabel = "保存",
  pending,
  error,
}: {
  fields: FormField[];
  initial?: Record<string, unknown>;
  onSubmit: (values: Record<string, unknown>) => void;
  submitLabel?: string;
  pending?: boolean;
  error?: Error | null;
}) {
  const [values, setValues] = useState(initial);
  const set = (name: string, value: unknown) =>
    setValues((previous) => ({ ...previous, [name]: value }));
  const submit = (event: FormEvent) => {
    event.preventDefault();
    onSubmit(values);
  };
  return (
    <form onSubmit={submit} className="entity-form">
      <ErrorNotice error={error} />
      {fields.map((field) => (
        <Field
          key={field.name}
          label={field.label}
          hint={field.hint}
          required={field.required}
        >
          {field.type === "textarea" ? (
            <textarea
              required={field.required}
              rows={4}
              value={String(values[field.name] ?? "")}
              onChange={(event) => set(field.name, event.target.value)}
            />
          ) : field.type === "select" ? (
            <select
              required={field.required}
              value={String(values[field.name] ?? "")}
              onChange={(event) => set(field.name, event.target.value)}
            >
              <option value="">请选择</option>
              {field.options?.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          ) : field.type === "checkbox" ? (
            <span className="check-field">
              <input
                type="checkbox"
                checked={Boolean(values[field.name])}
                onChange={(event) => set(field.name, event.target.checked)}
              />
              启用
            </span>
          ) : (
            <input
              type={field.type || "text"}
              required={field.required}
              min={field.min}
              max={field.max}
              step={field.type === "number" ? "any" : undefined}
              value={String(values[field.name] ?? "")}
              onChange={(event) =>
                set(
                  field.name,
                  field.type === "number" && event.target.value !== ""
                    ? Number(event.target.value)
                    : event.target.value,
                )
              }
              autoComplete={
                field.type === "password" ? "new-password" : undefined
              }
            />
          )}
        </Field>
      ))}
      <div className="form-submit">
        <Button tone="primary" busy={pending} type="submit">
          {submitLabel}
        </Button>
      </div>
    </form>
  );
}
