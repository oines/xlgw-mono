# 3D 陪伴角色

团团猫、暖暖狐和咕咕鸮来自 Vuena 发布的 [Cute Pets & Wildlife 免费样本 v3.1](https://vuena.itch.io/blocky-pets-free)。三个 GLB 包含骨骼、12 条动作与贴图，附带的 [CC0 文件](VUENA-CC0.txt)覆盖这三款模型、贴图和动画。模型原文件仅改名存入 `apps/mobile/assets/companion`。App 自己实现口型尺寸、头脸和耳部调整、换色、领结以及聊天动作映射。

## 本机预览与截图

```sh
npm --prefix art ci
npm --prefix art run bundle
python3 -m http.server 8347 --directory apps/mobile/assets/companion
```

可打开 [本地三维视口](http://localhost:8347/studio.html)。另一个终端运行 `node art/verify.mjs` 可检查模型实际加载、刷新缩略图并验证倾听和招呼动作。它使用 Playwright Chromium，可先在 `art` 执行 `npx playwright install chromium`，或提供本机 Chrome 路径 `CHROMIUM_PATH`。

## 热更新

原生和网页客户端共用内置渲染器。可更新 GLB 和图片，动作片段可随 GLB 发布。发布文件须延续三个预设槽和本版骨骼/动作名称。已有账户的参数继续适用，拓扑协议变更需要新 App。

```sh
export HARBOR_COMPANION_DIR=/absolute/path/to/companion-releases
python3 art/publish_assets.py "$HARBOR_COMPANION_DIR" pets-20261114.1
```

Go 启动时读取目录位置，后续新版本通过原子替换目录里的 `current` 文件立即生效。回滚可将其改回已有 release。原生 App 检查清单、逐文件校验 SHA-256 和长度，并在整包完成后切换；远端故障回退到有效缓存或内置资产。网页版同源加载模型，可回退到内置资源。预览和编辑过程中选择的参数保存在 PostgreSQL。
