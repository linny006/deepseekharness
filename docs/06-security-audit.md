# 6. 安全审计与风险

## 6.1 当前防护

### 用户隔离
- DSH 使用独立 `dsh` 用户
- 无 sudo 权限
- 不在 docker 组
- 家目录 700
- 无法读取 `/home/opc`、`/home/ubuntu`

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
- Mobile 网关 3443/3444/3445 未开启
- 不新增公网端口

### 凭据
- API key 存于:
  - `~/.dsh/.credentials.yaml`
  - `~/.dsh/.env`
- 权限 600
- 不写入 Git
- Web 登录 token 不写入 Git

### 沙箱
- `DSH_PERMISSION_MODE=workspace-write`
- 默认审批策略 ask
- 已安装 bubblewrap 0.6.1
- DSH 内置 sandbox-local 可用

## 6.2 已验证

| 检查 | 结果 |
|---|---|
| 3080 只绑定 127.0.0.1 | 通过 |
| 无 token 访问 401 | 通过 |
| 带 token 访问 303 -> 200 | 通过 |
| dsh 无 sudo | 通过 |
| dsh 无法读其他用户家目录 | 通过 |
| 凭据文件 600 | 通过 |
| systemd enabled | 通过 |
| 数据盘依赖 | 已加入 |
| bwrap 可运行 | 通过 |

## 6.3 重要风险: docker.sock 666

现象:
```text
srw-rw-rw- 1 root docker /var/run/docker.sock
```

风险:
- 任何本地用户都可以访问 Docker
- Docker socket 等价于宿主机 root
- `dsh` 用户也能借此提权

验证方式:
```bash
sudo -iu dsh docker ps
```

该问题是服务器既有配置, 不是 DSH 部署引入。

修复建议:
- 将 socket 权限收紧为 660
- 仅 root 和 docker 组访问
- 修改前必须评估现有容器、CI、脚本、服务账号

由于本机有长期运行的生产容器, 本部署未擅自修改。

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
| 3443 | 未监听 | Mobile LAN |
| 3444 | 未监听 | Mobile remote |
| 3445 | 未监听 | 测试端口 |

## 6.9 建议后续动作

1. 修复 `/var/run/docker.sock` 权限
2. 启用 fail2ban 或限制 SSH 来源
3. 定期轮换 pekpik API key
4. 加密备份 `/mnt/data/dsh`
5. 如需手机访问, 使用 Cloudflare Tunnel + Access 或 Tailscale, 不直接开公网端口
