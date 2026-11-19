# 1. 部署总览

本目录是 DSH 在本机的部署说明仓库，不是 DSH 程序源码仓库。所有可执行程序、配置、数据均在数据盘。

## 1.1 当前运行环境

| 项 | 当前状态 |
|---|---|
| OS | Ubuntu 22.04.5 LTS |
| 架构 | aarch64 |
| CPU | 4 核 |
| RAM | 23 GB |
| 数据盘 | /mnt/data (ext4, noatime,_netdev,nofail) |
| DSH 用户 | dsh (无 sudo; 在 docker 组) |
| DSH 权限 | `/mnt/data` 完整读写; Docker 部署权限; 不访问 `/home/ubuntu` |
| Node.js | v24.22.3 (dsh 用户 nvm) |
| 系统 Node | /usr/bin/node v12.22.9 (勿动, 其他生产服务依赖) |

主机上同时运行 nginx、MySQL、Docker、aria2、sing-box 等生产服务。本部署采用"只增不改"原则，不修改上述服务的配置或端口。

## 1.2 部署版本组合

| 组件 | 版本 | 说明 |
|---|---|---|
| DeepSeek Harness | 0.2.2-rc.5 | `@deepseek-ai/dsh` |
| TUI | 0.20.1 | `@deepseek-harness-tui/dsh-tui` |
| Remote | 0.6.5 | `ds-harness-remote` + 自建 Relay |
| 旧 Mobile 插件 | 0.8.8 | `dsh-mobile`，暂保留但未作为入口 |
| Node.js | 24.22.3 | nvm 安装 |
| pnpm | 10.34.9 | dsh 用户全局 |
| LLM 网关 | pekpik | OpenAI 兼容 |
| 模型 | deepseek-v4-1-flash-1017 | 默认模型 |

npm dist-tags 历史说明:
- latest: 0.2.2-rc.1
- next: 0.2.2-rc.3
- 部署采用 0.2.2-rc.5

## 1.3 为什么选 0.2.2-rc.5

- dsh-TUI 0.20.1 的 peerDependencies 明确支持 `0.2.2-rc.1` 和 `0.2.2-rc.5`
- `dsh-mobile` 0.8.8 的 peerDependencies 使用 `*`
- `ds-harness-remote` 0.6.5 与当前 DSH Web 实机验证可用
- TUI 0.20.1 的 headless CLI adapter 白名单硬编码到 `0.2.1-rc.5`
- 但其交互式 TUI 和 Web UI 可与 `0.2.2-rc.5` 配合, 已实机验证
- 0.2.2-rc.3 当时未被 TUI 0.20.1 peer 列表覆盖

## 1.4 目录布局

```
/mnt/data/dsh/
├── home/                     # ~/.dsh 软链指向这里
│   ├── profiles/
│   │   ├── web/              # Web + Remote profile
│   │   └── dsh-tui/          # dsh-TUI profile
│   ├── sessions/             # 持久化会话
│   ├── overlays/
│   │   └── pekpik.yml        # headless 测试/CLI overlay
│   ├── .env                  # PEKPIK_API_KEY, 600
│   ├── .credentials.yaml     # 凭据, 600
│   └── mobile-access/        # Mobile 配对与状态
├── apps/
│   ├── harness/              # @deepseek-ai/dsh
│   └── dsh-tui/              # dsh-TUI
├── projects/
│   ├── demo/                 # 演示项目
│   └── ...
├── backups/                  # 备份输出
└── bin/
    └── dsh-backup.sh         # 备份脚本
```

`dsh` 用户家目录 `/home/dsh` 中有软链:
- `~/.dsh -> /mnt/data/dsh/home`
- `~/apps -> /mnt/data/dsh/apps`
- `~/projects -> /mnt/data/dsh/projects`

这样, 程序和数据占用数据盘, 同时保持 DSH 默认路径兼容。

## 1.5 systemd 服务

服务文件:
```text
/etc/systemd/system/deepseek-harness.service
```

关键行为:
- User/Group: dsh
- WorkingDirectory: /home/dsh/projects
- DSH_HOME: /home/dsh/.dsh
- DSH_PERMISSION_MODE: workspace-write
- EnvironmentFile: /mnt/data/dsh/home/.env
- 只监听: 127.0.0.1:3080
- enabled + active
- After/RequiresMountsFor 保证 /mnt/data 挂载完成后再启动

## 1.6 手机远程部署

远程访问采用 `ds-harness-remote@0.6.5` 和自建 Relay Server：

```text
https://dsh.spectracodeai.com
    -> Cloudflare 橙色云
    -> nginx 443
    -> Relay 127.0.0.1:8080
    -> DSH Host 插件主动出站连接
```

部署目录：

```text
/mnt/data/dsh-remote-server
```

详细配置、手机端登录和授权失效处理见 `docs/08-mobile-remote-access.md`。

## 1.7 Web UI 访问

DSH Web token 每次服务启动随机生成，没有固定 token 参数，重启后旧 token 失效。

在服务器本机获取当前 URL:
```bash
sudo journalctl -u deepseek-harness --no-pager | grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*' | tail -1
```

在服务器本机访问:
- 浏览器打开上述 URL

从本地电脑通过 SSH 隧道访问:
```bash
# 在用户本机执行, 不是在服务器执行
ssh -N -L 3080:127.0.0.1:3080 <用户>@<服务器IP>
```
另开终端获取当前 token 后，浏览器打开 `http://127.0.0.1:3080/?token=...`。

手机端不使用 token，走 `https://dsh.spectracodeai.com` + Relay 账号登录。

不要把带 token 的 URL 存入 git、截图、聊天或日志系统。

## 1.8 LLM 路由配置

两个 profile 均在 `cordis.patch.yml` 中配置 `llm-pi-ai`:
- provider: `pekpik`
- API: `openai-completions`
- baseURL: `https://aiapiv2.pekpik.com/v1`
- key 引用: `PEKPIK_API_KEY`
- 模型: `deepseek-v4-1-flash-1017`
- 默认 reasoning effort: `high`

`headless` profile 没有持久化 profile 目录, 因此 CLI/测试使用:
```text
/mnt/data/dsh/home/overlays/pekpik.yml
```

## 1.9 DSH 能力入口

### Web UI (推荐)
获取 token 后, 浏览器打开 Web URL。适合日常交互、任务、文件修改、轨迹查看、会话管理。

### TUI (交互式)
```bash
sudo -iu dsh
cd ~/projects/demo
dsh-tui
```

### Headless / Codex 风格 CLI
```bash
sudo -iu dsh
cd ~/projects/demo
ds "任务"
```

`ds` 是本机包装脚本:
```text
/home/dsh/.local/bin/ds
```

常用:
```bash
ds "任务"
ds --save-id "任务"        # 保存 session id
ds -c "继续"              # 继续当前目录 session
ds -r <session-id> "继续" # 指定 session 继续聊
ds -j "任务"              # JSON 事件流
```

### 原生 headless
```bash
sudo -iu dsh
cd ~/projects/demo
dsh --profile headless --patch ~/.dsh/overlays/pekpik.yml "任务"
```
