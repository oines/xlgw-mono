import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  test,
  expect,
  request,
  type APIRequestContext,
  type Page,
  type Locator,
} from "@playwright/test";

const origin = process.env.E2E_API_ORIGIN || "http://127.0.0.1:18080";
const stamp = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`;
const password = `Harbor-${stamp}-safe`;
const teacherAccount = `mobileteacher_${stamp}`;
const studentAccount = `mobilestudent_${stamp}`;
const peerAccount = `mobilepeer_${stamp}`;
const teacherName = `手机老师${stamp.slice(-4)}`;
const studentName = `手机同学${stamp.slice(-4)}`;
let admin: APIRequestContext;
let teacher: APIRequestContext;
let teacherId: string;
let slotTime: string;
const screenshotRoot =
  process.env.E2E_SCREENSHOT_DIR ||
  join(tmpdir(), "xlgw-console-verification", "screenshots");

async function loginApi(account: string, password: string) {
  const client = await request.newContext({
    baseURL: origin,
    extraHTTPHeaders: { Origin: origin },
  });
  const response = await client.post("/api/v1/auth/login", {
    data: { account, password },
  });
  expect(response.ok(), `真实 API 登录失败 ${response.status()}`).toBeTruthy();
  return client;
}

async function openApp(page: Page) {
  await page.goto("/mobile/");
  await page.locator("flutter-view").waitFor({ timeout: 30000 });
  const placeholder = page.locator("flt-semantics-placeholder");
  if (await placeholder.count())
    await placeholder.evaluate((element) => (element as HTMLElement).click());
  await page.getByRole("button", { name: "登录", exact: true }).waitFor();
}

async function fillFlutter(field: Locator, value: string) {
  await field.click();
  await expect(field).toBeFocused();
  // Flutter may replace the semantic input after focus. Type into the
  // active field and verify its value before moving to the next control.
  await expect(async () => {
    await field.press("ControlOrMeta+A");
    await field.press("Backspace");
    await field.pressSequentially(value, { delay: 32 });
    await expect(field).toHaveValue(value, { timeout: 600 });
  }).toPass({ timeout: 9000 });
}

async function loginApp(page: Page, account: string) {
  await openApp(page);
  await fillFlutter(
    page.getByRole("textbox", { name: "账号", exact: true }),
    account,
  );
  await fillFlutter(
    page.getByRole("textbox", { name: "密码", exact: true }),
    password,
  );
  await page.getByRole("button", { name: "登录", exact: true }).click();
}

test.beforeAll(async () => {
  await mkdir(screenshotRoot, { recursive: true });
  const account = process.env.E2E_ADMIN_ACCOUNT;
  const secret = process.env.E2E_ADMIN_PASSWORD;
  if (!account || !secret)
    throw new Error(
      "移动端 smoke 需要隔离后端及 E2E_ADMIN_ACCOUNT、E2E_ADMIN_PASSWORD。先构建并提供同源 /mobile/。",
    );
  admin = await loginApi(account, secret);
  let response = await admin.post("/api/v1/admin/users", {
    data: {
      account: teacherAccount,
      password,
      nickname: teacherName,
      roles: ["teacher"],
    },
  });
  expect(response.ok()).toBeTruthy();
  teacherId = (await response.json()).id;
  response = await admin.put(`/api/v1/admin/staff/${teacherId}`, {
    data: {
      role: "teacher",
      bio: "真实接口手机端测试接待",
      modes: ["online"],
      location: "",
      active: true,
    },
  });
  expect(response.ok()).toBeTruthy();
  teacher = await loginApi(teacherAccount, password);
  const start = new Date();
  start.setMinutes(start.getMinutes() + 30, 0, 0);
  slotTime = new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "Asia/Shanghai",
  }).format(start);
  response = await teacher.post("/api/v1/slots", {
    data: { start_at: start.toISOString(), mode: "online" },
  });
  expect(response.ok()).toBeTruthy();
  response = await admin.post("/api/v1/admin/users", {
    data: {
      account: peerAccount,
      password,
      nickname: `朋辈同学${stamp.slice(-4)}`,
      roles: ["student", "peer"],
    },
  });
  expect(response.ok()).toBeTruthy();
  const peerId = (await response.json()).id;
  response = await admin.put(`/api/v1/admin/staff/${peerId}`, {
    data: {
      role: "peer",
      bio: "手机端身份切换测试",
      modes: ["online"],
      supervisor_id: teacherId,
      active: true,
    },
  });
  expect(response.ok()).toBeTruthy();
});

test.afterAll(async () => {
  await admin?.dispose();
  await teacher?.dispose();
});

test("学生通过手机注册和预约，老师在同一个App接待并结束服务", async ({
  page,
  browser,
}) => {
  await openApp(page);
  await page
    .getByRole("button", { name: "首次使用，注册账号", exact: true })
    .click();
  await fillFlutter(page.getByRole("textbox", { name: /昵称/ }), studentName);
  await fillFlutter(
    page.getByRole("textbox", { name: "账号", exact: true }),
    studentAccount,
  );
  await fillFlutter(
    page.getByRole("textbox", { name: "密码", exact: true }),
    password,
  );
  await page.getByRole("button", { name: "注册并进入", exact: true }).click();
  await page.getByRole("button", { name: "找人聊聊", exact: true }).click();
  await page.getByRole("button", { name: new RegExp(teacherName) }).click();
  await page
    .getByRole("checkbox", { name: new RegExp(`${slotTime}.*线上文字`, "s") })
    .click();
  await page.getByRole("button", { name: "预约这次交流", exact: true }).click();
  await page.getByRole("button", { name: "提交预约", exact: true }).click();
  await expect(page.getByText("待确认", { exact: false })).toBeVisible();
  await page.screenshot({ path: join(screenshotRoot, "mobile-booking.png") });

  const response = await teacher.get("/api/v1/appointments?scope=work");
  const booking = (await response.json()).items.find(
    (item: { student_name: string }) => item.student_name === studentName,
  );
  expect(booking).toBeTruthy();
  const workContext = await browser.newContext({
    baseURL: origin,
    viewport: { width: 390, height: 844 },
    locale: "zh-CN",
    timezoneId: "Asia/Shanghai",
  });
  const workPage = await workContext.newPage();
  await loginApp(workPage, teacherAccount);
  await workPage
    .getByRole("button", {
      name: new RegExp(`${studentName}.*预约待确认`, "s"),
    })
    .click();
  await workPage.getByRole("button", { name: "确认预约", exact: true }).click();
  await expect(workPage.getByText("已确认", { exact: false })).toBeVisible();
  await workPage.getByRole("button", { name: "开始服务", exact: true }).click();
  await expect(
    workPage.getByRole("button", { name: "结束服务", exact: true }),
  ).toBeVisible();
  await workPage.getByRole("button", { name: "结束服务", exact: true }).click();
  await fillFlutter(
    workPage.getByRole("textbox", { name: /内部服务记录/ }),
    "手机端完成本次接待。",
  );
  await workPage.getByRole("button", { name: "确认完成", exact: true }).click();
  await expect(workPage.getByText("已完成", { exact: false })).toBeVisible();
  await expect
    .poll(
      async () =>
        (await (await teacher.get(`/api/v1/appointments/${booking.id}`)).json())
          .status,
    )
    .toBe("completed");
  await workPage
    .getByRole("button", { name: "查看咨询回访", exact: true })
    .click();
  await expect(workPage.getByText("回访与跟进", { exact: true })).toBeVisible();
  await workPage.screenshot({
    path: join(screenshotRoot, "mobile-work-followups.png"),
  });
  await workContext.close();
});

test("朋辈账号能选择工作身份并进入手机排班", async ({ page }) => {
  await loginApp(page, peerAccount);
  await page
    .getByRole("button", { name: /朋辈同学.*预约、接待和服务跟进/s })
    .click();
  await expect(
    page.getByText("今天，也从倾听开始。", { exact: false }),
  ).toBeVisible();
  await page.getByRole("button", { name: "管理排班", exact: true }).click();
  await expect(page.getByText("设置可约时间", { exact: true })).toBeVisible();
  await expect(
    page.getByText("每次 30 分钟，相邻时段间隔 10 分钟。", { exact: true }),
  ).toBeVisible();
  await page.screenshot({
    path: join(screenshotRoot, "mobile-peer-schedule.png"),
  });
});
