# 12. 在 macOS 本机部署 DSH（作为新 Host，复用原 Relay）

> 本文件是交接文档。新会话（无上下文）读本文件即可继续安装。
> 生成时间：2026-11-18，本机 macOS 27.2.1 / Apple Silicon (arm64)。

## 12.0 一句话任务

在**这台 Mac** 上安装 DSH Core + TUI + `ds-harness-remote` Host 插件，
让 Mac 成为 DSH 的第二个 Host：

- **本机浏览器**：访问 `http://127.0.0.1:3080`（仅回环，不开公网）
- **手机**：通过**复用原 Ubuntu 服务器的 Relay**（`https://dsh.spectracodeai.com`）连接 Mac Host
- **原 Relay 服务器不动**，Mac 侧不装 Docker、不装 nginx、不开公网端口

## 12.1 架构（运行时，只有两条链路）

```text
本机浏览器 --> http://127.0.0.1:3080 --> Mac 上的 DSH Web

手机 --> https://dsh.spectracodeai.com （原 Relay，Ubuntu 服务器，不动）
               ^
               |  Mac 的 ds-harness-remote 插件主动出站连接
               |
        Mac 上的 DSH Web Profile
```

Mac 不需要公网入站端口。只要 Mac 能**出站**访问：
`https://dsh.spectracodeai.com`（Relay）和 `https://aiapiv2.pekpik.com/v1`（LLM 网关）。

## 12.2 与 Ubuntu 方案的差异（重要）

仓库其余文档描述的是 Ubuntu 22.04 服务器方案。本机是 macOS，
以下环节按本表替换，**其余逻辑（版本组合、补丁逻辑、Relay 协议）完全一致**。

| 环节 | Ubuntu 原方案 | macOS 本机改法 |
|---|---|---|
| 数据目录 | `/mnt/data/dsh` | `~/dsh`，`~/.dsh -> ~/dsh/home` 软链 |
| 专用账户 | 新建 `dsh` 用户 | **本方案直接用 `macai0`**（uid 501），不新建用户 |
| Node 24 | nvm | 仍用 nvm（装到 `~/.nvm`，不污染系统；本机原本无 node） |
| 常驻服务 | systemd unit | **launchd LaunchAgent**（用户级，登录自启） |
| 服务加固 | systemd `ProtectSystem=` 等 | macOS 无等价项，靠目录权限 + 后置收敛 |
| 沙箱 | bubblewrap | DSH 自带 sandbox，macOS 下按实际兼容情况定 |
| Relay | 本机 Docker compose | **复用原服务器，Mac 侧零改动** |
| nginx/Cloudflare | 本机配置 | **复用原服务器，不动** |
| pi-ai 补丁 | 脚本三副本 | 脚本可复用，仅路径不同（见 11.6） |

## 12.3 当前环境事实（已探测，2026-11-18）

| 项 | 值 |
|---|---|
| 系统 | macOS 27.2.1 (Build 26B131) |
| 架构 | arm64 (Apple Silicon) |
| 用户 | `macai0` (uid 501, 在 admin 组) |
| 家目录 | `/Users/macai0` |
| 磁盘 | 926Gi 总，约 847Gi 可用 |
| Node / npm / nvm | **全部未安装**（需从零装 Node 24） |
| Homebrew | 未安装 |
| Xcode CLT | 已装（`/Applications/Xcode.app/Contents/Developer`） |
| git | 2.54.0（Apple Git-157） |
| 其他工具 | `curl`、`jq`、`python3`(3.9.6) 已有；`wget` 无 |
| 端口 3080 | **空闲** |
| Docker | 未安装（本方案不需要） |
| 网络 | 正常（走 VPN/隧道，出口可达 npm/GitHub/pekpik） |
| 仓库 | `/Users/macai0/Devlop/deepseekharness`，当前 HEAD `d7b05c5` |

## 12.4 前置条件：YOLO / 沙箱

安装需要**全盘写 + 联网**。本机 `~/.codex/config.toml` 已设置：

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

注意：这两项在**会话启动时读取**，改了必须**重开会话**才生效。

新会话开局请先自检（用来确认 YOLO 已生效）：

```bash
curl -sS -m 10 -o /dev/null -w "npmjs: %{http_code}\n" https://registry.npmjs.org/
```

- 返回 `200` → YOLO 已生效，继续第 11.5 节。
- 返回 `Could not resolve host` 或非 200 → 沙箱未关，**停止安装**并告知用户：
  会话仍带旧沙箱，需要用 `danger-full-access` 的会话重开
  （检查启动命令是否用了会覆盖的 `-p` profile）。

自检通过后，所有命令以当前用户 `macai0` 直接执行，不需要 `sudo`、
不需要逐条提权确认。

## 12.5 安装步骤（可直接执行）

约定变量（每步都假设已设置）：

```bash
export DSH_ROOT="$HOME/dsh"
export PATH="$HOME/.local/bin:$PATH"
```

### 步骤 1：建目录与软链

```bash
mkdir -p "$HOME/dsh"/{home,apps,projects,backups}
mkdir -p "$HOME/dsh/home/"{profiles,overlays}
ln -sfn "$HOME/dsh/home"     "$HOME/.dsh"
ln -sfn "$HOME/dsh/apps"     "$HOME/apps"
ln -sfn "$HOME/dsh/projects" "$HOME/projects"
mkdir -p "$HOME/.local/bin"
ls -la "$HOME/.dsh" "$HOME/apps" "$HOME/projects"
```

期望：三个软链分别指向 `~/dsh/home`、`~/dsh/apps`、`~/dsh/projects`。

### 步骤 2：安装 nvm + Node 24

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 24
nvm alias default 24
node -v     # 期望 v24.x
npm -v
```

注意：本机系统 Node 不存在，nvm 装的 Node 24 会成为本机唯一 Node。
后续所有命令都在 `nvm use 24` 环境下执行。

### 步骤 3：安装 DSH 核心

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
mkdir -p "$HOME/apps/harness" && cd "$HOME/apps/harness"
npm init -y
npm install --save-exact @deepseek-ai/dsh@0.2.2-rc.2
ln -sfn "$HOME/apps/harness/node_modules/.bin/dsh" "$HOME/.local/bin/dsh"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
export PATH="$HOME/.local/bin:$PATH"
dsh -V     # 期望 0.2.2-rc.2
```

### 步骤 4：安装 TUI（可选但推荐）

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
mkdir -p "$HOME/apps/dsh-tui" && cd "$HOME/apps/dsh-tui"
npm init -y
npm install --save-exact @deepseek-harness-tui/dsh-tui@0.20.0
ln -sfn "$HOME/apps/dsh-tui/node_modules/.bin/dsh-tui" "$HOME/.local/bin/dsh-tui"
dsh-tui --version 2>/dev/null || echo "TUI 安装完成"
```

### 步骤 5：配置 pekpik LLM 网关

凭据只放 `~/.dsh/.env`，权限 600，绝不进 Git。

```bash
cat > "$HOME/.dsh/.env" <<'EOF'
PEKPIK_API_KEY=<在这里填真实 key>
EOF
chmod 600 "$HOME/.dsh/.env"
```

> 已完成：2026-11-18 已写入真实 key，见 11.8。

Web profile 的 provider 配置写入 `~/.dsh/profiles/web/cordis.patch.yml`，
TUI profile 写入 `~/.dsh/profiles/dsh-tui/cordis.patch.yml`。
内容参照 `docs/01-deployment-overview.md` 的「1.8 LLM 路由配置」小节：

- provider: `pekpik`
- API: `openai-completions`
- baseURL: `https://aiapiv2.pekpik.com/v1`
- key 引用: `PEKPIK_API_KEY`
- 模型: `deepseek-v4-1-flash-1017`
- 默认 reasoning effort: `high`
- `compat.supportsStore: false`
- `compat.maxTokensField: max_tokens`
- `reasoningEfforts` 映射：off→none, low→low, medium→high, high→high, xhigh→xhigh, max→max
- `maxRetries: 6`

headless overlay 写入 `~/.dsh/overlays/pekpik.yml`（内容同上，供 CLI 使用）。

### 步骤 6：应用 pi-ai 兼容补丁

pekpik 返回非标准 thinking 数组，需给 pi-ai 打补丁（详见 `docs/03-pi-ai-patch.md`）。
补丁脚本 `scripts/apply-pi-ai-patch.sh` 硬编码了三个 ROOT，
**macOS 下需改成**：

```text
$HOME/apps/harness
$HOME/.dsh/profiles/web
$HOME/.dsh/profiles/dsh-tui
```

注意脚本开头有 `if [[ "$(id -un)" != "dsh" ]]` 校验，
本机用户是 `macai0`，需放宽该检查（或改为允许当前用户）。

执行：

```bash
node "$HOME/apps/harness/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js" 2>/dev/null
# 用改好的脚本：
bash /Users/macai0/Devlop/deepseekharness/scripts/apply-pi-ai-patch.sh
```

> 已完成：新增 `scripts/apply-pi-ai-patch-macos.sh` 并已执行，见 11.8 步骤 6。

### 步骤 7：安装 ds-harness-remote 插件并连 Relay

在 Web profile 中安装 Host 插件：

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
cd "$HOME/.dsh/profiles/web"
npm install --save-exact ds-harness-remote@0.6.4
```

随后启动 Web（见步骤 8），在 Web UI 的 `Remote` 面板：

1. Server URL：`https://dsh.spectracodeai.com`
2. Email：`owner@spectracodeai.com`
3. Password：从**原服务器** `/mnt/data/dsh-remote-server/.env` 读取
4. Host 名称：自定义，例如 `mac`
5. 登录并保持在线

> 已完成：2026-11-18 已用账号授权脚本完成 Relay 登录，见 11.8。

### 步骤 8：启动 Web 并本机验证

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
export PATH="$HOME/.local/bin:$PATH"
export DSH_HOME="$HOME/.dsh"
cd "$HOME/projects"
dsh web --no-open --host 127.0.0.1 --port 3080
```

另开终端获取登录 URL：

```bash
cat "$HOME/.dsh"/*.log 2>/dev/null | grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*' | tail -1
```

或直接在启动输出的日志里找 `token=`。浏览器打开该 URL。

验证项：

```bash
# 仅回环监听
lsof -nP -iTCP:3080 -sTCP:LISTEN
# 无 token 应 401
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3080/
```

### 步骤 9：launchd 常驻（可选，跑通后再做）

先用步骤 8 手动验证 Web + 手机远程可用，再做常驻。

用户级 LaunchAgent：`~/Library/LaunchAgents/com.deepseek.harness.web.plist`

要点：

- `ProgramArguments` 指向 nvm 的 node 绝对路径 + `dsh web --no-open --host 127.0.0.1 --port 3080`
- `EnvironmentVariables`：`HOME`、`DSH_HOME`、`PATH`（含 nvm bin 和 `~/.local/bin`）
- `WorkingDirectory`：`~/projects`
- `RunAtLoad` = true，`KeepAlive` = true
- `StandardOutPath` / `StandardErrorPath` 指向 `~/dsh/backups/` 或日志目录

加载：

```bash
launchctl load -w ~/Library/LaunchAgents/com.deepseek.harness.web.plist
launchctl list | grep deepseek
```

## 12.6 验收清单（Mac 版）

对照 `scripts/verify-deployment.sh`，逐项在 Mac 语境下核对：

- [ ] `node -v` 为 v24.x
- [ ] `dsh -V` 输出 `0.2.2-rc.2`
- [ ] Web 只监听 `127.0.0.1:3080`（`lsof` 确认无 `*:3080`）
- [ ] 无 token 访问 3080 返回 401
- [ ] 带 token 访问返回 200/303
- [ ] `~/.dsh`、`~/apps`、`~/projects` 软链指向 `~/dsh/*`
- [ ] `~/.dsh/.env` 权限 600
- [ ] pi-ai 补丁三副本均已打（`grep "Array.isArray(choice.delta.content)"` 有输出）
- [ ] `ds-harness-remote` 插件已安装于 Web profile
- [ ] Web UI Remote 面板登录 Relay 成功，Host 上线
- [ ] 手机端 `https://dsh.spectracodeai.com` 能看到 Mac Host 并连接

推荐直接运行验收脚本：

```bash
bash /Users/macai0/Devlop/deepseekharness/scripts/verify-deployment-macos.sh
```

## 12.7 新会话开局操作（复制这段给新会话）

```text
读 /Users/macai0/Devlop/deepseekharness/docs/12-macos-host-install.md，
按里面第 12.4 节先自检 YOLO/沙箱是否生效，然后从第 12.5 节开始，
把 DSH 装到这台 Mac 上（Mac 作为新 Host，复用原 Relay）。
遇到需要 PEKPIK_API_KEY 或 Relay 密码时停下来问我。
```

## 12.8 安装进度（2026-11-18 更新）

### 已完成

- 步骤 1 目录与软链：`~/.dsh`、`~/apps`、`~/projects` 均指向 `~/dsh/*`。
- 步骤 2 nvm + Node：Node v24.22.3（npm 11.19.1、pnpm 12.21.0 via corepack）。
- 步骤 3 DSH core：`@deepseek-ai/dsh@0.2.2-rc.2`，`~/.local/bin/dsh` 就绪。
  安装时 npm 11 拦截了 5 个 install script，已用
  `npm install-scripts approve` 逐个批准后重装。
- 步骤 4 TUI：`@deepseek-harness-tui/dsh-tui@0.20.0`，`~/.local/bin/dsh-tui` 就绪。
  TUI profile 尚未初始化，首次交互式运行 `dsh-tui` 时自举。
- 步骤 5 LLM 网关配置：两份 `cordis.patch.yml` 与 `overlays/pekpik.yml` 已写入
  pekpik 路由（provider/模型/compat/reasoningEfforts/retryPolicy 见这些文件）。
  `~/.dsh/.env` 权限 600，`PEKPIK_API_KEY` 已写入真实 key（2026-11-18）。
  注意 `maxRetries` 必须写在 provider 的 `retryPolicy.mode: normal` 下，
  `llm-retry` 插件本身不接受任何 config。
- 步骤 6 pi-ai 补丁：新增 `scripts/apply-pi-ai-patch-macos.sh`（已提交 fee658d），
  动态发现 pi-ai 副本。Mac 布局下 in-box bundle 只从 dsh 安装目录解析，
  因此实际只有一份 pi-ai（`~/apps/harness`），已打补丁并备份 `.orig`。
- 步骤 7 remote 插件：`ds-harness-remote@0.6.4` 已装入 web profile，
  profile patch 覆盖 `serverUrl: https://dsh.spectracodeai.com`、`deviceName: mac`。
- 步骤 8/9 Web + launchd：`~/Library/LaunchAgents/com.deepseek.harness.web.plist`
  已加载，`launchctl list` 显示 PID 稳定；只监听 `127.0.0.1:3080`；
  无 token 返回 401，带 token 返回 303。

### 阻塞已解除（2026-11-18）

1. **PEKPIK_API_KEY**：已写入 `~/.dsh/.env`（权限 600）。
2. **Relay 登录**：已用脚本完成账号授权
   （`POST /api/v1/auth/login` + `POST /api/v1/devices/register`），
   凭证写入 `~/.dsh/ds-harness-remote/servers/22c362b08529bf99a3e425b7/host/server-credentials.json`（权限 600）。
   Web 日志已出现 `server control connection online`，不再报 `ACCOUNT_AUTH_REQUIRED`。

### 已知限制（非阻塞）

- TUI headless CLI adapter 最高校验到 `0.2.1-rc.5`，`dst` 系列命令在
  DSH `0.2.2-rc.2` 下报 `ADAPTER_UNAVAILABLE`；交互式 TUI 与 Web 正常。
- Web token 每次启动随机生成，重启后旧 URL 失效。取当前 URL：
  `grep -o 'token=[A-Za-z0-9_-]*' ~/dsh/backups/web.out.log | tail -1`
- `ds-harness-remote` 默认服务器是 `https://dsh.r2049.cn`，已在 profile patch
  中改回自建 Relay。
- 2026-11-19 已按 `docs/11-performance-audit-2026-11.md` 同步修正
  `medium → low`、`maxRetries: 3` 与显式 backoff 配置；Web、TUI、CLI 三份配置一致。
- `~/dsh/backups/web.out.log` 含 Web token，目录已设为 `700`、日志文件 `600`。

## 12.9 本机使用说明（日常操作）

### 12.9.1 打开 Web 会话页面（本机浏览器）

Web 服务由 launchd 常驻，开机登录后自动启动，监听 `127.0.0.1:3080`。

**注意：Web token 每次启动随机生成。** 要拿当前有效的 URL：

```bash
grep -o 'token=[A-Za-z0-9_-]*' ~/dsh/backups/web.out.log | tail -1
```

输出示例：

```text
token=KLG3eiWePdvy4jRmj0DVRTg9BF-ZLas6T7cmPmUYz4w
```

把结果拼成完整地址，在浏览器打开：

```text
http://127.0.0.1:3080/?token=KLG3eiWePdvy4jRmj0DVRTg9BF-ZLas6T7cmPmUYz4w
```

打开后进入 DSH Web 界面，会话页面在左侧会话列表里（New Chat / 会话列表入口）。

如果直接访问 `http://127.0.0.1:3080/` 不带 token，会返回 401。

也可以直接在终端里一键打开浏览器：

```bash
open "http://127.0.0.1:3080/?token=$(grep -o 'token=[A-Za-z0-9_-]*' ~/dsh/backups/web.out.log | tail -1 | cut -d= -f2)"
```

注意：`~/dsh/backups/web.out.log` 如果被轮转清空，就先重启 Web 服务
（见 12.9.2）再执行上面的命令，或者在服务启动输出里找 token。

### 12.9.2 检查 Web 是否在运行

```bash
# launchd 任务是否在跑
launchctl list | grep com.deepseek.harness.web

# 是否监听 3080（应只显示 127.0.0.1）
lsof -nP -iTCP:3080 -sTCP:LISTEN

# 最近日志
tail -30 ~/dsh/backups/web.out.log
tail -30 ~/dsh/backups/web.err.log
```

若 launchd 任务不存在或进程已退出，重新加载：

```bash
launchctl load -w ~/Library/LaunchAgents/com.deepseek.harness.web.plist
```

若服务异常、改了配置或想重启：

```bash
launchctl kickstart -k gui/$(id -u)/com.deepseek.harness.web
```

重启后 token 会变，必须重新执行 12.9.1 拿新 URL。

### 12.9.3 手机端访问 Mac Host

手机浏览器打开 `https://dsh.spectracodeai.com`，登录 Relay
（Email：`owner@spectracodeai.com`），在设备列表里选择名为 `mac` 的 Host。

前提：Mac 的 `ds-harness-remote` 插件在线。验证方式：

```bash
grep "server control connection" ~/dsh/backups/web.out.log | tail -1
```

应看到 `server control connection online`，而不是 `ACCOUNT_AUTH_REQUIRED`。

### 12.9.4 命令行 TUI（备用入口）

Web 正常时优先用浏览器。备用入口是终端交互式 TUI：

```bash
export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
export PATH="$HOME/.local/bin:$PATH"
export DSH_HOME="$HOME/.dsh"
cd "$HOME/projects"
dsh-tui
```

TUI profile 首次运行会自动自举初始化。`dst` 系列 headless 命令在
DSH `0.2.2-rc.2` 下暂不可用（ADAPTER_UNAVAILABLE），交互式 TUI 正常。

### 12.9.5 关键路径与文件

| 用途 | 路径 |
|---|---|
| Web 访问地址 | `http://127.0.0.1:3080/?token=<最新 token>` |
| Web 日志（stdout） | `~/dsh/backups/web.out.log` |
| Web 日志（stderr） | `~/dsh/backups/web.err.log` |
| launchd 配置 | `~/Library/LaunchAgents/com.deepseek.harness.web.plist` |
| DSH 配置 | `~/.dsh/` |
| DSH Web profile | `~/.dsh/profiles/web/` |
| LLM 密钥 | `~/.dsh/.env`（权限 600） |
| Relay 主机凭证 | `~/.dsh/ds-harness-remote/servers/<server-hash>/host/server-credentials.json` |
| 工作目录 | `~/projects/` |
| macOS 验收脚本 | `/Users/macai0/Devlop/deepseekharness/scripts/verify-deployment-macos.sh` |

### 12.9.6 日常验收与配置一致性

```bash
# 完整验收（launchd、回环监听、token、Relay、权限、软链、补丁）
bash /Users/macai0/Devlop/deepseekharness/scripts/verify-deployment-macos.sh

# pi-ai 兼容补丁检查
bash /Users/macai0/Devlop/deepseekharness/scripts/apply-pi-ai-patch-macos.sh --check

# 修改模型配置后重启 Web
launchctl kickstart -k gui/$(id -u)/com.deepseek.harness.web
```

性能审计确认过的三项修正必须保留在：

1. `~/.dsh/profiles/web/cordis.patch.yml`
2. `~/.dsh/profiles/dsh-tui/cordis.patch.yml`
3. `~/.dsh/overlays/pekpik.yml`

关键值：

```yaml
medium: low
maxRetries: 3
backoff:
  initialDelayMs: 500
  maxDelayMs: 8000
  jitterRatio: 0.3
```

## 12.10 不要做

- 不要动原 Relay 服务器（Ubuntu）的任何配置
- 不要把 API key、Relay 密码、Web token 写入 Git
- 不要把 3080 开到公网（保持 `127.0.0.1`）
- 不要在未跑通前就装 launchd 常驻
- 本机不需要 Docker / nginx
