import { useState } from "react";
import { BarChart3, Download } from "lucide-react";
import { useObject } from "../lib/data";
import { text, type Row } from "../lib/api";
import {
  Button,
  Empty,
  ErrorNotice,
  Loading,
  PageHeader,
  Table,
} from "../components/ui";

const metrics = [
  { key: "registered", label: "注册人数" },
  { key: "active", label: "活跃人数" },
  { key: "ai_inputs", label: "AI 消息数" },
  { key: "appointments_completed", label: "完成服务" },
  { key: "followups_submitted", label: "提交回访" },
];
function day(value: Date) {
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
}
export function StatisticsPage() {
  const [from, setFrom] = useState(() => {
    const date = new Date();
    date.setDate(date.getDate() - 6);
    return day(date);
  });
  const [to, setTo] = useState(() => day(new Date()));
  const [metric, setMetric] = useState("active");
  const stats = useObject(
    `/admin/stats?from=${from}&to=${to}`,
    Boolean(from && to && from <= to),
  );
  const rows: Row[] = Array.isArray(stats.data?.series)
    ? (stats.data.series as Row[]).map((row) => ({
        ...row,
        id: text(row, "date"),
      }))
    : [];
  const maximum = Math.max(1, ...rows.map((row) => Number(row[metric] || 0)));
  const hasData = rows.some((row) => Number(row[metric]) > 0);
  function exportCsv() {
    const cell = (value: unknown) =>
      `"${String(value ?? "").replaceAll('"', '""')}"`;
    const content = [
      ["日期", ...metrics.map((item) => item.label)],
      ...rows.map((row) => [
        text(row, "date"),
        ...metrics.map((item) => row[item.key]),
      ]),
    ]
      .map((row) => row.map(cell).join(","))
      .join("\r\n");
    const url = URL.createObjectURL(
      new Blob(["\uFEFF", content], { type: "text/csv;charset=utf-8;" }),
    );
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `校园服务统计-${from}-${to}.csv`;
    anchor.click();
    URL.revokeObjectURL(url);
  }
  return (
    <>
      <PageHeader
        title="使用与服务统计"
        description="看见真实的使用情况与服务进展。"
        action={
          <Button disabled={!rows.length} onClick={exportCsv}>
            <Download size={16} />
            导出当前数据
          </Button>
        }
      />
      <div className="toolbar plain-toolbar">
        <div className="date-filter">
          <label>
            开始日期
            <input
              type="date"
              value={from}
              max={to}
              onChange={(event) => setFrom(event.target.value)}
            />
          </label>
          <span>至</span>
          <label>
            结束日期
            <input
              type="date"
              value={to}
              min={from}
              onChange={(event) => setTo(event.target.value)}
            />
          </label>
        </div>
        <span className="muted">
          {from} 至 {to}
        </span>
      </div>
      {from > to && (
        <ErrorNotice error={new Error("结束日期不能早于开始日期。")} />
      )}
      <ErrorNotice error={stats.error} retry={() => void stats.refetch()} />
      <div className="metrics-grid statistics-metrics">
        {metrics.slice(0, 4).map((item) => (
          <div className="metric" key={item.key}>
            <span className="metric-label">{item.label}</span>
            <strong className="metric-value">
              {stats.data?.[item.key] === undefined
                ? "—"
                : String(stats.data[item.key])}
            </strong>
            <small>所选时间范围</small>
          </div>
        ))}
      </div>
      <section className="panel trend-panel">
        <div className="section-heading">
          <div>
            <h2>每日变化</h2>
            <p>选择指标，查看每天实际记录的数量。</p>
          </div>
          <select
            aria-label="趋势指标"
            className="metric-select"
            value={metric}
            onChange={(event) => setMetric(event.target.value)}
          >
            {metrics.map((item) => (
              <option value={item.key} key={item.key}>
                {item.label}
              </option>
            ))}
          </select>
        </div>
        {stats.isLoading ? (
          <Loading />
        ) : hasData ? (
          <div
            className="bar-chart"
            aria-label={`${metrics.find((item) => item.key === metric)?.label}每日变化`}
          >
            <div className="chart-y-label">数量</div>
            <div className="chart-plot">
              {rows.map((row) => (
                <div className="bar-column" key={row.id}>
                  <button
                    className="chart-bar"
                    style={{
                      height: `${(Math.max(0, Number(row[metric] || 0)) / maximum) * 190}px`,
                    }}
                    title={`${row.id}：${row[metric] ?? 0}`}
                    aria-label={`${row.id}，${metrics.find((item) => item.key === metric)?.label} ${row[metric] ?? 0}`}
                  >
                    <span>{String(row[metric] ?? 0)}</span>
                  </button>
                  <time>{row.id.slice(5)}</time>
                </div>
              ))}
            </div>
          </div>
        ) : (
          <Empty
            title="该时间范围还没有对应记录"
            description="发生真实操作后，这里会显示每日变化。"
            icon={<BarChart3 size={30} strokeWidth={1.4} />}
          />
        )}
      </section>
      <section className="panel">
        <div className="section-heading">
          <h2>每日明细</h2>
          <span className="muted">{rows.length} 天</span>
        </div>
        <Table
          rows={rows}
          emptyTitle="暂无统计明细"
          columns={[
            { key: "date", label: "日期" },
            ...metrics.map((item) => ({
              key: item.key,
              label: item.label,
              numeric: true,
              render: (row: Row) =>
                typeof row[item.key] === "number" ? String(row[item.key]) : "—",
            })),
          ]}
        />
      </section>
    </>
  );
}
