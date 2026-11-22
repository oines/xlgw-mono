export class ApiError extends Error {
  status: number;
  code: string;
  constructor(message: string, status: number, code = "") {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const base = import.meta.env.VITE_API_BASE_URL || "/api/v1";

export async function api<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${base}${path}`, {
      credentials: "include",
      ...options,
      headers: { "Content-Type": "application/json", ...options.headers },
    });
  } catch {
    throw new ApiError(
      "网络连接失败，请检查网络或服务连接后重试。",
      0,
      "NETWORK_ERROR",
    );
  }
  const body = await response.text();
  let payload: unknown;
  try {
    payload = body ? JSON.parse(body) : null;
  } catch {
    throw new ApiError(
      "服务返回了无法读取的结果，请稍后重试。",
      response.status,
    );
  }
  if (!response.ok) {
    const error = payload as { message?: string; code?: string } | null;
    throw new ApiError(
      error?.message || `请求失败（${response.status}）`,
      response.status,
      error?.code,
    );
  }
  return payload as T;
}

export const write = <T>(path: string, data: unknown = {}, method = "POST") =>
  api<T>(path, { method, body: JSON.stringify(data) });

export type Row = Record<string, unknown> & { id: string };
export type User = {
  id: string;
  account: string;
  nickname: string;
  roles: string[];
  active: boolean;
  school?: unknown;
};
export type School = {
  name?: string;
  intro?: string;
  location?: string;
  contact?: string;
  service_hours?: string;
  initialized?: boolean;
  timezone?: string;
};
export type ListResult<T> = { items: T[]; total?: number };

export function text(
  row: Record<string, unknown> | undefined | null,
  ...keys: string[]
): string {
  for (const key of keys) {
    const value = row?.[key];
    if (typeof value === "string" && value.length) return value;
    if (typeof value === "number") return String(value);
  }
  return "";
}

export function number(
  row: Record<string, unknown> | undefined,
  key: string,
): number | undefined {
  const value = row?.[key];
  return typeof value === "number" ? value : undefined;
}

export function dateTime(value: unknown, short = false): string {
  if (typeof value !== "string" || !value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    ...(short ? {} : { hour: "2-digit", minute: "2-digit", hour12: false }),
  }).format(date);
}

export function localInput(value?: string): string {
  const date = value ? new Date(value) : new Date();
  date.setMinutes(date.getMinutes() - date.getTimezoneOffset());
  return date.toISOString().slice(0, 16);
}

export const roles: Record<string, string> = {
  student: "学生",
  teacher: "心理老师",
  peer: "朋辈同学",
  admin: "运营管理员",
};
