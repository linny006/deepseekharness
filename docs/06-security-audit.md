# 6. 安全审计与风险

## 6.1 当前防护

### 用户隔离
- DSH 使用独立 `dsh` 用户
- 无 sudo 权限
- 已按运维需求加入 `docker` 组
- 家目录 700
- 只读写 `/mnt/data`
- 不访问 `/home/ubuntu`，`.ssh` 权限保持 `700`

### 服务加固
systemd 单元包含:
- User=dsh / Group=dsh
- NoNewPrivileges=true
- PrivateTmp=true
- ProtectSystem=strict
- ProtectHome=read-only
- ReadWritePaths=/home/dsh /mnt/data/dsh
- ProtectKernelTunables=true
- ProtectKernelModules=true
- ProtectControlGroups=true
- ProtectClock=true
- ProtectHostname=true
- ProtectProc=invisible
- RestrictSUIDSGID=true
- RestrictRealtime=true
- LockPersonality=true
- RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
- SystemCallArchitectures=native
- CapabilityBoundingSet=
- DevicePolicy=closed

### 网络暴露
- Web 只监听 `127.0.0.1:3080`
- 3080 未出现在 0.0.0.0 或 [::]
- Relay Server 只监听 `127.0.0.1:8080`
- 旧 Mobile 网关 3443/3444/3445 未开启
- 不新增公网端口

### 凭据
- API key 存于:
  - `~/.dsh/.credentials.yaml`
  - `~/.dsh/.env`
- 权限 600
- 不写入 Git
- Web 登录 token 不写入 Git

注意：由于 `/mnt/data` 已完整授权给 `dsh`，`dsh` 也能读取
`/mnt/data/dsh-remote-server/.env`。该文件包含 Relay 登录密码，必须仅用于可信部署任务。

### 沙箱
- `DSH_PERMISSION_MODE=workspace-write`
- 默认审批策略 ask
- 已安装 bubblewrap 0.6.1
- DSH 内置 sandbox-local 可用

## 6.2 已验证

| 检查 | 结果 |
|---|---|
| 3080 只绑定 127.0.0.1 | 通过 |
| 8080 只绑定 127.0.0.1 | 通过 |
| 无 token 访问 401 | 通过 |
| 带 token 访问 303 -> 200 | 通过 |
| dsh 无 sudo | 通过 |
| `/mnt/data` 归属 `dsh:dsh` | 通过 |
| `dsh` 无法读取 `/home/ubuntu/.ssh` | 通过 |
| `dsh` 可访问 Docker | 通过 |
| 凭据文件 600 | 通过 |
| systemd enabled | 通过 |
| 数据盘依赖 | 已加入 |
| bwrap 可运行 | 通过 |

## 6.3 重要风险: dsh 加入 docker 组

当前配置:

```text
dsh groups: dsh,docker
```

风险:
- Docker socket 等价于宿主机 root
- `dsh` 可通过 Docker 挂载宿主路径、特权容器或修改生产容器
- 如果 Agent 输出或插件被诱导执行 Docker 命令，可能造成宿主机提权

验证方式:
```bash
sudo -iu dsh docker ps
```

修复建议:
- 如不再需要部署能力，执行 `sudo deluser dsh docker`
- 如保留能力，仅在可信任务中使用
- 不把 Docker 命令暴露给不可信 Agent
- 使用独立 rootless Docker 或专用部署账户作为长期方案

## 6.3.1 SSH 家目录权限（红线）

`/home/ubuntu` 绝不能设为组/其他可写，否则 OpenSSH `StrictModes`
会拒绝所有公钥认证，导致机器无法 SSH 登录。

```text
Authentication refused: bad ownership or modes for directory /home/ubuntu
```

已发生并修复过。当前标准：

- `/home/ubuntu` = `755 ubuntu:ubuntu`
- `/home/ubuntu/.ssh` = `700 ubuntu:ubuntu`
- `/home/ubuntu/.ssh/authorized_keys` = `600 ubuntu:ubuntu`

任何操作都不要对家目录执行 `chmod g+w`、`chown ubuntu:dsh` 或 `chmod g+s`。

## 6.4 SSH 暴露

当时审计结果:
- PasswordAuthentication no
- PermitRootLogin without-password
- 7 天内 SSH 失败记录约 5328 条
- fail2ban 未启用

建议:
- 保持仅密钥登录
- 考虑启用 fail2ban 或云安全组限源
- 不要为 DSH 单独开放 3080

## 6.5 Web token 风险

Web URL 中 token 等同登录密码:
- 泄漏后可控制 Agent
- Agent 能写 workspace 文件
- 可运行受控命令

要求:
- 不截图、不转发、不提交
- token 疑似泄漏时重启服务
- 重启会生成新 token

## 6.5.1 远程 Relay 凭据风险

Relay 登录成功后可以连接 Host 并使用 DSH 能力：

- 不要共享 `owner@spectracodeai.com` 的密码
- 密码只保存在 `/mnt/data/dsh-remote-server/.env`
- 手机丢失或凭据泄漏时立即修改密码
- 修改密码后需要重新授权 DSH Host 和手机端

## 6.6 Agent 权限边界

- workspace-write 允许写当前工作区
- 审批策略 ask
- 插件运行在 dsh 用户权限内
- profile 不是安全沙箱
- 不要把生产密钥放在默认可读目录
- 不可信代码应使用容器/VM 额外隔离

## 6.7 数据保密

- 会话可能包含项目源码和任务内容
- 请求会发送到外部 LLM 网关
- 备份包含 API key 和会话
- 需要加密备份并控制访问

## 6.8 端口清单

| 端口 | 状态 | 说明 |
|---|---|---|
| 3080 | 127.0.0.1 | Web UI |
| 8080 | 127.0.0.1 | ds-harness-remote Relay |
| 3443 | 未监听 | Mobile LAN |
| 3444 | 未监听 | Mobile remote |
| 3445 | 未监听 | 测试端口 |

## 6.9 建议后续动作

1. 修复 `/var/run/docker.sock` 权限
2. 启用 fail2ban 或限制 SSH 来源
3. 定期轮换 pekpik API key
4. 加密备份 `/mnt/data/dsh`
5. 为远程 Relay 增加 Cloudflare WAF、限流或 Access 前先验证 WebSocket 不受影响
