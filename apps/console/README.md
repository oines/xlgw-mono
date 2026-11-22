# 心灵港湾 Web 工作台

同一套 React / TypeScript 应用供心理老师、朋辈同学和运营管理员使用。界面通过真实 API 读写数据，空库显示空状态。

## 启动

```sh
npm install
npm run dev
```

默认打开 `http://localhost:5173`。开发服务器将 `/api` 和 `/uploads` 代理到 `http://127.0.0.1:8080`。后端地址可通过 `API_PROXY_TARGET` 修改。生产环境推荐将前端静态文件与 `/api/v1` 部署在同一域名下。

```sh
API_PROXY_TARGET=http://127.0.0.1:8081 npm run dev
npm run build
```

`dist/` 是生产构建产物。HTML 路由需要回退到 `index.html`，API 路由应转发给 Go 服务。使用同源 HttpOnly 会话 Cookie，前端不会持久化模型密钥或登录密码。

管理员由后端初始化。老师和朋辈使用已有工作账号登录，学生账号会看到身份说明，运营页面只对管理员开放。

## 业务页面

- 工作概览、工作通知、预约列表和周历、可约时间。
- 服务消息、学生授权资料、服务转交、回访与人工求助。
- 账号与接待身份、社区举报、应用反馈、学校内容和活动。
- 学校规则、真实统计、模型连接、用途路由、实际调用与个人额度。
- 本人接待资料、昵称和密码设置。

接口依据仓库中的 `packages/contracts/api.md`。API 错误显示在当前操作区域，只有服务器确认成功后才展示成功反馈。

## 验证

```sh
npm run typecheck
npm run build
npx playwright install chromium
```

Playwright 测试向隔离测试后端创建真实账号、预约、消息、回访与内容记录。运行前应启动空的测试数据库与后端，并配置可登录的管理员。不要指向正式环境。

```sh
E2E_API_ORIGIN=http://127.0.0.1:8081 \
E2E_ADMIN_ACCOUNT="$TEST_ADMIN_ACCOUNT" \
E2E_ADMIN_PASSWORD="$TEST_ADMIN_PASSWORD" \
npm run test:e2e
```

测试自动启动端口 5174 的前端，通过真实 API 完成老师接待闭环及运营内容发布/删除，并检查角色入口与窄窗口布局。失败时保留截图和 trace。

Flutter 移动端有独立的真实浏览器验证入口。先构建 Flutter Web 并由同一测试后端提供 `/mobile/`，然后运行：

```sh
E2E_API_ORIGIN=http://127.0.0.1:18080 \
E2E_ADMIN_ACCOUNT="$TEST_ADMIN_ACCOUNT" \
E2E_ADMIN_PASSWORD="$TEST_ADMIN_PASSWORD" \
npm run test:mobile
```

该入口验证学生注册、选择校内人员、提交预约，以及老师在 App 中确认和结束服务、朋辈切换工作身份与进入排班。浏览器报告、失败 trace 和截图默认存入系统临时目录下的 `xlgw-console-verification`，可用 `E2E_ARTIFACT_DIR` 和 `E2E_SCREENSHOT_DIR` 指定位置。
