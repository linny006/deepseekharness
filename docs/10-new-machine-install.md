# 10. 新机器从零部署 DSH

本文用于在一台全新机器上部署 DSH，包含账户原则、目录布局、权限配置和验收。

## 10.1 核心原则：必须新建专用账户

**不要用默认账户（`ubuntu` / `opc` / `root`）跑 DSH。**

默认账户是云主机登录入口，通常已经：

- 绑定 sudo 和 docker 组
- 家目录里有 `authorized_keys`、云凭据、历史命令
- 承担其他生产服务的运维

把 DSH Agent 放进默认账户，等于让 AI Agent 和你的管理员入口共用一套权限，影响面过大，容易误碰生产、误改 SSH、误读密钥。

正确做法：新建专用 `dsh` 账户，只给必要权限。

### 为什么这是红线

本仓库所在机器曾发生一次事故：为了让 `dsh` 写 `/home/ubuntu`，把默认账户家目录改成了组可写，结果 OpenSSH `StrictModes` 拒绝所有公钥认证，机器一度无法 SSH 登录。

结论：

- 默认账户家目录绝不改为组/其他可写
- DSH 数据全部放数据盘，和默认账户家目录物理隔离

详见 `docs/06-security-audit.md` 的 SSH 红线章节。

## 10.2 前置检查

```bash
cat /etc/os-release
uname -m
df -h /
free -h
```

推荐配置：

| 项 | 最低 | 推荐 |
|---|---|---|
| Ubuntu | 22.04 LTS | 22.04 及以上 |
| CPU | 2 核 | 4 核 |
| 内存 | 4 GB | 8 GB 以上 |
| 磁盘 | 20 GB | 50 GB SSD 以上 |

架构可为 `x86_64` 或 `aarch64`。

## 10.3 创建专用账户

```bash
# 创建无密码登录的专用账户（不可 SSH 登录）
sudo adduser --disabled-password --gecos "" dsh

# 不要给 dsh 加 sudo
```

需要生产部署能力时再加 docker 组（可选）：

```bash
sudo usermod -aG docker dsh
```

注意：docker 组等价宿主机 root，只在确实需要部署时开启。

## 10.4 数据盘与目录布局

把 DSH 数据和程序放在独立数据盘（假设挂载在 `/mnt/data`）：

```bash
sudo mkdir -p /mnt/data/dsh/{home,apps,projects,backups}
sudo chown -R dsh:dsh /mnt/data/dsh

# 建立 dsh 家目录软链，保持 DSH 默认路径兼容
sudo -iu dsh
ln -sfn /mnt/data/dsh/home     ~/.dsh
ln -sfn /mnt/data/dsh/apps     ~/apps
ln -sfn /mnt/data/dsh/projects ~/projects
```

最终布局：

```text
/mnt/data/dsh/
├── home/        # ~/.dsh，配置、会话、凭据、profile
├── apps/        # DSH 核心与 TUI 程序
├── projects/    # 工作区项目
└── backups/     # 备份输出
```

## 10.5 安装 Node.js 24

DSH 要求 Node.js 24.9+。使用 nvm 装在 `dsh` 用户下，**不要动系统 Node**：

```bash
sudo -iu dsh
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm install 24
nvm alias default 24
node -v    # 应为 v24.x
npm -v
```

## 10.6 安装 DSH 核心

固定版本安装，不要用 `latest`：

```bash
sudo -iu dsh
cd ~/apps
mkdir -p harness && cd harness
npm init -y
npm install --save-exact @deepseek-ai/dsh@0.2.2-rc.5

# 快捷命令
ln -sfn ~/apps/harness/node_modules/.bin/dsh ~/.local/bin/dsh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
dsh -V    # 应输出 0.2.2-rc.5
```

可选安装 TUI：

```bash
cd ~/apps
mkdir -p dsh-tui && cd dsh-tui
npm init -y
npm install --save-exact @deepseek-harness-tui/dsh-tui@0.20.1
ln -sfn ~/apps/dsh-tui/node_modules/.bin/dsh-tui ~/.local/bin/dsh-tui
```

## 10.7 配置 LLM 网关

凭据只放 `dsh` 家目录，权限 600，绝不进 Git：

```bash
sudo -iu dsh
cat > ~/.dsh/.env <<'EOF'
PEKPIK_API_KEY=<在这里填真实 key>
EOF
chmod 600 ~/.dsh/.env
```

provider 配置写入 `~/.dsh/profiles/web/cordis.patch.yml` 和
`~/.dsh/profiles/dsh-tui/cordis.patch.yml`，内容参考本仓库
`docs/01-deployment-overview.md` 的 LLM 路由配置小节。

如果网关返回非标准 thinking 数组，按 `docs/03-pi-ai-patch.md` 应用 pi-ai 补丁。

## 10.8 配置 systemd 服务

```bash
sudo tee /etc/systemd/system/deepseek-harness.service > /dev/null <<'EOF'
[Unit]
Description=DeepSeek Harness Web
Wants=network-online.target
After=network-online.target
RequiresMountsFor=/mnt/data/dsh

[Service]
Type=simple
User=dsh
Group=dsh
WorkingDirectory=/home/dsh/projects
Environment=HOME=/home/dsh
Environment=DSH_HOME=/home/dsh/.dsh
Environment=DSH_PERMISSION_MODE=workspace-write
EnvironmentFile=-/mnt/data/dsh/home/.env
Environment=PATH=/home/dsh/.nvm/versions/node/v24.22.3/bin:/home/dsh/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/dsh/.nvm/versions/node/v24.22.3/bin/node /home/dsh/apps/harness/node_modules/.bin/dsh web --no-open --host 127.0.0.1 --port 3080

Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/dsh /mnt/data/dsh
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
DevicePolicy=closed

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now deepseek-harness
sudo systemctl status deepseek-harness
```

## 10.9 Web UI 访问

DSH Web 只监听 `127.0.0.1:3080`，通过 SSH 隧道访问：

```bash
# 本地电脑执行
ssh -N -L 3080:127.0.0.1:3080 <SSH用户>@<服务器IP>
```

获取当前 token（全量日志，不要加 `-n`）：

```bash
sudo journalctl -u deepseek-harness --no-pager | grep -o 'token=[A-Za-z0-9_-]*' | tail -1
```

浏览器打开 `http://127.0.0.1:3080/?token=<上一步的值>`。

token 每次重启变化，没有固定 token 参数。

## 10.10 安全加固清单

| 项 | 要求 |
|---|---|
| 专用账户 | `dsh` 无 sudo，按需加 docker |
| 默认账户家目录 | 保持 `755`，绝不组可写（SSH 红线） |
| 凭据文件 | `600`，不进 Git |
| Web 监听 | 只 `127.0.0.1:3080` |
| systemd | 开启 `NoNewPrivileges`、`ProtectSystem=strict` 等 |
| 备份 | 加密保存，控制访问 |

## 10.11 验收清单

- [ ] `dsh -V` 输出版本正确
- [ ] `node -v` 为 v24.x
- [ ] `systemctl is-active deepseek-harness` 为 active
- [ ] `ss -lntp` 显示 3080 只绑 `127.0.0.1`
- [ ] 无 token 访问返回 401，带 token 返回 303
- [ ] `id dsh` 无 sudo，docker 组按需
- [ ] `/home/<默认账户>` 为 755，非组可写
- [ ] 凭据文件权限 600
- [ ] `~/.dsh`、`~/apps`、`~/projects` 软链指向数据盘

## 10.12 常见错误

1. **SSH 全部失联**
   原因：把默认账户家目录改成组可写。
   修复：恢复 `755`，见 `docs/04-troubleshooting.md` 的 StrictModes 章节。

2. **取不到 Web token**
   原因：命令加了 `-n`，启动日志被挤出窗口。
   修复：使用全量日志 `journalctl -u deepseek-harness --no-pager`。

3. **Node 版本过低**
   原因：用了系统 Node。
   修复：用 nvm 安装 Node 24，不要动系统 Node。
