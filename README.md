# 心灵港湾

面向高校的心理支持应用。学生可以与可定制的 3D AI 伙伴聊天、在社区表达感受、预约心理老师或朋辈同学。工作人员用同一个 App 的工作模式或浏览器工作台处理预约、人工消息、回访和转介。学校管理员通过工作台维护人员、内容、模型接入和额度。

## 本地运行

需要 Go 1.26.4、PostgreSQL 17、Node.js 和 Flutter 3.50。通过 Docker 启动 PostgreSQL，或者在 `.env` 中连接现有数据库。

```sh
docker compose up -d postgres
cp .env.example .env
```

编辑 `.env`，给 `HARBOR_ADMIN_PASSWORD` 设置自己的密码。后端第一次启动时执行数据库迁移并创建这个管理员。管理员从工作台创建工作人员，授予老师或朋辈身份并启用接待资料。学生可在 App 自助注册，管理员可在学校设置中关闭注册。

```sh
make console
make mobile-web

set -a
. ./.env
set +a
export HARBOR_CONSOLE_DIR="$PWD/apps/console/dist"
export HARBOR_MOBILE_DIR="$PWD/apps/mobile/build/web"
make backend
```

打开 [运营及工作人员工作台](http://127.0.0.1:8080/) 或 [学生及工作人员 App 网页版](http://127.0.0.1:8080/mobile/)。Web 构建与 Go API 同源，可以使用通用的会话和资源配置。开发工作台也可以在 `apps/console` 执行 `npm run dev`，Vite 默认将 API 代理到 8080。

### 原生 App

进入 `apps/mobile` 执行 `flutter run`。Android 模拟器默认访问 `10.0.2.2:8080`，iOS 模拟器默认访问 `127.0.0.1:8080`。真机通过以下命令指定可达的服务地址。

```sh
flutter run --dart-define=HARBOR_API_URL=https://your-campus-host
```

Android 安装包可用 `flutter build apk --dart-define=HARBOR_API_URL=...` 构建。iOS 使用 Xcode 和对应签名配置。角色模型、预览、动作和视口随 App 打包，旋转和编辑在设备上运行。

### 发布 iOS TestFlight 内测

PR 合并进 `main` 会触发 [iOS TestFlight 工作流](.github/workflows/testflight.yml)。工作流按锁文件安装 Flutter 依赖，归档并签名上传内测联网版。App Store Connect 在处理完成后把构建分发给已启用自动分发的内部测试组。安装设备需要能访问部署的后端，并在提示时允许 App 访问本地网络。

在 GitHub 的 `testflight` 环境中把部署分支限制为 `main`，并设置以下变量和 Secrets。

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | Apple Developer Team ID |
| Secret | `APP_STORE_CONNECT_KEY_ID` | App Store Connect 团队 API Key 的 Key ID |
| Secret | `APP_STORE_CONNECT_ISSUER_ID` | 该 API Key 所属团队的 Issuer ID |
| Secret | `APP_STORE_CONNECT_KEY_P8_BASE64` | 该 API Key 下载的 `.p8` 文件，使用 Base64 编码 |
| Secret | `APPLE_DISTRIBUTION_P12_BASE64` | Apple Distribution 证书及私钥导出的 `.p12` 文件，使用 Base64 编码 |
| Secret | `APPLE_DISTRIBUTION_P12_PASSWORD` | 导出上述 `.p12` 文件时设置的密码 |
| Secret | `APPLE_APP_STORE_PROFILE_BASE64` | 与上述证书配套的 App Store Connect 描述文件，使用 Base64 编码 |
| Secret | `HARBOR_API_URL` | iPhone 可访问的后端 URL |

构建使用专用的 Apple Distribution 证书和 `dev.oines.xlgw` 的 App Store Connect 描述文件签名，团队 API Key 用于上传。证书更新时需要同时更新与之配套的描述文件。若使用 HTTP，构建会按后端主机生成对应的 iOS 网络例外。版本从 `apps/mobile/pubspec.yaml` 读取，构建号由 Actions 运行编号和尝试次数生成。

发布失败时，在 GitHub Actions 查看失败步骤。可重跑失败的任务，也可在 Actions 的 iOS TestFlight 页面从 `main` 手动触发。

### 导出离线 Mock APK

改完功能后，在仓库根目录运行 `make mobile-mock-apk`，把生成的 `dist/心灵港湾-Mock.apk` 发给体验者。命令会用当前工作区的源码构建。可用 `./scripts/export-mock-apk.sh /path/to/demo.apk` 指定导出文件，或用 `make mobile-mock-apk FLUTTER=/path/to/flutter` 指定 SDK。

安装后点「进入离线体验」，可切换学生、老师和朋辈空间。APK 使用独立包名，可和联网版同时安装。离线数据和预设回复都在设备上运行，无需配置服务器。新增流程如果依赖新接口，需要在 `apps/mobile/lib/mock/` 里补对应的本地行为。APK 使用本机的 Android 调试密钥签名，覆盖安装时需要沿用同一密钥。

### 模型配置

管理工作台的「模型网关」可配置 OpenAI 兼容连接。服务器配置 `AI_ENCRYPTION_KEY` 后支持在工作台保存加密的供应商密钥。也可以在启动时通过 `AI_API_KEY`、`AI_BASE_URL`、`AI_MODEL` 初始化连接。学校名称、接待地点、服务时间和联系渠道在工作台维护。

新库仅有默认规则和资源定义。注册、发帖、预约、消息和统计来自实际操作。聊天上下文保存在 Astral Core 的 Host PostgreSQL Store，模型调用账本独立记录用量，用户的聊天历史可在多端读取。

## 测试

```sh
export XL_GW_TEST_DATABASE_URL='postgres://harbor:harbor_local@127.0.0.1:5432/postgres?sslmode=disable'
make test
```

后端集成测试通过实际 HTTP API 和 PostgreSQL 运行，为每条套件创建并清理隔离数据库。覆盖预约并发、学生和工作人员授权、服务会话、回访、转交、举报、屏蔽、形象保存，以及 Astral 的流式输出、工具调用、限额、失败重试和重启恢复。AI 测试用受控 HTTP 供应商测试端点，观测真实出站请求及用量。

浏览器测试需要一个独立的空测试库及该库的后端服务。在 `apps/console` 先运行 `npm ci` 和 `npx playwright install chromium`，然后设置 `E2E_API_ORIGIN`、`E2E_ADMIN_ACCOUNT`、`E2E_ADMIN_PASSWORD`，执行 `npm run test:e2e`。浏览器测试会注册自己的账号并走真实业务流程。Flutter 网页版端到端使用相同的测试服务，部署 /mobile/ 后执行 npm run test:mobile。

## 项目结构

- `apps/mobile` 是 Flutter 学生和工作人员 App。
- `apps/console` 是 React Web 工作台。
- `backend` 是 Go API、业务模块、AI Host 和 PostgreSQL 迁移。
- `art` 保存模型授权、视口源码、验收工具和热更新发布脚本。
- [API 契约](packages/contracts/api.md) 与 [总体架构](docs/architecture/01-总体架构.md) 可用于联调与维护。

伙伴外观采用授权明确的 CC0 玩具风动物模型。原生客户端自带默认资源，也可在部署端发布新版 GLB 和图像。发布、预览和回滚见 [3D 资源说明](art/README.md)。
