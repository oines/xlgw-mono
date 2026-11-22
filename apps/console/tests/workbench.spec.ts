import {
  test,
  expect,
  request,
  type APIRequestContext,
  type Page,
} from "@playwright/test";

const apiOrigin = process.env.E2E_API_ORIGIN || "http://127.0.0.1:8080";
const adminAccount = process.env.E2E_ADMIN_ACCOUNT;
const adminPassword = process.env.E2E_ADMIN_PASSWORD;
const stamp = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`;
const password = `Harbor-${stamp}-safe`;
const teacherAccount = `teacher_${stamp}`;
const studentAccount = `student_${stamp}`;
let admin: APIRequestContext;
let student: APIRequestContext;
let teacherId: string;

async function apiLogin(account: string, secret: string) {
  const context = await request.newContext({
    baseURL: apiOrigin,
    extraHTTPHeaders: { Origin: apiOrigin },
  });
  const response = await context.post("/api/v1/auth/login", {
    data: { account, password: secret },
  });
  expect(
    response.ok(),
    `真实 API 登录应成功，HTTP ${response.status()}`,
  ).toBeTruthy();
  return context;
}

async function login(page: Page, account: string, secret: string) {
  await page.goto("/");
  await page.getByLabel("账号", { exact: true }).fill(account);
  await page.getByLabel("密码", { exact: true }).fill(secret);
  await page.getByRole("button", { name: "登录工作台", exact: true }).click();
  await expect(page.getByRole("navigation", { name: "主导航" })).toBeVisible();
}

async function action(page: Page, name: string) {
  await page.getByRole("button", { name, exact: true }).click();
  await page.getByRole("button", { name: "确认操作", exact: true }).click();
}

test.beforeAll(async () => {
  if (!adminAccount || !adminPassword)
    throw new Error(
      "请为隔离测试后端设置 E2E_ADMIN_ACCOUNT、E2E_ADMIN_PASSWORD 和 E2E_API_ORIGIN。测试使用真实 API 创建账号和业务记录。",
    );
  admin = await apiLogin(adminAccount, adminPassword);
  const teacher = await admin.post("/api/v1/admin/users", {
    data: {
      account: teacherAccount,
      password,
      nickname: "集成测试老师",
      roles: ["teacher"],
    },
  });
  expect(teacher.ok()).toBeTruthy();
  teacherId = (await teacher.json()).id;
  const profile = await admin.put(`/api/v1/admin/staff/${teacherId}`, {
    data: {
      role: "teacher",
      bio: "隔离测试环境的接待账号",
      modes: ["online"],
      location: "",
      active: true,
    },
  });
  expect(profile.ok()).toBeTruthy();
  const register = await admin.post("/api/v1/admin/users", {
    data: {
      account: studentAccount,
      password,
      nickname: "集成测试同学",
      roles: ["student"],
    },
  });
  expect(register.ok()).toBeTruthy();
  student = await apiLogin(studentAccount, password);
});

test.afterAll(async () => {
  await admin?.dispose();
  await student?.dispose();
});

test("老师能发布时段、确认真实预约、交流、结束服务并完成回访跟进", async ({
  page,
}) => {
  await login(page, teacherAccount, password);
  await expect(
    page.getByRole("link", { name: "成员与人员", exact: true }),
  ).toHaveCount(0);
  await page.getByRole("link", { name: "预约与排班", exact: true }).click();
  await page.getByRole("button", { name: "发布可约时段", exact: true }).click();
  const start = new Date();
  start.setDate(start.getDate() + 2);
  start.setHours(10, 0, 0, 0);
  const local = new Date(start);
  local.setMinutes(local.getMinutes() - local.getTimezoneOffset());
  await page.getByLabel("开始时间").fill(local.toISOString().slice(0, 16));
  await page.getByRole("button", { name: "发布时段", exact: true }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "可约时段已发布" }),
  ).toBeVisible();
  const slotsResponse = await student.get(
    `/api/v1/slots?staff_id=${teacherId}`,
  );
  expect(slotsResponse.ok()).toBeTruthy();
  const slots = (await slotsResponse.json()).items;
  const slot = slots.find(
    (item: { start_at: string }) =>
      new Date(item.start_at).getTime() === start.getTime(),
  );
  expect(slot).toBeTruthy();
  const bookingResponse = await student.post("/api/v1/appointments", {
    data: {
      id: crypto.randomUUID(),
      slot_id: slot.id,
      note: "想聊一聊最近的学习安排。",
    },
  });
  expect(bookingResponse.ok()).toBeTruthy();
  const bookingId = (await bookingResponse.json()).id;
  await page.goto(`/appointments?selected=${bookingId}`);
  await expect(
    page.getByRole("heading", { name: "预约详情", exact: true }),
  ).toBeVisible();
  await action(page, "确认预约");
  await expect
    .poll(
      async () =>
        (await (await student.get(`/api/v1/appointments/${bookingId}`)).json())
          .status,
    )
    .toBe("confirmed");
  const booking = await (
    await student.get(`/api/v1/appointments/${bookingId}`)
  ).json();
  await page.goto(`/inbox?selected=${booking.conversation_id}`);
  await page
    .getByRole("textbox", { name: "回复同学", exact: true })
    .fill("你好，我们可以一起聊聊。");
  await page.getByRole("button", { name: "发送", exact: true }).click();
  await expect(
    page
      .locator(".message-bubble")
      .filter({ hasText: "你好，我们可以一起聊聊。" }),
  ).toBeVisible();
  const messageResponse = await student.get(
    `/api/v1/conversations/${booking.conversation_id}/messages`,
  );
  expect(
    (await messageResponse.json()).items.some(
      (item: { body: string }) => item.body === "你好，我们可以一起聊聊。",
    ),
  ).toBeTruthy();
  await page.goto(`/appointments?selected=${bookingId}`);
  await action(page, "开始服务");
  await expect(
    page.getByRole("button", { name: "结束服务", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "结束服务", exact: true }).click();
  await page.getByLabel("内部服务记录").fill("已完成本次交流。");
  await page
    .getByLabel("给同学的下一步安排")
    .fill("请在回访问卷中告诉我后来的感受。");
  await page.getByRole("button", { name: "确认操作", exact: true }).click();
  await expect
    .poll(
      async () =>
        (await (await student.get(`/api/v1/appointments/${bookingId}`)).json())
          .status,
    )
    .toBe("completed");
  let followupId = "";
  await expect
    .poll(async () => {
      const response = await student.get("/api/v1/followups");
      const row = (await response.json()).items.find(
        (item: { service_id: string }) =>
          item.service_id === booking.service_id,
      );
      followupId = row?.id || "";
      return Boolean(followupId);
    })
    .toBeTruthy();
  const answer = await student.post(`/api/v1/followups/${followupId}/submit`, {
    data: {
      mood: "same",
      helpfulness: "helpful",
      note: "希望再联系一次。",
      contact_requested: true,
    },
  });
  expect(answer.ok()).toBeTruthy();
  await page.goto(`/followups?selected=${followupId}`);
  await page.getByRole("button", { name: "记录联系", exact: true }).click();
  await page.getByLabel("处理记录").fill("已再次联系同学。");
  await page.getByRole("button", { name: "确认保存", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "结案", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "结案", exact: true }).click();
  await page.getByLabel("处理记录").fill("已完成本次跟进。");
  await page.getByRole("button", { name: "确认保存", exact: true }).click();
  await expect
    .poll(
      async () =>
        (await (await student.get(`/api/v1/followups/${followupId}`)).json())
          .status,
    )
    .toBe("closed");
});

test("管理员拥有运营入口，内容发布和撤回都作用于真实学生接口", async ({
  page,
}) => {
  await login(page, adminAccount!, adminPassword!);
  await expect(
    page.getByRole("link", { name: "成员与人员", exact: true }),
  ).toBeVisible();
  await page.getByRole("link", { name: "内容与活动", exact: true }).click();
  await page.getByRole("button", { name: "创建内容", exact: true }).click();
  const title = `测试校园活动 ${stamp}`;
  await page.getByLabel("内容分类").selectOption("activity");
  await page.getByRole("textbox", { name: "标题", exact: true }).fill(title);
  await page
    .getByRole("textbox", { name: "正文", exact: true })
    .fill("隔离环境里验证内容发布和撤回。");
  await page.getByLabel("公开发布").check();
  await page.getByRole("button", { name: "保存内容", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: title, exact: true }),
  ).toBeVisible();
  const publishedResponse = await student.get(
    "/api/v1/resources?kind=activity",
  );
  const publishedBody = await publishedResponse.json();
  const items = Array.isArray(publishedBody)
    ? publishedBody
    : publishedBody.items;
  expect(
    items.some((item: { title: string }) => item.title === title),
  ).toBeTruthy();
  await page.getByRole("button", { name: `删除${title}`, exact: true }).click();
  await page.getByRole("button", { name: "确认删除", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: title, exact: true }),
  ).toHaveCount(0);
  await page.setViewportSize({ width: 1024, height: 900 });
  await page.getByRole("link", { name: "模型与用量", exact: true }).click();
  await page.getByRole("tab", { name: "实际调用", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "模型与用量", exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBeTruthy();
});
