# DeepSeek Harness 部署文档仓库

本仓库是 **DeepSeek Harness (DSH)** 在 Ubuntu 服务器上的完整部署、配置与维护文档仓库。它不是 DSH 程序源码，而是记录如何在这台机器上安装、配置、修复和维护 DSH 的全部知识——包括踩过的坑、解决办法、维护脚本和升级流程。

> 仓库地址：[linny006/deepseekharness](https://github.com/linny006/deepseekharness)

---

## 项目是什么

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 是一个 AI Coding 工作站平台，类似 Codex CLI / Claude Code，可以让 AI Agent 在服务器上：

- 读写项目代码
- 运行命令和测试
- 多轮对话完成任务
- 通过 Web UI、终端 TUI、手机远程客户端三种界面操作

本仓库记录的部署方案把一台 Ubuntu 22.04.5 服务器变成这样的工作站，具体包括：

- DSH 核心 + TUI + 自建远程访问三件套安装
- 自定义 OpenAI 兼容 LLM 网关接入
- systemd 后台常驻服务
- pi-ai 流式响应兼容补丁
- 安全隔离和加固
- 数据盘优先的目录布局

---

## 版本组合

| 组件 | 版本 | 说明 |
|---|---|---|
| DeepSeek Harness | `0.2.2-rc.2` | `@deepseek-ai/dsh` |
| TUI | `0.20.0` | `@deepseek-harness-tui/dsh-tui` |
| Remote | `0.6.4` | `ds-harness-remote` 插件 + 自建 Relay |
| 旧 Mobile 插件 | `0.8.8` | `dsh-mobile`，暂保留但未作为入口 |
| Node.js | `24.22.3` | nvm 安装在 dsh 用户下 |
| pnpm | `10.34.9` | 全局安装 |
| LLM 网关 | pekpik | OpenAI 兼容端点 |
| 模型 | `deepseek-v4-1-flash-1017` | 默认模型 |
| OS | Ubuntu 22.04.5 LTS | aarch64 |

---

## 部署架构

```
浏览器 / 手机远程客户端
    │
    │ SSH 隧道访问 Web, HTTPS 访问远程 Relay
    ▼
┌──────────────────────────────────┐
│ Cloudflare + nginx 443           │
│ dsh.spectracodeai.com            │
│ -> Relay 127.0.0.1:8080          │
└──────────────────────────────────┘
    │ Host 插件主动出站连接
    ▼
┌──────────────────────────────────┐
│ Ubuntu 22.04.5 LTS              │
│                                 │
│  systemd: deepseek-harness      │
│  ┌───────────────────────────┐  │
│  │ dsh web (127.0.0.1:3080) │  │
│  │  + ds-harness-remote 插件 │  │
│  └───────────────────────────┘  │
│                                 │
│  dsh 用户 (无 sudo; 有 docker)  │
│  ├── apps/harness (DSH 核心)    │
│  ├── apps/dsh-tui (TUI)         │
│  ├── projects/ (工作区)         │
│  └── .dsh/ (配置/会话/凭据)     │
│                                 │
│  数据盘 /mnt/data/dsh           │
│  bubblewrap 沙箱                │
└──────────────────────────────────┘
    │
    │ HTTPS
    ▼
pekpik LLM 网关 (aiapiv2.pekpik.com)
```

所有 DSH 数据存放在数据盘 `/mnt/data/dsh`，系统盘只放 nvm/npm 缓存。

---

## 快速开始

### 访问 Web UI（推荐）

```bash
# 获取带 token 的登录地址
sudo journalctl -u deepseek-harness --no-pager | grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*' | tail -1
```

本机浏览器直接打开该 URL。

SSH 远程访问时，在本地电脑执行：
```bash
ssh -N -L 3080:127.0.0.1:3080 <用户>@<服务器IP>
```
然后本地浏览器打开同样的 URL。

### 使用 CLI

```bash
sudo -iu dsh
cd ~/projects/demo
ds "分析当前项目并说明目录结构"
```

### 使用 TUI

```bash
sudo -iu dsh
cd ~/projects/demo
dsh-tui
```



### 手机远程访问

使用 Android App 或手机浏览器访问 Relay:

```
https://dsh.spectracodeai.com
```

- Server URL：`https://dsh.spectracodeai.com`
- Email：`owner@spectracodeai.com`
- Password：从 `/mnt/data/dsh-remote-server/.env` 读取
- Host：选择 `aiapp`

不要把 DSH Web token 填入手机 App。iPhone 可在 Safari 登录后“添加到主屏幕”。

详见 [docs/08-mobile-remote-access.md](docs/08-mobile-remote-access.md)。
---

## 文档目录

| 文档 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 项目约束和入口索引 |
| [docs/01-deployment-overview.md](docs/01-deployment-overview.md) | 部署总览、版本选择、目录布局、systemd 服务 |
| [docs/02-operations-manual.md](docs/02-operations-manual.md) | 日常操作手册：Web/TUI/CLI/备份/服务管理 |
| [docs/03-pi-ai-patch.md](docs/03-pi-ai-patch.md) | pekpik 网关兼容补丁详情 |
| [docs/04-troubleshooting.md](docs/04-troubleshooting.md) | 常见错误排查 |
| [docs/05-upgrade-procedure.md](docs/05-upgrade-procedure.md) | 升级流程和回滚 |
| [docs/06-security-audit.md](docs/06-security-audit.md) | 安全审计和风险清单 |
| [docs/07-new-session-handoff.md](docs/07-new-session-handoff.md) | 新会话/新维护者快速接手 |
| [docs/09-external-projects-onboarding.md](docs/09-external-projects-onboarding.md) | 外部项目（gks/gpi）接入 DSH 开发与安全部署 |
| [docs/10-new-machine-install.md](docs/10-new-machine-install.md) | 新机器从零部署：专用账户、目录、权限、验收 |
| [docs/11-performance-audit-2026-11.md](docs/11-performance-audit-2026-11.md) | 性能审计与配置修正：瓶颈定位、档位映射、重试策略 |
| [docs/12-macos-host-install.md](docs/12-macos-host-install.md) | macOS 第二 Host 部署、Web/手机访问与日常维护 |

## 脚本

| 脚本 | 用途 |
|---|---|
| `scripts/apply-pi-ai-patch.sh` | 幂等应用 pi-ai 兼容补丁（支持 `--check`） |
| `scripts/apply-pi-ai-patch-macos.sh` | macOS 版 pi-ai 兼容补丁（动态发现安装副本） |
| `scripts/verify-deployment-macos.sh` | macOS Host 验收：launchd、回环监听、Relay、权限与补丁 |
| `scripts/verify-deployment.sh` | 部署验收检查（12 项） |

---

## 部署细节摘要

### 目录布局

```
/mnt/data/dsh/
├── home/                     # ~/.dsh 软链指向这里
│   ├── profiles/web/         # Web + Mobile profile
│   ├── profiles/dsh-tui/     # TUI profile
│   ├── sessions/             # 持久化会话
│   ├── overlays/pekpik.yml   # headless CLI overlay
│   ├── .env                  # API key (600)
│   └── .credentials.yaml     # 凭据存储 (600)
├── apps/harness/             # @deepseek-ai/dsh
├── apps/dsh-tui/             # dsh-TUI
├── projects/                 # 工作区
├── backups/                  # 备份
└── bin/dsh-backup.sh         # 备份脚本
```

### systemd 服务

- 服务文件：`/etc/systemd/system/deepseek-harness.service`
- 用户：`dsh`（无 sudo；在 docker 组）
- 监听：`127.0.0.1:3080`（仅回环，不暴露公网）
- 权限模式：`workspace-write` + 审批 `ask`
- 开机自启：`enabled`
- 数据盘依赖：`RequiresMountsFor=/mnt/data/dsh`

### LLM 网关配置

- Provider：`pekpik`（OpenAI 兼容）
- 端点：`https://aiapiv2.pekpik.com/v1`
- 模型：`deepseek-v4-1-flash-1017`
- 凭据：`PEKPIK_API_KEY`，存在 `~/.dsh/.credentials.yaml` 和 `~/.dsh/.env`

### pi-ai 兼容补丁

pekpik 网关返回非标准的 thinking 数组格式，导致 `text-delta text must be a string`。补丁位置在：

```
node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js
```

三份副本都需要打补丁，用脚本一键完成：
```bash
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh
sudo systemctl restart deepseek-harness
```

---

## 安全要点

- Web 服务只监听 `127.0.0.1`，不暴露公网
- `dsh` 用户无 sudo；只读写 `/mnt/data`，具有 Docker 部署权限
- 严禁修改 `/home/ubuntu` 权限为组/其他可写，否则 SSH 公钥认证会被 StrictModes 拒绝，导致无法登录
- 凭据文件权限 `600`，不进 Git
- systemd 加固：`NoNewPrivileges`、`ProtectSystem=strict`、`CapabilityBoundingSet=` 等
- bubblewrap 沙箱已安装并可用
- Web 登录 token 等同密码，泄漏后需重启服务使其失效

详见 [docs/06-security-audit.md](docs/06-security-audit.md)。

---

## 推送到远程仓库

本仓库使用 GitHub Deploy Key 认证，SSH Host 别名 `github.com-dsh`。

### 日常推送

```bash
cd /mnt/data/deepseekharness
git add -A
git commit -m "描述改动"
git push
```

### SSH 配置

```ssh-config
# ~/.ssh/config
Host github.com-dsh
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
```

Deploy Key 指纹：`SHA256:5QfdcwMA6IUIshylVr1910Tfv8sU0cqQVMr37fljo7I`

### 克隆到新机器

```bash
git clone git@github.com:linny006/deepseekharness.git
```

需要先在目标机器的 GitHub 仓库 Settings → Deploy keys 添加该机器的 SSH 公钥。

---

## 维护检查清单

定期执行：

```bash
# 1. 服务状态
sudo systemctl status deepseek-harness

# 2. 补丁状态
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh --check

# 3. 完整验收
cd /mnt/data/deepseekharness
./scripts/verify-deployment.sh

# 4. 备份
sudo -iu dsh
/mnt/data/dsh/bin/dsh-backup.sh
```

验收脚本当前结果：**12/12 全部通过**。

---

## 关键踩坑记录

1. **Node 22 下 DSH CLI 静默退出**——DSH 入口用 `import.meta.main`，Node 22 下为 `undefined`，必须用 Node 24+
2. **pekpik 不接受 `store:false`**——`compat.supportsStore: false`
3. **pekpik 使用 `max_tokens`**——`compat.maxTokensField: max_tokens`
4. **pekpik `reasoning_effort` 不支持 `medium`**——`reasoningEfforts` 映射 medium→high
5. **pekpik 把 thinking 塞进 `content` 数组**——pi-ai 期望 string，需要兼容补丁
6. **dsh-TUI 0.20.0 headless CLI 白名单不含 rc.2**——用官方 `dsh --profile headless` 或 `ds` 包装脚本
7. **Web profile 有独立 node_modules**——补丁只打主安装不够，三份都要打

详见 [docs/04-troubleshooting.md](docs/04-troubleshooting.md)。

---

## License

本仓库是部署文档，不包含 DSH 源码。DSH 本身遵循其官方 License。
