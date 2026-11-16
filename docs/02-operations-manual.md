# 2. 日常操作手册

## 2.1 切换到 DSH 用户

DSH 安装在独立 `dsh` 用户下, 日常维护与使用均需先切换:
```bash
sudo -iu dsh
```

验证:
```bash
whoami        # dsh
node -v       # v24.22.3
dsh -V        # 0.2.2-rc.2
```

注意: 系统 `/usr/bin/node` 是 v12.22.9, 供其他生产服务使用, 不要修改。

## 2.2 Web UI (推荐使用)

### 重要：token 不是固定的

DSH Web token 在每次服务启动时随机生成，**没有固定 token 参数**。
服务重启后旧 token 立即失效。因此每次访问前都需要重新获取当前 token。

不要把 token 截图、转发或写入仓库。泄漏后重启服务即可让旧 token 失效。

**取 token 时不要加 `-n` 限制行数。**

token 只在服务启动时打印一次。如果写成 `journalctl -n 20`，服务运行一段时间后
那行启动日志会被挤出最近 20 行，导致命令返回空值。必须使用全量日志：

```bash
sudo journalctl -u deepseek-harness --no-pager | grep -o 'token=[A-Za-z0-9_-]*' | tail -1
```

### 方式一：手动 SSH 隧道（推荐）

**在【你自己的电脑】上执行**，不是在服务器上执行。

在本地电脑执行:
```bash
ssh -N -L 3080:127.0.0.1:3080 <用户>@<服务器IP>
```

另开一个终端获取当前 token:
```bash
ssh <用户>@<服务器IP> \
  "sudo journalctl -u deepseek-harness --no-pager | grep -o 'token=[A-Za-z0-9_-]*' | tail -1"
```

浏览器打开:
```text
http://127.0.0.1:3080/?token=<上一步取到的值>
```

### 方式二：在服务器本机访问

如果就在服务器终端上操作（或在服务器桌面环境）:
```bash
sudo journalctl -u deepseek-harness --no-pager | grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*' | tail -1
```
浏览器打开该 URL。

### 方式三：手机端（无需 token）

手机使用 `https://dsh.spectracodeai.com`，用 Relay 账号登录，
不需要 DSH Web token。详见 `docs/08-mobile-remote-access.md`。

### 为什么必须走 SSH 隧道

DSH Web 只监听 `127.0.0.1:3080`，不暴露公网。这是安全设计，
不要为了省事把 3080 开到公网。

### 常见页面操作
- Workspace: 选择 `/mnt/data/dsh/projects` 或其中具体项目
- Session: 新建或恢复会话
- Chat: 输入任务
- 轨迹 (Trajectory): 查看系统提示词、工具调用、文件修改、时间等上下文

## 2.3 TUI

```bash
sudo -iu dsh
tmux new -s coding
cd ~/projects/demo
dsh-tui
```

离开 tmux: `Ctrl+B`, 然后 `D`  
恢复:
```bash
sudo -iu dsh
tmux attach -t coding
```

退出 TUI: 输入 `/quit` 并回车。

## 2.4 Codex 风格 CLI (`ds`)

`ds` 包装了 DSH headless 模式, 适合一次性任务与多轮续聊。

一次性任务:
```bash
sudo -iu dsh
cd ~/projects/demo
ds "分析当前项目并说明目录结构"
```

保存 session id:
```bash
ds --save-id "记住 magic=888"
```

续聊:
```bash
ds -c "magic 是多少？"
```

指定 session:
```bash
ds -r <session-id> "继续刚才的任务"
```

JSON 事件流:
```bash
ds -j "创建 test.js 并运行"
```

`ds` 会读取:
```text
~/.dsh/.env
~/.dsh/overlays/pekpik.yml
```

## 2.5 备份

```bash
sudo -iu dsh
/mnt/data/dsh/bin/dsh-backup.sh
```

输出:
```text
/mnt/data/dsh/backups/dsh-backup-<timestamp>.tar.gz
```

备份内容:
- DSH home
- projects

注意: 备份包含 API key、会话内容、模型请求历史等敏感数据。应加密保存并严格控制访问。

## 2.6 服务管理

状态:
```bash
sudo systemctl status deepseek-harness
```

启动:
```bash
sudo systemctl start deepseek-harness
```

停止:
```bash
sudo systemctl stop deepseek-harness
```

重启:
```bash
sudo systemctl restart deepseek-harness
```

日志:
```bash
sudo journalctl -u deepseek-harness -n 100 --no-pager
```

获取当前登录 URL:
```bash
sudo journalctl -u deepseek-harness --no-pager | grep -o 'token=[A-Za-z0-9_-]*' | tail -1
```

## 2.7 工作区管理

默认工作区:
```text
/mnt/data/dsh/projects
```

建议:
- 每个独立项目放 `/mnt/data/dsh/projects/<项目名>`
- 并行任务使用 git worktree, 不要让多个 agent 同时写同一目录
- 不要把生产 SSH key、云 token、数据库密码放在默认工作区

## 2.8 模型配置

配置文件:
```text
~/.dsh/profiles/web/cordis.patch.yml
~/.dsh/profiles/dsh-tui/cordis.patch.yml
```

headless overlay:
```text
~/.dsh/overlays/pekpik.yml
```

修改后需重启对应 profile 或服务:
```bash
sudo systemctl restart deepseek-harness
```

模型列表:
- provider: `pekpik`
- model: `deepseek-v4-1-flash-1017`

重试策略:

```yaml
retryPolicy:
  mode: normal
  maxRetries: 6
  retryableCodes:
    - EMPTY_RESPONSE
    - RATE_LIMIT
    - SERVER
    - TIMEOUT
    - TRANSPORT
    - STREAM_CLOSED
```

该配置已同步到:

```text
~/.dsh/profiles/web/cordis.patch.yml
~/.dsh/profiles/dsh-tui/cordis.patch.yml
~/.dsh/overlays/pekpik.yml
```

`maxRetries: 6` 表示最多重试 6 次，即单次请求最多发起 7 次调用。修改后必须重启 `deepseek-harness`。

## 2.9 手机远程访问

当前手机入口是 `ds-harness-remote@0.6.4` + 自建 Relay Server，不再是 `dsh-mobile`。

当前状态:
- Relay 容器：`dsh-remote-server-server-1`
- Relay 地址：`127.0.0.1:8080`
- 公网地址：`https://dsh.spectracodeai.com`
- Host：`aiapp`
- Relay 目录：`/mnt/data/dsh-remote-server`
- DSH Web 仍只监听 `127.0.0.1:3080`

日常检查：

```bash
cd /mnt/data/dsh-remote-server
docker compose ps
sudo journalctl -u deepseek-harness -n 100 --no-pager |
  grep ds-harness-remote
```

不要把 3080、8080 或 `dsh-mobile` 的 3443/3444 端口开到公网。

## 2.10 安全提醒

- 不要提交 `.env`、`.credentials.yaml`、带 token 的 URL
- 不要把 API key 写入项目代码
- 不要在不可信任务中给 `dsh` 使用 Docker 权限
- 定期备份并轮换 API key
- Web URL 中的 token 等同密码, 泄漏后需重启服务使其失效

## 2.11 DSH 用户权限

当前授权:

| 目标 | 权限 | 说明 |
|---|---|---|
| `/mnt/data` | 完整读写, 递归归属 `dsh:dsh` | 覆盖数据盘全部内容 |
| Docker | `dsh` 在 `docker` 组 | 可查看容器、构建镜像、部署 Compose |
| `/home/ubuntu` | 不授权给 `dsh` | 保持 `755 ubuntu:ubuntu` |
| `/home/ubuntu/.ssh` | 不可访问 | 保持 `700 ubuntu:ubuntu` |

验证:

```bash
id dsh
stat -c '%A %U:%G %n' /mnt/data /home/ubuntu /home/ubuntu/.ssh
sudo -iu dsh docker ps
```

`dsh` 加入 `docker` 组后，需要重新登录或重启相关会话才会生效。Docker socket 等价于宿主机 root 权限，不要在不可信任务中开放 Docker 能力。

### 严禁事项：不要修改 `/home/ubuntu` 权限

OpenSSH 的 `StrictModes` 要求用户家目录不能被组或其他用户写入。
如果把 `/home/ubuntu` 改成 `ubuntu:dsh` + `2770`（组可写），所有机器的公钥认证都会被拒绝：

```text
Authentication refused: bad ownership or modes for directory /home/ubuntu
```

后果是这台机器完全无法通过 SSH 登录。

正确做法：

- `/home/ubuntu` 必须为 `755 ubuntu:ubuntu`（无组写）
- `/home/ubuntu/.ssh` 必须为 `700 ubuntu:ubuntu`
- `/home/ubuntu/.ssh/authorized_keys` 必须为 `600 ubuntu:ubuntu`
- `dsh` 需要读写 ubuntu 数据时，通过 `/mnt/data` 下的共享目录，不碰 `/home/ubuntu`
