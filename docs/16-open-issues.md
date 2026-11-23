# 16. 待修复与待更新清单（Open Issues）

本文件记录 2026-11-23 安全审计与自检中发现的、**尚未处理**的问题。每项都标注了
现状、影响和建议动作；处理时请逐项更新本文件的状态。

> 原则：这些项都**不紧急且不影响当前 Web 会话能力**，按时间窗口排期处理即可。

## 16.1 文档版本与实际部署不一致（待对齐）

`AGENTS.md` 与多份文档把 TUI / Remote 写成较新版本，但机器上实际安装的是旧版本：

| 组件 | 文档声称 | 实测版本 | 备注 |
|---|---|---|---|
| DSH core (`@deepseek-ai/dsh`) | 0.2.2-rc.5 | 0.2.2-rc.5 | 一致 ✅ |
| Web bundle (`@deepseek-ai/dsh-web-app`) | 0.2.2-rc.5 | 0.2.2-rc.5 | 一致 ✅ |
| TUI (`@deepseek-harness-tui/dsh-tui`) | 0.20.1 | **0.20.0** | 不一致 ❌ |
| Remote (`ds-harness-remote`) | 0.6.5 | **0.6.4** | 不一致 ❌ |
| `@deepseek-ai/dsh-llm-pi-ai` (web) | — | 0.2.2-rc.5 | 文档未列 |
| `@deepseek-ai/dsh-llm-pi-ai` (tui) | — | 0.2.2-rc.2 | 与 web 不同版本，需确认是否有意 |
| `dsh-mobile` (web bundle) | 未列 | 0.8.8 | 遗留冗余，手机入口已改用 `ds-harness-remote` |

**影响**：仅文档误导，无功能影响。

**待办（二选一）**：
- (a) 把 `AGENTS.md`、`docs/01`、`docs/02`、`docs/07`、`docs/08` 中的版本表述改成实测值；
- (b) 或把 TUI/Remote 升级到 0.20.1 / 0.6.5，再让文档保持不变。
  升级前请确认 TUI / Android App / Relay 三端版本兼容（见 `docs/05`）。

**需澄清**：TUI 的 `dsh-llm-pi-ai` 仍是 rc.2，而 web 已是 rc.5 —— 是有意保持还是漏升级？

## 16.2 ACP 外部 Agent 后端未安装（待修复）

`ds-harness-remote` 的 `acp.backends` 声明了多个外部 agent 可执行文件，但它们在
**`dsh` 用户的 PATH 下都不存在**：

| backend id | 命令 | 状态 |
|---|---|---|
| `codex` | `codex` | 缺失（`ubuntu` 用户下有一个，`dsh` 下没有） |
| `cursor` | `agent` | 缺失（且配置里 `enabled: false`） |
| `antigravity` | `agy` | 缺失 |
| `pi` | `pi-acp` | 缺失 |
| `claude` | `claude-agent-acp` | 缺失 |
| `opencode` | `opencode` | 缺失 |

**影响**：不影响 Web 主功能和 pekpik 模型会话；仅当想从 DSH 里调用这些外部
agent（Codex/Cursor/Antigravity/Claude Code/Pi/OpenCode）时失败，日志出现
`Antigravity binary error` / `Cursor ACP ... UNAVAILABLE` / `Codex App Server ... UNAVAILABLE`。

**待办**：确认哪些 ACP 后端是真正需要的，安装对应 CLI 并放到 `dsh` 用户 PATH；
不需要的在 `cordis.patch.yml` 里把 `enabled` 置 `false`，消除噪声告警。

## 16.3 远端 ACP 能力定位与稳定性说明（认知项）

**ACP** = Agent Client Protocol。DSH 本身不是这些外部 agent，而是通过
`ds-harness-remote` 的 **ACP 网关**把它们接入，实现「多 agent 编排」：

- `ds-harness-remote` 的官方描述：*"P2P-based, end-to-end encrypted remote access
  to DeepSeek Harness, **CodeX**, **Claude Code**, **Pi**, and other workspaces..."*
- README Highlights 原文：Codex 域与 Cursor/Antigravity ACP 网关是
  **"optional **experimental**"（可选的实验性）**，客户端投影保留在内存中
  （`client-side projections kept in memory`）。
- README 明说：CodeX/ACP **当前仅支持 workspace discovery**，通过
  `remote_list_hosts` / `remote_list_workspaces` 两个工具发现工作区；本版本
  **不注册外部 MCP server**；terminal-only profile 不是受支持的 Host 形态。

**结论（稳定性）**：
- **不是完整能力**。DSH 通过 ACP 调用外部 agent 目前是实验特性：以「发现工作区
  + 在远端已有会话上继续交互」为主，并非把 agy/codex CLI 的全部能力原样透传。
- 版本兼容基线是 Harness `dsh-v0.2.2-rc.1`；跨版本行为可能变化。
- 因此：把「DSH 调用 agy/codex」当作**可选实验能力**使用，不要依赖它承载
  关键流程；关键工作用原生 Harness 会话（pekpik 模型）完成。

**待办**：若要正式启用，先装 CLI、再实测一次「发现工作区 → 建/续会话 → 读历史」，
并把结果与版本号记录到本文档；若不稳定，保持关闭。

## 16.4 仓库 git 目录所有权（低优先）

`/mnt/data/deepseekharness` 属主不是当前操作用户，`git` 会报
`detected dubious ownership`。本会话用
`git -c safe.directory=/mnt/data/deepseekharness ...` 绕过。

**待办**：在需要的账号下执行一次
`git config --global --add safe.directory /mnt/data/deepseekharness`，
或修正目录属主。

## 16.5 配置文件生成纪律（已修复，留档）

任何改动 `~/.dsh/profiles/web/cordis.patch.yml` 的操作，**必须**用
`scripts/generate-persona-preset.mjs` 生成（复用 DSH 的 `js-yaml` 方言，保留
`!!js` 标签），并以**服务启动日志无 `did not activate`** 为唯一验收判据。
详见 `docs/15-persona-suffix.md` 第 15.4 节。此项已于 2026-11-23 修复。
