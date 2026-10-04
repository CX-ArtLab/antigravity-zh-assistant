<div align="center">
  <img src="src/Assets/assistant-icon.png" width="128" height="128" alt="Antigravity 中文助手 图标" />
  <h1>Antigravity 中文助手</h1>
  <p>面向 Windows / macOS (Apple Silicon) 的 Google Antigravity 极简外挂式界面汉化伴侣</p>
</div>

**Antigravity 中文助手**（`AntigravityZhAssistant`）是一个专为 Google Antigravity 桌面环境打造的非官方外挂式汉化伴侣程序。它通过 Chromium 本地调试接口（CDP）实现运行时界面汉化，不修改 Antigravity 官方二进制执行文件和核心签名，不破坏智能体执行与工作区沙箱功能，支持一键应用全中文界面，并随时可一键无损还原官方原版英文。

---

## 客户端下载与使用

### Windows 用户使用

1. 从 [Releases](https://github.com/CX-ARTLab/antigravity-zh-assistant/releases/latest) 下载最新版本的 `AntigravityZhAssistant-windows.zip`。
2. 将 ZIP 解压到任意文件夹。无需安装开发环境，也不需要将 EXE 放入 Antigravity 安装目录。
3. 先启动 Antigravity，再运行解压后的 `AntigravityZhAssistant.exe`。
4. 点击主卡片中的 **“立即应用汉化”** 状态胶囊按钮即可一键完成汉化。
5. 助手支持“后台监控”、“自动适配新词条”、“自动更新词典”与“随 Windows 启动”，启动后可常驻系统托盘静默守护。

> **便携版程序**：本程序为单文件绿色免安装应用，移动整个解压文件夹即可移动助手，卸载时在助手内点击恢复原版后直接删除该文件夹即可。

### macOS 用户使用（Apple Silicon）

1. 从 [Releases](https://github.com/CX-ARTLab/antigravity-zh-assistant/releases/latest) 下载最新版本的 `AntigravityZhAssistant-macOS-apple-silicon.zip`。
2. 双击解压得到 `AntigravityZhAssistant-macOS-apple-silicon.app`，将其拖入 **“访达 (Finder) -> 应用程序 (/Applications)”** 中。
3. 先启动 Antigravity，双击运行助手，点击 **“立即应用汉化”** 即可体验完整中文界面。
4. 如需开机自启或同步最新词典，勾选界面中的“随系统启动”与“自动加载最新汉化包”即可。

> **Gatekeeper 安全提示**：由于开源程序未购买 Apple 开发者企业签名证书，若首次打开弹出安全提示，可前往 **“系统设置 -> 隐私与安全性”** 点击 **“仍要打开”**；或在终端中执行：
> ```bash
> xattr -cr /Applications/AntigravityZhAssistant-macOS-apple-silicon.app
> ```

---

<div align="center">
  <img width="1611" height="750" alt="Antigravity 中文助手 界面预览" src="https://github.com/user-attachments/assets/2532c6a0-563b-480e-b211-bf62bf9a9336" />
</div>

---

## 当前功能特性

- **双端原生跨平台支持**：同时提供 Windows 原生高性能单文件客户端与 macOS (Apple Silicon M1/M2/M3/M4) 原生 SwiftUI 客户端。
- **非侵入式运行时注入**：采用 CDP 本地安全通道进行界面元素翻译，不修改官方原程序文件与签名，保障智能体安全策略与运行沙箱完整无损。
- **安全过滤与智能避让**：精准匹配系统与菜单文案，自动严格避让用户输入框、代码块、终端编辑区、对话消息、项目私有文件以及可编辑区域。
- **一键应用与一键还原**：内存状态即时切换，随时可一键无缝还原官方原版英文界面。
- **全场景词典深度覆盖**：全面覆盖侧边栏、对话交互、模型选择、安全预设、额度限流、执行方式、快捷键气泡（Tooltip）及各类设置面板。
- **极简卡片与原生美学**：采用现代化微立体卡片视窗，结合高精度矢量抗锯齿绘制与 DPI 自适应防挤压方案，多尺度高分屏均清晰锐利。
- **智能版本检测与自动适配**：实时监测 Antigravity 进程与版本升级，检测到新版本后自动增量适配常见新词条。
- **待适配词条扫描器**：自动比对官方英文词条与现有汉化，未翻译的新增词条自动输出到用户配置目录下的 `待适配词条.json`，便于后续维护与社区贡献。
- **独立词典云端热更新**：支持在线热更新远程词典包，无需频繁重新下载助手客户端。

---

## 兼容性与运行环境

| 平台 | 操作系统支持 | 适用芯片 / 架构 | 软件版本要求 |
| :--- | :--- | :--- | :--- |
| **Windows** | Windows 10 / 11（64 位） | x64 / ARM64 (兼容层) | 官方 Google Antigravity 客户端 |
| **macOS** | macOS 12 Monterey 及更高 | Apple Silicon (M1/M2/M3/M4) | 官方 Google Antigravity for Mac |

---

## 本地编译构建

### Windows 版本编译

在 Windows PowerShell 中运行：

```powershell
.\build.ps1
```

生成的单文件便携程序位于 `dist/AntigravityZhAssistant.exe`，并会自动打包生成 `dist/AntigravityZhAssistant-windows.zip`。项目使用 Windows 自带的 .NET Framework C# 编译器（`csc.exe`），无需安装 Visual Studio、.NET SDK、Node.js 或 Python 等额外开发环境。

### macOS 版本编译

在 macOS 终端中运行：

```bash
bash macOS/build-macos.sh
```

脚本会自动使用 Swift Package Manager（`swift build`）编译原生 Apple Silicon 可执行文件，组装包含图标和内嵌资源的 `.app` 应用程序包，并生成便携分发文件 `dist/AntigravityZhAssistant-macOS-apple-silicon.zip`。

---

## 词典包说明

- 翻译词典源文件位于 [`translation/`](translation/)：
  - `translation-pack.json`：打包的完整词典集合（包含前端界面、弹窗、设置与快捷键词条）。
  - `manifest.json`：词典版本控制与云端更新元数据。
- 发布版会直接把构建时的完整词典内嵌打包进应用，完全离线即可使用。
- 开启“自动更新”后，程序会自动检测并优先加载用户数据目录中的最新更新词典。

---

## 隐私与免责声明

1. **隐私安全**：助手仅处理 Antigravity 的系统界面文本与菜单配置，绝不读取、修改或上传您的对话记录、提示词、代码片段或项目私有文件。扫描出的待适配词条仅保存在本机。
2. **非官方声明**：本项目不是 Google 或 Antigravity 官方产品，与 Google LLC 不存在任何隶属、赞助或授权关系。“Google”、“Antigravity”及相关商标和品牌资源均归其各自权利人所有。
3. **开源许可**：本项目基于 MIT 许可证开源，仅供学习、交流与界面便利使用。
