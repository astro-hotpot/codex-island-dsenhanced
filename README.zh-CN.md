# CodexIsland · DeepSeek Fork

[English](README.md) | [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Assets/codexisland-logo.png" width="160" alt="CodexIsland logo">
</p>

> 你的 AI 用量限额，住在 Mac 刘海里。

CodexIsland 是一个原生 macOS 悬浮层，把 MacBook 刘海变成类似 Dynamic Island 的实时用量状态。它支持 Claude Code 和 Codex，用悬停预览 5 小时窗口，用点击展开完整面板，展示 5 小时与周窗口的用量、重置时间、图表样式，以及从本地会话日志估算的美元成本和 token 吞吐量。

应用免费、开源、未签名，并且以本地优先为原则。它读取 Claude Code / Claude Desktop 和 Codex 已经写入本机的凭据，只调用对应服务自己的用量接口。

## 关于这个 Fork

本仓库基于 [ericjypark/codex-island](https://github.com/ericjypark/codex-island)，由 houtianyihou 维护 DeepSeek 扩展。保留原项目 MIT 许可证及作者署名。

- DeepSeek API 余额查询，以及内嵌官方用量页面的历史数据显示。
- 从本机 DSH 的 `session.v3.jsonl.zstd` 读取 Token，用于活动日历；只统计 `assistant/message.data.usage`，避免流式记录重复计数。
- 提供商列和显示样式可独立配置。
- 当前构建面向 **Apple Silicon（M 系列）和 macOS 13+**。

DeepSeek 网页历史依赖登录状态和页面结构；未读到完整历史时不代表累计用量为零。DSH 数据目前来自本地日志扫描，不属于上游用量数据库的持久保存范围。

## 功能

- **两个服务，四个窗口。** 在一个面板里显示 Claude 5 小时 + 7 天，以及 Codex 5 小时 + 7 天。
- **贴合刘海的悬浮层。** 紧凑状态是一个对齐物理刘海的黑色胶囊；没有刘海的 Mac 会退回到菜单栏胶囊。
- **隐藏图标。** 在设置 → 通用中开启后，平时隐藏在刘海中，鼠标移到刘海显示用量横条，移开后隐藏；点击仍可展开完整面板。此模式优先于“始终显示用量”，且不因限额提醒自动展开。无刘海屏幕以顶部中央区域作为悬停入口。
- **悬停预览。** 鼠标移到刘海附近时，胶囊会展开到足够显示每个可见服务的 5 小时百分比和重置提示。
- **点击展开。** 点击岛可打开完整 Usage / Cost / Overview 面板，包含服务列、图表控制和分页。
- **Usage 与 Cost 横向切换。** Cost 页面会从本地 Claude Code 和 Codex 日志估算今天与本月至今的美元成本、token 吞吐量和趋势。
- **用量分享卡片。** 从 **Overview → 分享用量** 或 **设置 → 通用 → 用量卡片** 打开。以美元 API 换算价值为主角，展示流动的累计曲线与各提供商金额，也可切换为 token 数。配色由所选指标自动决定：低于 $1K / 1 亿 token 为白卡，达到 $1K / 1 亿为黑卡，达到 $10K / 10 亿为蓝卡。时间范围可选最近 7 天、最近 30 天、最近 3 个月、今年或全部时间，默认最近 7 天。最近 7 天和最近 30 天分别包含今天及之前的 6 天或 29 天。最近 3 个月为截至今天的滚动日历范围。今年统计至今天，全部时间按需读取最早保存的本地用量记录。选择动态 / 方形 / 故事比例和可选署名，通过 macOS 分享菜单发送图片与文案。点击“实际大小”查看细节，通过“…”菜单保存 1080 像素宽的 PNG 或复制图片与文案。应用更新后，有本周用量时会自动打开一次。按本地日历统计并包含缓存；金额为估算值，并非订阅账单，缺少价格时会标注。全部在 Mac 上生成。
- **持久保存用量历史。** CodexIsland 将采集到的 token 数量保存在自己的本地数据库中，即使提供商清理日志也会保留。重复扫描不会重复计数。仅保存用量、模型、时间及匿名记录标识，不保存对话或凭据。从 **设置 → 通用 → 恢复 Claude 用量…** 打开恢复窗口，预览留存日志、备份和旧每日快照中的计数，确认后再导入。也可使用 [终端恢复脚本](docs/USAGE-HISTORY.md#recover-your-claude-usage)。详见[用量历史存储说明](docs/USAGE-HISTORY.md)。
- **可配置 token 统计口径。** 可以选择统计所有 token（包含缓存，接近 ccusage 口径），或只统计输入 + 输出（接近 Anthropic claude.ai 统计面板）。
- **不遮挡岛外点击。** 窗口会忽略可见轮廓外的鼠标事件，菜单栏和后面的 app 仍能正常操作。
- **多种图表样式。** 支持 Ring、Bar、Stepped、Numeric、Sparkline；可在设置中选择默认样式，也可在展开面板里 Cmd 点击切换。
- **手动刷新。** 点击面板头部的同步状态即可立即重新拉取数据。
- **周围灯效。** 设置 → 通用中可独立开关辉光和流动灯效，默认开启；隐藏在刘海时不发光，悬停或展开后恢复。
- **低功耗模式。** 可以隐藏常驻辉光，只在刷新、悬停或接近限额提醒时显示。
- **无 Dock 图标设置窗口。** 应用以 accessory app 运行，通过面板里的齿轮打开自定义设置窗口。
- **安全轮询间隔。** 支持 5 分钟、15 分钟、30 分钟；不提供低于 5 分钟的轮询，避免触发 Anthropic 用量接口的严格限流。
- **Apple Silicon 构建。** `build.sh` 编译 arm64，目标为 macOS 13+。
- **Sparkle 自动更新。** 启动时和每天一次检查最新 GitHub Release 的 appcast，安装前会提示用户确认。
- **原生隐私边界。** 没有应用遥测、崩溃上报、第三方分析或代理服务。

## 安装与启动

需要 Apple Silicon Mac、macOS 13+、Xcode 或 Command Line Tools，以及 Python 3。首次构建会联网下载 Sparkle。

```sh
git clone https://github.com/houtianyihou/codex-island-dsavailable.git
cd codex-island-dsavailable
./start.command
```

也可以在 Finder 中双击 `start.command`。首次启动自动构建，之后直接打开 `build/CodexIsland.app`。应用没有 Dock 图标，请在刘海或菜单栏区域查找悬浮岛。

更新代码后，先从应用设置退出，再执行：

```sh
git pull --ff-only
./start.command --build
```

`--build` 会重新构建；构建失败时保留已有应用。直接打开已有构建也可以使用 `open build/CodexIsland.app`。如果已有同 bundle ID 的应用运行，请先退出它，避免仍看到旧版本。

原作者的 Homebrew cask 和安装包是上游版本，不包含本 Fork 的 DeepSeek 修改。本 Fork 当前以源码构建为推荐安装方式。

当前 Sparkle 更新源仍指向上游。为保留 Fork 功能，请在设置中关闭自动检查，不要安装上游更新；更新本 Fork 请使用以上 Git 命令。

## 首次运行

Claude / Codex 使用已有登录凭据；DeepSeek 余额查询需要单独配置 API key 文件。

Codex：

- 先登录 Codex / ChatGPT CLI。
- CodexIsland 读取 `~/.codex/auth.json`。
- 如果文件或 access token 缺失，面板会显示 `no codex auth`。

Claude：

- 运行一次 `claude`，或打开 Claude Desktop，让 Claude 凭据写入本机。
- CodexIsland 读取环境变量 `CLAUDE_CODE_OAUTH_TOKEN`、Claude Code 的 Keychain 项以及凭据文件。应用不直接刷新 OAuth token，也不写入 Claude 凭据；过期时由 Claude Code 更新。
- 如果都不可用，面板会显示 `auth required — run claude`。

应用启动后会立即进行第一次拉取，所以你第一次悬停时通常已经能看到数据。打开设置也会触发一次刷新。

## DeepSeek 配置

1. 在设置中将一个提供商列切换为 **DeepSeek**。
2. 将 API key 保存到仓库之外的本地纯文本文件，文件中应仅有一个 `sk-...` 密钥。设置自定义路径（替换示例路径），然后重启应用：

```sh
defaults write dev.codexisland.CodexIsland MacIsland.deepSeekKeyFile -string "$HOME/.config/deepseek/api-key"
```

请自行创建该文件并限制读取权限，例如 `chmod 600`。不配置时当前代码默认读取 `~/Desktop/key/key`。余额请求发往 DeepSeek 官方 API；不要把密钥提交到 Git。

3. 网页历史使用独立的网页登录：点击 **打开 DeepSeek**，在内嵌官方页面登录并打开用量页。API key 不能替代网页登录。
4. 若要显示 DSH 本地 Token 日历，安装 `zstd`（`brew install zstd`），并确保本机存在 `~/.dsh/sessions/` 下的会话日志。不使用 DSH 时无需安装。

## 使用

- 悬停刘海，预览当前 5 小时用量。
- 点击岛，展开完整面板。
- 在面板上横向滑动，或点击底部圆点，在 **Usage**、**Cost** 和 **Overview** 之间切换。
- 移开鼠标，面板会收起。
- 在展开面板里 Cmd 点击，可切换当前页面的可视化样式。
- 点击 `synced Xs ago` 状态可立即刷新。
- 点击展开面板左下角的齿轮打开设置。
- 在设置里可以开启登录启动、选择刷新间隔、切换低功耗模式、隐藏或显示 Claude / Codex、选择默认图表和成本视图、切换 token 统计口径、选择成本显示货币、打开 GitHub / License，或退出应用。货币换算使用每日参考汇率并在本地缓存，底层模型价格和成本计算仍以美元为基准。

汇率与模型价格采用相同的刷新节奏：启动时读取缓存，每六小时检查一次，缓存满 24 小时后重新获取。点击刷新也会更新汇率。切换货币直接使用同一份缓存汇率表，不会额外发起请求；离线时保留最近一次有效汇率，没有缓存时显示美元。

服务可见性只影响显示。隐藏某个服务会移除它的 logo 和列，但应用仍会把最新用量保存在内存里，重新显示时不需要重置。

## 设置

设置窗口是自定义 `NSWindow`，不是系统 Settings scene。应用仍以无 Dock 图标、无菜单栏的 accessory app 方式运行。

主要偏好：

| 设置 | 存储 | UserDefaults key | 值 |
| --- | --- | --- | --- |
| 图表样式 | `StylePref` | `MacIsland.chartStyle` | `ring`, `bar`, `stepped`, `numeric`, `spark` |
| 成本样式 | `CostStylePref` | `MacIsland.costStyle` | `dollar`, `multi`, `tokens`, `spark` |
| Token 统计 | `TokenCountModeStore` | `MacIsland.tokenCountMode` | `all`, `billable` |
| 刷新间隔 | `RefreshIntervalStore` | `MacIsland.refreshInterval` | `300`, `900`, `1800` |
| 低功耗模式 | `LowPowerModeStore` | `MacIsland.lowPowerMode` | Boolean，默认 `false` |
| Claude 可见 | `ProviderVisibilityStore` | `MacIsland.claudeVisible` | Boolean，默认 `true` |
| Codex 可见 | `ProviderVisibilityStore` | `MacIsland.codexVisible` | Boolean，默认 `true` |
| 登录启动 | `LaunchAtLoginStore` | 由 `SMAppService.mainApp` 管理 | 系统登录项状态 |

刷新间隔会立即生效。`UsageStore` 会重置当前计时器，并用新的间隔重新安排下一次拉取。

## 从源码构建

需要 macOS 13+ 和来自 Xcode / Command Line Tools 的 Swift 工具链。

```sh
git clone https://github.com/houtianyihou/codex-island-dsavailable.git
cd codex-island-dsavailable
./build.sh
open build/CodexIsland.app
```

这个项目没有 Xcode project，也没有 SwiftPM package。`build.sh` 会直接用 `swiftc` 编译 `Sources/**/*.swift`，构建 arm64 二进制，复制资源并写入 `Info.plist`。

原生 app 冒烟测试：

```sh
./scripts/verify.sh
```

脚本会构建应用，启动二进制 1 秒，如果它仍在运行就结束进程。

## 发布

打包 DMG：

```sh
npm install --global create-dmg
./release.sh
```

`release.sh` 会运行原生构建，把 `.app` 复制到 `dist/`，应用 ad-hoc codesign，创建 `dist/CodexIsland-X.Y.Z.dmg`，并输出文件大小和 SHA-256。

推送 `v*` tag 会触发 `.github/workflows/release.yml`，在 `macos-15` 上构建 DMG、计算 checksum、发布 GitHub Release，并在配置了 `HOMEBREW_TAP_TOKEN` 时同步 cask 到 `ericjypark/homebrew-tap`。
