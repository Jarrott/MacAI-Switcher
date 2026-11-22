# AI Switcher

**在 macOS 菜单栏中统一查看额度、切换账号并拖拽排序 Codex、Claude 与 Gemini。**

将多个 AI CLI 登录集中到一个轻量原生菜单栏面板中：一目了然查看剩余额度与重置时间，
支持通过 **Antigravity CLI（`agy`）** 或 **Gemini CLI（`gemini`）** 记录 Gemini 使用量，
支持在菜单栏和设置窗口直接拖拽调整账号与服务商分组顺序，并按服务商独立切换当前账号。
基于 Swift 6、SwiftUI 与 AppKit 原生开发，支持英文和简体中文界面。

[English](README.md) · **简体中文**

[核心功能](#核心功能) · [快速开始](#快速开始) · [使用指南](#使用指南) ·
[兼容范围](#兼容范围) · [本地数据](#本地数据与凭据) ·
[常见问题](#常见问题) · [开发指南](#开发指南) · [文档导航](#文档导航)

<p align="center">
  <img src="docs/images/menu-preview.png" alt="AI Switcher 中文菜单：展示 OpenAI Codex、Anthropic Claude 与 Google Gemini 账号分组、剩余额度进度条、重置时间、拖拽手柄及菜单操作" width="360">
</p>

## 核心功能

- **三大服务商，独立激活**：同时管理 **OpenAI Codex**、**Anthropic Claude** 与
  **Google Gemini** 多账号，各服务商独立维护当前激活账号，互不干扰。
- **Gemini 双模式支持（`agy` + `gemini` CLI）**：
  - **Antigravity CLI（`agy`）**：一键接入官方 `statusLine` 回调，自动记录每个登录
    Google 账号的邮箱、套餐与 5 小时 / 7 天 Gemini 剩余额度，不触碰系统钥匙串，也不记录对话内容。
  - **Gemini CLI（`@google/gemini-cli`）**：支持 `~/.gemini/oauth_creds.json` 账号发现、
    凭据快照切换、OAuth 自动续期以及 Pro / Flash 每日模型剩余额度查询。
- **全界面拖拽排序**：在菜单栏下拉面板和**账号设置**窗口中，均可拖拽服务商标题调整分组顺序，
  拖拽分组内账号卡片或列表行调整账号顺序（设置窗口同时提供键盘可访问的上移 / 下移按钮）。
  自定义顺序持久化保存在 `accounts.json` 中，并实时同步到悬停账号子菜单。
- **剩余额度一目了然**：分段进度条按剩余比例自动着色（低于 10% 为红色，10%～50% 为黄色，
  高于 50% 为绿色），清晰展示重置日期与套餐徽章；无法获取的数值始终显示 `--%` / `--`，绝不伪造为零。
- **灵活添加与登录恢复**：支持一键开启 `agy` 用量记录、隔离式浏览器 OAuth 登录、导入当前 CLI 登录
  或导入凭据 JSON 文件；过期 OAuth 令牌自动刷新，同步 CLI 侧令牌轮换，重新授权原地更新账号无需先删除。
- **Codex 重置次数确认兑换**：在账号支持时显示可用重置次数，点击后经独立确认弹窗才发起消耗请求。
- **原生 macOS 体验**：半透明毛玻璃菜单面板、每 5 分钟自动刷新、手动刷新（`⌘R`）、
  自定义账号名称、登录时启动（`⌘L`）、SQLite 持久化累计运行时间与即时语言切换，无任何第三方 Swift 包依赖。

## 快速开始

### 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | macOS 14 Sonoma 或更新版本 |
| 编译工具 | Swift 6.0+ 与 macOS SDK（Xcode 或 Command Line Tools） |
| 支持的 CLI | 按需安装 Codex CLI（`codex`）、Claude Code（`claude`）、Antigravity CLI（`agy`）或 Gemini CLI（`gemini`） |
| 网络 | 浏览器登录、Codex / Claude / Gemini CLI 额度刷新和 Codex 重置次数兑换需要联网 |

只需安装你实际使用的服务商 CLI，其余可忽略。

### 编译并启动

在项目根目录执行：

```bash
git clone https://github.com/Jarrott/MacAI-Switcher.git
cd MacAI-Switcher
./build-app.sh release
open "$(swift build -c release --show-bin-path)/AI Switcher.app"
```

如果本地已有仓库，请在包含 `Package.swift` 的**项目根目录**执行最后两条命令。
`./build-app.sh release` 会编译 Release 可执行文件、打包图标与中英文资源并执行 ad-hoc 签名；
单独运行 `swift build` 不会组装完整的 `.app` 应用包。

启动后请在 **macOS 顶部菜单栏**点击切换图标（本应用无 Dock 图标和主窗口）。
日常使用时，建议先退出当前实例，在 Finder 中将 `AI Switcher.app` 复制到“应用程序”目录后再启动，
并按需在菜单中勾选**登录时启动**。

## 使用指南

### 添加账号

应用启动时会自动扫描已支持位置的现有登录。需要新增账号或接入 Gemini 记录时，
打开**添加账号**（`⌘N`），选择 **Codex**、**Claude** 或 **Gemini**，按场景选择对应操作：

| 操作 | 适用场景 | 执行效果 |
| --- | --- | --- |
| **启用 Antigravity (`agy`) 用量记录** | 使用 `agy` 并希望自动记录 Gemini 额度 | 向 `~/.gemini/antigravity-cli/settings.json` 注册官方 `statusLine` 记录脚本并同步已有记录 |
| **使用浏览器登录** | 新增 `codex` / `claude` / `gemini` CLI 账号或重新授权 | 调用已安装 CLI 的官方浏览器 OAuth 流程，验证成功后自动导入并激活 |
| **导入当前登录** | 终端中已经登录，或 `agy` 已有记录 | 保存或更新当前登录快照，并标记为该服务商当前账号 |
| **导入凭据文件…** | 已有导出的凭据 JSON 文件 | 校验并安全保存快照，手动激活前不会覆盖当前 CLI 登录 |

手动在终端执行登录的命令参考：

```bash
codex login          # Codex / ChatGPT
claude auth login    # Claude Code
agy                  # Antigravity CLI（钥匙串 Google 登录，可用 /usage 查看额度）
gemini               # Gemini CLI（Sign in with Google）
```

### 通过 Antigravity CLI（`agy`）记录 Gemini 使用量

当本机已安装 `agy` 时：

1. 打开**添加账号 → Gemini**，点击**启用 Antigravity (agy) 用量记录**。
   - 应用会在应用支持目录生成仅当前用户可执行的 `agy-statusline-hook.sh`，并写入
     `~/.gemini/antigravity-cli/settings.json`（设置 `stack_with_default: true`）。
   - 保留 `settings.json` 中所有原有配置以及 `agy` 默认状态栏；如果此前已有自定义
     `statusLine.command`，会自动串联保留原输出。
2. 重新打开一个 `agy` 会话（或在已打开的 `agy` 中运行一次 `/statusline`），发送消息或执行 `/usage`。
3. 点击菜单栏 AI Switcher 图标（或按 `⌘R` 立即刷新），即可看到同步后的 **Google / Gemini**
   账号邮箱、套餐徽章、5 小时 / 7 天剩余额度进度条与重置时间。

`agy` 使用系统钥匙串自行管理登录态；如需在 `agy` 中切换不同 Google 账号，请在 `agy` 内执行
`/logout` 后重新登录，AI Switcher 会自动为每个登录过的账号分别保留并更新额度记录。

### 拖拽调整账号与服务商顺序

- **在菜单栏下拉面板中**：
  - 拖拽任意**服务商分组标题栏**（OpenAI / Anthropic / Google）即可上下调整分组顺序。
  - 拖拽账号卡片右侧的**拖拽手柄（`≡`）**，或直接拖拽仅展示用的**额度进度条区域**，
    即可在同一服务商分组内调整账号顺序；点击账号标题行仍然正常执行账号切换。
- **在“账号设置”窗口中**：
  - 在各服务商分组内直接拖拽账号行调整顺序。
  - 拖拽服务商分组标题，或点击分组标题右侧支持键盘访问的 **↑ / ↓** 按钮调整分组顺序。
- **持久化与多处同步**：顺序修改会立即写入 `accounts.json`，在自动刷新、重新授权与应用重启后保持不变，
  并实时同步到菜单栏主面板、悬停账号子菜单及账号设置窗口。

### 切换账号

1. 点击账号的**标题行**，或将鼠标悬停在**账号设置**上，从右侧子菜单中点击目标账号。
2. 确认账号左侧的 **✓** 标记。Codex、Claude 与 Gemini 各自独立维护当前账号。
3. 启动会读取新凭据的 CLI 会话。

切换前应用会先为当前实际登录写入快照，防止丢失 CLI 侧最新轮换的令牌。
已经运行的 CLI 会话或共享后台服务可能仍缓存旧账号；勾选标记表示已选中目标凭据，
不代表已打开的终端会自动切换。Codex 会话隔离与安全重启方法见
[Codex 终端集成](docs/CODEX_TERMINALS.md)。

### 查看额度、重置次数与快捷键

- 百分比表示**剩余额度**：低于 10% 为红色，10%～50% 为黄色，高于 50% 为绿色；缺失字段保持 `--%` / `--`。
- 进度条与日期区域仅用于展示（多账号时支持拖拽排序），不会误触账号切换。
- Codex 存在可用重置次数时，对应行可点击，先弹出明确确认框再发起消耗请求。
- 刷新失败时保留上次成功的数据并在卡片内显示错误提示，避免偶发网络波动清空已有视图。

菜单打开时支持以下快捷键：

| 快捷键 | 操作 |
| --- | --- |
| `⌘N` | 添加账号 |
| `⌘R` | 立即刷新 |
| `⌘L` | 切换“登录时启动” |
| `⌘Q` | 退出 AI 切换器 |

## 兼容范围

| 能力 | Codex / OpenAI | Claude / Anthropic | Gemini / Google |
| --- | --- | --- | --- |
| 支持的 CLI | Codex CLI（`codex`） | Claude Code（`claude`） | Antigravity CLI（`agy`）及/或 Gemini CLI（`gemini`） |
| 凭据 / 数据来源 | `~/.codex/auth.json` | macOS 钥匙串 `Claude Code-credentials` | `agy` 官方 `statusLine` 缓存（`antigravity-usage.json`）及/或 `~/.gemini/oauth_creds.json` |
| 其他本地文件 | 从凭据 JWT 解析账号身份 | 备用文件 `~/.claude/.credentials.json`；只读 `~/.claude.json` | `~/.gemini/antigravity-cli/settings.json`（`agy`）；`~/.gemini/google_accounts.json`（`gemini`） |
| 额度窗口 | 5 小时 / 7 天 | 5 小时 / 7 天 | 5 小时 / 7 天（`agy`）；Pro / Flash 每日额度（`gemini`） |
| 账号切换 | 支持（临时隔离 `CODEX_HOME` 登录） | 支持（系统钥匙串写入） | `gemini` CLI 支持（隔离 `GEMINI_CLI_HOME`）；`agy` 通过 `/logout` 切换 |
| 手动重置次数 | 服务商提供时支持 | 不支持 | 不支持 |
| 独立当前账号 | 支持 | 支持 | 支持 |

说明：

- Codex 当前不管理仅存于系统钥匙串中的凭据、自定义 `CODEX_HOME` 或仅 API Key 配置。
- Claude 账号切换需要已初始化且可写的钥匙串登录项；仅有备用文件无法完成 macOS 切换。
- Gemini CLI 令牌刷新会在运行时从本机安装的 `gemini` CLI 包（或 `GEMINI_OAUTH_CLIENT_ID` /
  `GEMINI_OAUTH_CLIENT_SECRET` 环境变量）读取公开桌面 OAuth 客户端配置，仓库内不硬编码任何密钥。
- Codex、Claude 与 Gemini CLI 的额度接口为服务商未公开承诺稳定性的后端接口，可能变动；
  `agy` 使用其官方文档约定的 `statusLine` 回调格式。详细说明见 [API 文档](docs/API.md)。

## 本地数据与凭据

应用管理的数据存放在 `~/Library/Application Support/AISwitcher/`：

| 路径 | 权限 | 内容 |
| --- | --- | --- |
| `accounts.json` | 当前用户 | 账号元数据、自定义名称、自定义排序与分组顺序、当前账号选择及额度缓存 |
| `codex-accounts/` | `0700` / `0600` | Codex 凭据快照 |
| `claude-accounts/` | `0700` / `0600` | Claude 凭据快照 |
| `gemini-accounts/` | `0700` / `0600` | Gemini CLI 凭据快照 |
| `antigravity-usage.json` | `0600` | 脱敏后的 `agy` 用量缓存（仅含 `email`、`plan_tier`、`quota` 与时间戳，不含令牌、对话或路径） |
| `agy-statusline-hook.sh` | `0700` | 供 `agy` `statusLine` 调用的轻量记录脚本 |
| `runtime.sqlite` | 当前用户 | 以毫秒记录的累计运行时间，不包含凭据或事件历史 |

凭据快照采用原子写入与仅当前用户可读写的 `0600` 权限，但**并非加密保险库**。
请勿将快照、实际登录凭据或 `accounts.json` 提交到 Git 仓库、附在 Issue 中或放进公开截图。

Codex（`CODEX_HOME`）与 Gemini CLI（`GEMINI_CLI_HOME` + `GEMINI_FORCE_FILE_STORAGE=true`）
的浏览器 OAuth 均在临时隔离目录中运行，取消或失败不会破坏当前登录。累计运行时间每分钟及正常退出时写入
SQLite，应用关闭期间不计时；结构与回退方式见 [数据库文档](docs/DATABASE.md)。

## 常见问题

| 问题 | 处理方式 |
| --- | --- |
| 执行 `swift build --show-bin-path` 报错找不到 `Package.swift` | 请先 `cd` 到仓库根目录再运行，或直接使用 `.app` 的绝对路径执行 `open`。 |
| 启动后看不到窗口 | 请查看 macOS 顶部菜单栏图标；本应用为纯菜单栏工具，没有 Dock 图标。 |
| Gemini 提示找不到 `gemini` CLI | 若使用 **Antigravity CLI（`agy`）**，请直接点击**启用 Antigravity (agy) 用量记录**；若使用 **Gemini CLI**，请先安装 `npm install -g @google/gemini-cli` 或 `brew install gemini-cli`。 |
| 已启用 `agy` 用量记录，但菜单里还没有 Gemini 卡片 | 重新打开一个 `agy` 会话（或在当前会话执行 `/statusline`），发送消息或执行 `/usage`，再点击菜单栏图标或按 `⌘R` 即可同步。 |
| Codex 提示登录失效或 401 | 先按 `⌘R` 刷新，或点击**导入当前登录**；若授权已撤销，使用浏览器重新登录**同一账号**即可原地更新，原有名称、排序和缓存不会丢失。 |
| Claude 无法刷新或切换 | 导入当前有效的 CLI 登录或重新登录。缺少钥匙串登录项时需先通过 Claude 自身登录流程创建；权限弹窗修复见[钥匙串恢复](docs/FUNCTIONAL.md#claude-keychain-recovery)。 |
| 已打开的 Codex 终端仍在使用旧账号 | 参见 [Codex 终端集成](docs/CODEX_TERMINALS.md)；已有会话不会自动切换。 |
| 额度或重置次数显示 `--%` / 不可用 | 查看卡片内错误提示并按 `⌘R` 重试。缺失字段会保留未知状态，不会显示成零。 |

## 开发指南

在项目根目录执行检查与打包：

```bash
swift format lint --configuration .swift-format --recursive Sources Tests Package.swift
swift test
./build-app.sh release
```

全部 103 项单元测试均基于合成响应、可注入网络传输与隔离临时目录，无需真实账号凭据、钥匙串或联网即可运行。

### 离屏界面预览

执行 `./build-app.sh release` 后，可直接渲染英文与简体中文预览图，无需点击菜单栏：

```bash
BIN="$(swift build -c release --show-bin-path)/AI Switcher.app/Contents/MacOS/AISwitcher"
AISWITCHER_RENDER=/tmp/aiswitcher-en.png AISWITCHER_LANG=en "$BIN"
AISWITCHER_RENDER=/tmp/aiswitcher-zh.png AISWITCHER_LANG=zh-Hans "$BIN"
```

预览默认使用合成账号，不发起网络请求，也不会修改 `accounts.json` 或 `runtime.sqlite`。附加环境变量：

| 变量 | 值 | 用途 |
| --- | --- | --- |
| `AISWITCHER_SCENARIO` | `codex-auth-error` | 预览 Codex 登录恢复错误状态 |
| `AISWITCHER_SURFACE` | `account-switcher` | 渲染悬停账号子菜单 |
| `AISWITCHER_REAL` | `1` | 渲染本机已保存的真实数据（图片可能包含个人信息） |

### 项目结构

```text
Sources/AISwitcher/
  AISwitcherApp.swift     # 应用入口与生命周期
  Models/                 # 账号、服务商、套餐、额度窗口与重置次数
  Services/               # AccountsManager、凭据与 agy 存储、OAuth/HTTP、运行时间
  Views/                  # 菜单面板、拖拽几何计算、设置与添加账号界面
  Resources/              # 服务商 SVG 图标、菜单栏图标与中英文翻译
  PreviewRenderer.swift   # 离屏中英文界面预览
Tests/AISwitcherTests/    # 额度解析、Codex/Claude/Gemini/agy 认证、排序与持久化测试
scripts/                  # 可选的 Codex shell 集成与钥匙串校验脚本
patches/                  # 针对特定 Codex 版本的可选客户端补丁
docs/                     # 功能规格、接口文档、数据库与集成说明
```

贡献代码前请阅读 [AGENTS.md](AGENTS.md)：凭据读写保留在 `Services/*CredentialStore.swift`，
应用状态由 `AccountsManager` 统一管理，界面文案同步维护 `en.lproj` 与 `zh-Hans.lproj`，
并为所有服务商响应映射补充合成数据解析测试。

## 文档导航

以下专题文档以英文维护：

| 文档 | 内容 |
| --- | --- |
| [功能规格](docs/FUNCTIONAL.md) | 账号流程、拖拽排序、界面行为、登录恢复与 Claude 钥匙串修复 |
| [服务商 API](docs/API.md) | Codex、Claude、Gemini CLI 与 Antigravity `statusLine` 协议及 OAuth 续期约定 |
| [本地数据库](docs/DATABASE.md) | 运行时间 SQLite 表结构、迁移、备份与回退 |
| [Codex 终端集成](docs/CODEX_TERMINALS.md) | 可选 zsh 启动脚本与已有会话处理 |
| [Codex 状态邮箱修复](docs/CODEX_STATUS_EMAIL.md) | 仅适用于 Codex 0.159.0 的可选客户端补丁 |
| [Codex 输入扩展](docs/CODEX_INPUT.md) | 上述补丁客户端的可选圆角输入框与 AI 草稿建议 |
| [变更记录](CHANGELOG.md) | 详细功能变更与修复记录 |

Codex 客户端补丁是独立的可选扩展；编译 AI Switcher 不会编译或修改 Codex CLI。

## 项目说明

AI Switcher 是独立工具。OpenAI、Codex、Anthropic、Claude、Google、Gemini、Antigravity
及其图形标识归各自所有者所有；使用这些名称与图形仅用于标识支持的服务，不代表官方背书或合作关系。

当前仓库尚未包含许可证文件。
