import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { MessageSquare, ShieldCheck } from "lucide-react";
import { useList, useWrite } from "../lib/data";
import { dateTime, text, type Row } from "../lib/api";
import {
  Button,
  DetailList,
  Drawer,
  ErrorNotice,
  Field,
  Loading,
  PageHeader,
  Person,
  Status,
  Table,
  Tabs,
  useToast,
} from "../components/ui";

export function ModerationPage() {
  const [params, setParams] = useSearchParams();
  const [tab, setTab] = useState("reports");
  const [selected, setSelected] = useState<Row | null>(null);
  const [action, setAction] = useState("dismiss");
  const [reply, setReply] = useState("");
  const reports = useList("/admin/reports");
  const feedback = useList("/admin/feedback");
  const mutation = useWrite();
  const toast = useToast();
  const all = tab === "reports" ? reports : feedback;
  const fromParams = [
    ...(reports.data?.items || []),
    ...(feedback.data?.items || []),
  ].find((row) => row.id === params.get("selected"));
  const row = selected || fromParams;
  const isReport = Boolean(row?.target_type);
  function close() {
    setSelected(null);
    setParams({});
    setReply("");
    mutation.reset();
  }
  async function save() {
    if (!row) return;
    try {
      await mutation.mutateAsync({
        path: isReport
          ? `/admin/reports/${row.id}/resolve`
          : `/admin/feedback/${row.id}`,
        method: isReport ? "POST" : "PATCH",
        data: isReport ? { action, result: reply } : { status: action, reply },
      });
      toast("处理结果已保存并通知同学");
      close();
    } catch {
      /* Inline error. */
    }
  }
  const reasonLabels: Record<string, string> = {
    post: "社区帖子",
    comment: "评论",
    message: "私聊消息",
  };
  return (
    <>
      <PageHeader
        title="社区与反馈"
        description="维护友善的交流环境，也认真回应产品意见。"
      />
      <Tabs
        value={tab}
        onChange={setTab}
        items={[
          {
            value: "reports",
            label: "内容举报",
            count: reports.data?.items.filter(
              (row) => !["resolved", "closed"].includes(text(row, "status")),
            ).length,
          },
          {
            value: "feedback",
            label: "应用反馈",
            count: feedback.data?.items.filter(
              (row) => row.status !== "resolved",
            ).length,
          },
        ]}
      />
      <ErrorNotice error={all.error} retry={() => void all.refetch()} />
      <section className="panel">
        <div className="section-heading">
          <h2>
            {tab === "reports" ? (
              <>
                <ShieldCheck size={18} />
                内容处理
              </>
            ) : (
              <>
                <MessageSquare size={18} />
                同学的声音
              </>
            )}
          </h2>
        </div>
        {all.isLoading ? (
          <Loading />
        ) : (
          <Table
            rows={all.data?.items || []}
            onRow={(item) => {
              setSelected(item);
              setAction(
                tab === "reports"
                  ? "dismiss"
                  : text(item, "status") || "processing",
              );
              setReply(text(item, "reply", "result"));
              mutation.reset();
            }}
            emptyTitle={
              tab === "reports" ? "目前没有内容举报" : "暂时没有应用反馈"
            }
            emptyDescription={
              tab === "reports"
                ? "同学提交举报后，可以在这里核查与处理。"
                : "App 中提交的问题和建议会汇集到这里。"
            }
            columns={
              tab === "reports"
                ? [
                    {
                      key: "target",
                      label: "内容类型",
                      render: (item) =>
                        reasonLabels[text(item, "target_type")] || "内容",
                    },
                    { key: "reporter_name", label: "举报人" },
                    {
                      key: "reason",
                      label: "原因",
                      render: (item) => (
                        <span className="truncate-cell">
                          {text(item, "reason")}
                        </span>
                      ),
                    },
                    {
                      key: "date",
                      label: "提交时间",
                      render: (item) => dateTime(item.created_at),
                    },
                    {
                      key: "status",
                      label: "状态",
                      render: (item) => <Status value={item.status} />,
                    },
                  ]
                : [
                    {
                      key: "student",
                      label: "同学",
                      render: (item) => <Person row={item} />,
                    },
                    { key: "category", label: "分类" },
                    {
                      key: "body",
                      label: "反馈内容",
                      render: (item) => (
                        <span className="truncate-cell">
                          {text(item, "body")}
                        </span>
                      ),
                    },
                    {
                      key: "date",
                      label: "提交时间",
                      render: (item) => dateTime(item.created_at),
                    },
                    {
                      key: "status",
                      label: "状态",
                      render: (item) => <Status value={item.status} />,
                    },
                  ]
            }
          />
        )}
      </section>
      {row && (
        <Drawer
          title={isReport ? "处理内容举报" : "回复应用反馈"}
          subtitle={dateTime(row.created_at)}
          onClose={close}
          footer={
            <Button
              tone="primary"
              disabled={!reply.trim()}
              busy={mutation.isPending}
              onClick={() => void save()}
            >
              保存处理结果
            </Button>
          }
        >
          <ErrorNotice error={mutation.error} />
          <DetailList
            items={
              isReport
                ? [
                    { label: "举报人", value: text(row, "reporter_name") },
                    { label: "内容作者", value: text(row, "author_name") },
                    { label: "举报原因", value: text(row, "reason") },
                    { label: "补充说明", value: text(row, "note") },
                  ]
                : [
                    { label: "同学", value: text(row, "student_name") },
                    { label: "分类", value: text(row, "category") },
                    { label: "联系方式", value: text(row, "contact") },
                  ]
            }
          />
          <div className="detail-note">
            <h3>{isReport ? "被举报的内容" : "反馈内容"}</h3>
            <p>
              {isReport
                ? typeof row.evidence === "string"
                  ? row.evidence
                  : JSON.stringify(row.evidence, null, 2)
                : text(row, "body")}
            </p>
          </div>
          <Field label="处理方式">
            <select
              value={action}
              onChange={(event) => setAction(event.target.value)}
            >
              {isReport ? (
                <>
                  <option value="dismiss">驳回举报，保留内容</option>
                  <option value="remove">下架内容</option>
                  <option value="restrict">限制账号</option>
                </>
              ) : (
                <>
                  <option value="pending">待处理</option>
                  <option value="processing">处理中</option>
                  <option value="resolved">已解决</option>
                </>
              )}
            </select>
          </Field>
          <Field label={isReport ? "给举报人的处理说明" : "回复同学"} required>
            <textarea
              rows={5}
              value={reply}
              onChange={(event) => setReply(event.target.value)}
            />
          </Field>
        </Drawer>
      )}
    </>
  );
}
