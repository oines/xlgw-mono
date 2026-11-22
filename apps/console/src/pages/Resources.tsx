import { useState } from "react";
import {
  ArrowUpRight,
  BookOpen,
  CalendarDays,
  FileText,
  Megaphone,
  Plus,
  Trash2,
} from "lucide-react";
import { useList, useWrite } from "../lib/data";
import { dateTime, text, type Row } from "../lib/api";
import {
  Button,
  Drawer,
  Empty,
  EntityForm,
  ErrorNotice,
  Loading,
  PageHeader,
  SearchInput,
  Tabs,
  useToast,
} from "../components/ui";

const kinds = [
  { value: "article", label: "心理知识", icon: BookOpen },
  { value: "activity", label: "校园活动", icon: CalendarDays },
  { value: "announcement", label: "校园公告", icon: Megaphone },
  { value: "support", label: "求助资源", icon: FileText },
];
export function ResourcesPage() {
  const [tab, setTab] = useState("all");
  const [search, setSearch] = useState("");
  const [editing, setEditing] = useState<Row | "new" | null>(null);
  const [deleting, setDeleting] = useState<Row | null>(null);
  const list = useList("/admin/resources");
  const mutation = useWrite();
  const toast = useToast();
  const rows = (list.data?.items || []).filter(
    (row) =>
      (tab === "all" || row.kind === tab) &&
      text(row, "title").includes(search),
  );
  return (
    <>
      <PageHeader
        title="内容与活动"
        description="把值得了解的知识、活动和校内支持带到同学身边。"
        action={
          <Button
            tone="primary"
            onClick={() => {
              mutation.reset();
              setEditing("new");
            }}
          >
            <Plus size={17} />
            创建内容
          </Button>
        }
      />
      <Tabs
        value={tab}
        onChange={setTab}
        items={[{ value: "all", label: "全部内容" }, ...kinds]}
      />
      <ErrorNotice error={list.error} retry={() => void list.refetch()} />
      <div className="toolbar plain-toolbar">
        <span className="muted">{rows.length} 项内容</span>
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder="搜索标题"
        />
      </div>
      {list.isLoading ? (
        <Loading />
      ) : rows.length ? (
        <div className="resource-grid">
          {rows.map((row) => {
            const kind =
              kinds.find((item) => item.value === row.kind) || kinds[0];
            return (
              <article className="resource-card" key={row.id}>
                <header>
                  <span className="resource-kind">
                    <kind.icon size={17} />
                    {kind.label}
                  </span>
                  <span
                    className={`status status-${row.published ? "brand" : "muted"}`}
                  >
                    {row.published ? "已发布" : "草稿"}
                  </span>
                </header>
                <h2>{text(row, "title")}</h2>
                <p>{text(row, "body")}</p>
                <footer>
                  <time>{dateTime(row.created_at, true)}</time>
                  <div>
                    <Button
                      tone="ghost"
                      onClick={() => {
                        mutation.reset();
                        setEditing(row);
                      }}
                    >
                      编辑 <ArrowUpRight size={14} />
                    </Button>
                    <button
                      className="icon-button"
                      aria-label={`删除${text(row, "title")}`}
                      onClick={() => {
                        mutation.reset();
                        setDeleting(row);
                      }}
                    >
                      <Trash2 size={16} />
                    </button>
                  </div>
                </footer>
              </article>
            );
          })}
        </div>
      ) : (
        <section className="panel">
          <Empty
            title="还没有这类内容"
            description="发布真实的校内活动、知识文章或求助资源。"
            action={
              <Button onClick={() => setEditing("new")}>
                <Plus size={15} />
                创建第一篇内容
              </Button>
            }
          />
        </section>
      )}
      {editing && (
        <Drawer
          title={editing === "new" ? "创建内容" : "编辑内容"}
          subtitle="已发布的内容将出现在学生 App 中。"
          onClose={() => setEditing(null)}
        >
          <EntityForm
            key={editing === "new" ? "new" : editing.id}
            initial={
              editing === "new"
                ? { kind: tab === "all" ? "article" : tab, published: false }
                : editing
            }
            pending={mutation.isPending}
            error={mutation.error}
            fields={[
              {
                name: "kind",
                label: "内容分类",
                type: "select",
                required: true,
                options: kinds,
              },
              { name: "title", label: "标题", required: true },
              { name: "body", label: "正文", type: "textarea", required: true },
              { name: "url", label: "相关链接（选填）", type: "url" },
              {
                name: "published",
                label: "公开发布",
                type: "checkbox",
                hint: "开启后学生可见，关闭后保存为草稿。",
              },
            ]}
            submitLabel="保存内容"
            onSubmit={async (values) => {
              try {
                await mutation.mutateAsync({
                  path:
                    editing === "new"
                      ? "/admin/resources"
                      : `/admin/resources/${editing.id}`,
                  method: editing === "new" ? "POST" : "PATCH",
                  data: values,
                });
                setEditing(null);
                toast("内容已保存");
              } catch {
                /* Inline error. */
              }
            }}
          />
        </Drawer>
      )}
      {deleting && (
        <Drawer
          title="删除内容"
          onClose={() => setDeleting(null)}
          footer={
            <>
              <Button onClick={() => setDeleting(null)}>保留</Button>
              <Button
                tone="danger"
                busy={mutation.isPending}
                onClick={async () => {
                  try {
                    await mutation.mutateAsync({
                      path: `/admin/resources/${deleting.id}`,
                      method: "DELETE",
                    });
                    setDeleting(null);
                    toast("内容已删除");
                  } catch {
                    /* Inline error. */
                  }
                }}
              >
                确认删除
              </Button>
            </>
          }
        >
          <ErrorNotice error={mutation.error} />
          <p>删除「{text(deleting, "title")}」后，学生将无法再看到这篇内容。</p>
        </Drawer>
      )}
    </>
  );
}
