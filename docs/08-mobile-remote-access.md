# 8. 手机远程访问配置（ds-harness-remote 自建 Relay）

## 8.1 当前结论

当前手机远程访问不再使用以下旧方案：

- 不再把 `dsh.spectracodeai.com` 反向代理到 DSH Web `127.0.0.1:3080`
- 不再通过公网 URL 携带 DSH Web token 登录
- 不再以 `dsh-mobile` 插件作为手机入口

当前方案为 `ds-harness-remote 0.6.4` 插件、自建 Relay Server、nginx HTTPS 反代和 Cloudflare 橙色云代理。公网域名是：

```text
https://dsh.spectracodeai.com
```

这个域名现在只访问自建 Relay Server，不直接访问 DSH Web。

## 8.2 架构

```text
Android App / 手机浏览器 / 电脑浏览器
    │
    │ HTTPS / WebSocket
    ▼
Cloudflare 橙色云代理
    │  隐藏源站 IP
    ▼
nginx 443 (dsh.spectracodeai.com)
    │
    │ proxy_pass + WebSocket Upgrade
    ▼
ds-harness-remote Relay Server
    │  Docker 容器, 127.0.0.1:8080
    │
    │ Host 插件主动出站连接
    ▼
DeepSeek Harness Web Profile
    │  127.0.0.1:3080, 仅本机
    ▼
/mnt/data/dsh 下的项目、会话与工具
```

关键特征：

- DSH Web 仍然只监听 `127.0.0.1:3080`
- Relay Server 只监听 `127.0.0.1:8080`
- 公网只暴露 nginx 443
- DSH Host 不需要监听公网端口，由插件主动连接 Relay
- 手机端登录 Relay 账号，再选择已授权且在线的 Host

## 8.3 组件与版本

| 组件 | 当前版本 | 位置 |
|---|---:|---|
| DSH `web` Profile 插件 | `ds-harness-remote@0.6.4` | `/mnt/data/dsh/home/profiles/web` |
| Relay Server | 源码构建，容器 `dsh-remote-server-server-1` | `/mnt/data/dsh-remote-server` |
| Android App | `v0.6.4` | GitHub Releases |
| 浏览器客户端 | Relay Server 自带 `/app` 页面 | `https://dsh.spectracodeai.com` |
| DSH Web | `0.2.2-rc.2` | systemd `deepseek-harness` |
| 旧 `dsh-mobile` 插件 | `0.8.8` | 暂保留，未作为手机入口 |

`dsh-mobile@0.8.8` 仍安装在 `web` Profile 中。为了避免误删和保留回滚能力，暂时不卸载。远程方案稳定后，可以评估是否移除。

## 8.4 部署目录与配置

### Relay Server

```text
/mnt/data/dsh-remote-server/
├── .env                 # 登录账号、密码、公网 URL，权限受限，不进 Git
├── compose.yaml         # Docker Compose 配置
└── src/                 # ds-harness-remote 源码，用于 aarch64 构建
```

`.env` 中的关键配置：

```text
DSH_SERVER_ACCOUNT=owner@spectracodeai.com
DSH_SERVER_PASSWORD=<保存在服务器，不要写入本文>
DSH_SERVER_HOST=127.0.0.1
DSH_SERVER_PORT=8080
DSH_SERVER_PUBLIC_URL=https://dsh.spectracodeai.com
DSH_SERVER_LOG_LEVEL=info
```

注意：

- 登录接口和 App 均使用 `email` 字段
- 账号当前为 `owner@spectracodeai.com`
- 密码只在服务器 `.env` 中查看，不要复制到聊天、文档或 Git
- `DSH_SERVER_PUBLIC_URL` 必须与浏览器和 App 填写的域名完全一致

### Docker Compose

```text
/mnt/data/dsh-remote-server/compose.yaml
```

重要默认值：

| 环境变量 | 默认值 | 说明 |
|---|---:|---|
| `DSH_SERVER_HELLO_TIMEOUT_MS` | `5000` | 连接握手超时 |
| `DSH_SERVER_HEARTBEAT_INTERVAL_MS` | `25000` | 心跳间隔 |
| `DSH_SERVER_HEARTBEAT_DISCONNECT_MS` | `75000` | 超过该时间无心跳则断开 |
| `DSH_SERVER_LOG_LEVEL` | `info` | 日志级别 |

当前没有配置 TURN。如果手机网络下出现连接质量差或无法建立数据通道，再评估是否增加 TURN，不要在未测试前盲目添加。

### nginx

配置文件：

```text
/etc/nginx/sites-available/dsh.spectracodeai.com.conf
/etc/nginx/sites-enabled/dsh.spectracodeai.com.conf
```

关键配置：

```nginx
proxy_pass http://127.0.0.1:8080;
proxy_http_version 1.1;

proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";

proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

proxy_connect_timeout 10s;
proxy_send_timeout 300s;
proxy_read_timeout 300s;

proxy_buffering off;
proxy_cache off;
```

`proxy_read_timeout 300s` 大于 Relay 默认 `75s` 心跳断开时间，因此长连接不会被 nginx 提前切断。

### Cloudflare

当前状态：

- DNS：`dsh.spectracodeai.com`
- 代理状态：橙色云，Proxied
- 源站 IP：已隐藏
- WebSocket：Cloudflare 默认支持，无需单独开启开关

建议：

- SSL/TLS 模式使用 `Full (strict)`
- 保持 nginx 的真实证书
- 不要在 Cloudflare 额外改写路径或 Host
- 可按需增加 WAF、限流或 Access，但不要影响 WebSocket

## 8.5 Host 端配置

Host 指 Ubuntu 上的 DSH Web 服务。手机不能直接连 `127.0.0.1:3080`，必须先让 Host 登录 Relay。

### 8.5.1 打开 DSH Web

在管理电脑执行 SSH 隧道：

```bash
ssh -N -L 3080:127.0.0.1:3080 <SSH用户>@<服务器IP>
```

获取登录 URL：

```bash
sudo journalctl -u deepseek-harness --no-pager |
  grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*' | tail -1
```

在本地浏览器打开该 URL。不要把带 token 的 URL 发给别人，也不要写入 Git。

### 8.5.2 登录 Relay

在 DSH Web 左侧打开 `Remote`：

1. 如果已有旧授权，先退出登录
2. Server URL 填 `https://dsh.spectracodeai.com`
3. Email 填 `owner@spectracodeai.com`
4. Password 从 `/mnt/data/dsh-remote-server/.env` 读取
5. 登录并保持 Host 在线

当前 Host 名称是：

```text
aiapp
```

Host 在线后，插件会主动连接 Relay，无需在服务器防火墙开放 DSH Web 端口。

## 8.6 Android App 配置

### 8.6.1 下载

打开：

```text
https://github.com/liguobao/ds-harness-remote/releases/latest
```

当前安装版本：

```text
v0.6.4
```

APK：

```text
dsh-remote-android-v0.6.4.apk
```

建议同时下载并核对：

```text
SHA256SUMS.txt
```

在电脑上下载后可用以下命令校验：

```bash
sha256sum dsh-remote-android-v0.6.4.apk
grep dsh-remote-android-v0.6.4.apk SHA256SUMS.txt
```

### 8.6.2 登录

在 Android App 中打开远程连接设置：

| 配置项 | 值 |
|---|---|
| Server URL | `https://dsh.spectracodeai.com` |
| Email | `owner@spectracodeai.com` |
| Password | `/mnt/data/dsh-remote-server/.env` 中的 `DSH_SERVER_PASSWORD` |

登录后选择在线 Host：

```text
aiapp
```

不要选择旧域名 `https://dsh.r2049.cn`，也不要使用 DSH Web token 登录 App。

### 8.6.3 当前已验证状态

部署完成后已验证：

- Relay 容器状态为 `healthy`
- Host `aiapp` 已注册并在线
- 手机设备 `PGW110 · DSH Remote` 已注册并在线
- DSH 日志出现连续 `host rpc ok`
- 手机可以连接 Host 并进入远程界面

## 8.7 手机浏览器 / iPhone 配置

浏览器客户端地址：

```text
https://dsh.spectracodeai.com
```

流程：

1. 打开上面的地址
2. 进入 `/app/login`
3. 使用同一账号密码登录
4. 进入 `/app/remote`
5. 选择 Host `aiapp`

iPhone 当前可使用浏览器页面。若需要原生 iOS 客户端，该项目官方说明仍为 TestFlight beta，需要单独申请，不在本次部署范围内。

iPhone 可在 Safari 中：

```text
分享 → 添加到主屏幕
```

以后从主屏幕图标打开。

## 8.8 授权失效问题记录

### 错误信息

手机端曾出现：

```text
授权已失效，请退出授权后重新连接此 Host。
```

### 当时日志

DSH 日志中出现过：

```text
[ds-harness-remote] server control connection failed
{"code":"ACCOUNT_AUTH_REQUIRED","retryable":false,"status":401}

[ds-harness-remote] Host authorization failed. Authorize this Host again from a Remote client or in Remote settings.
```

查询 Relay 设备列表时，最初返回：

```json
{
  "items": []
}
```

### 根因

这不是账号密码错误，而是 Host 尚未在新的自建 Relay Server 上完成授权注册。

当时发生了两个变化：

1. 从旧方案切换到自建 Relay Server
2. Host 产生了新的设备身份

手机端仍保留旧授权状态，或 Host 未登录新 Relay，导致 Relay 无法确认 Host 与当前账号的归属关系。

### 处理步骤

1. 在 DSH Web 的 `Remote` 面板退出旧授权
2. Server URL 填 `https://dsh.spectracodeai.com`
3. 使用 Relay 账号密码重新登录
4. 等待 Host `aiapp` 注册并在线
5. 在手机 App 中退出登录
6. 如仍复现，清除 App 存储或删除旧 Host 记录
7. 手机重新使用同一 Server URL、Email、Password 登录
8. 选择新的 Host `aiapp`

处理后已验证：

- Relay 设备列表出现在线 Host
- 手机设备在线
- DSH 日志不再出现 `ACCOUNT_AUTH_REQUIRED`
- 远程 RPC 正常

### 为什么会出现重复 Host 名称

Relay 设备列表中可能看到两个 `aiapp`：

- 一个是切换域名或重新初始化身份前的旧 Host 记录
- 一个是当前在线的新 Host 记录

优先选择显示在线的 `aiapp`。远程方案稳定后，可在 Relay 管理界面清理旧设备记录。清理前确认不会误删当前 Host 或手机。

## 8.9 其他常见错误

### 登录失败

检查顺序：

1. Server URL 是否为 `https://dsh.spectracodeai.com`
2. 输入框是否为 Email，而不是用户名
3. Email 是否为 `owner@spectracodeai.com`
4. 密码是否与 `.env` 中 `DSH_SERVER_PASSWORD` 完全一致
5. Relay 是否运行：

   ```bash
   cd /mnt/data/dsh-remote-server
   docker compose ps
   ```

6. HTTPS 入口是否可用：

   ```bash
   curl -I https://dsh.spectracodeai.com/app/login
   ```

### 无法看到 Host

1. 检查 DSH 服务：

   ```bash
   sudo systemctl status deepseek-harness
   ```

2. 检查插件日志：

   ```bash
   sudo journalctl -u deepseek-harness -n 100 --no-pager |
     grep ds-harness-remote
   ```

3. 确认 DSH Web `Remote` 面板仍处于登录状态
4. 检查 Relay 设备列表：

   ```bash
   cd /mnt/data/dsh-remote-server
   # shellcheck disable=SC1091
   source .env

   LOGIN_RESPONSE=$(curl -sS \
     -X POST "$DSH_SERVER_PUBLIC_URL/api/v1/auth/login" \
     -H 'Content-Type: application/json' \
     -d "$(jq -n \
       --arg email "$DSH_SERVER_ACCOUNT" \
       --arg password "$DSH_SERVER_PASSWORD" \
       '{email:$email,password:$password}')")

   AUTH_TOKEN=$(printf '%s' "$LOGIN_RESPONSE" | jq -r '.token // empty')

   curl -sS \
     -H "Authorization: Bearer $AUTH_TOKEN" \
     "$DSH_SERVER_PUBLIC_URL/api/v1/account/devices" | jq .
   ```

期望结果：

- Host `aiapp` 在线
- 手机设备在线

### `CODEX_BINARY_UNAVAILABLE`

日志示例：

```text
[ds-harness-remote] Codex App Server communication failed
{"code":"CODEX_BINARY_UNAVAILABLE"}
```

含义：

- 服务器上没有安装 Codex App Server 相关二进制
- 不影响 DSH Host 和手机连接 DSH

本项目不需要为消除该日志安装 Codex。

### `CURSOR_BINARY_UNAVAILABLE` / `Antigravity ENOENT`

日志示例：

```text
[ds-harness-remote] Cursor ACP communication failed
{"code":"CURSOR_BINARY_UNAVAILABLE"}

[ds-harness-remote] Antigravity binary error
{"message":"spawn agy ENOENT"}
```

含义：

- 未安装 Cursor 或 Antigravity 客户端
- 这些是 ds-harness-remote 对其他开发工具的可选支持
- 不影响 DSH 远程功能

### 524 超时

Cloudflare HTTP 代理超时约为 100 秒。远程核心通信走 WebSocket，不应按普通 HTTP 请求评估。

如果出现 524：

1. 确认请求路径不是被当成长 HTTP 响应处理
2. 检查 nginx WebSocket Upgrade 配置
3. 检查 `proxy_read_timeout 300s`
4. 查看 Relay 日志：

   ```bash
   cd /mnt/data/dsh-remote-server
   docker compose logs -f server
   ```

### 浏览器白屏或 JS/CSS 403

官方说明提示该情况通常与 Origin 校验有关。

检查：

1. `DSH_SERVER_PUBLIC_URL` 是否等于浏览器实际域名
2. nginx 是否保留了原始 `Origin`
3. Cloudflare 或 nginx 是否额外改写了 Host / Origin / 路径

不要通过移除 MIME 类型或关闭 Origin 校验来绕过问题。

## 8.10 日常运维

以下命令均使用有 sudo / docker 权限的管理员账户执行，不要切换到 `dsh` 用户执行 Docker 命令。

### 查看状态

```bash
sudo systemctl status deepseek-harness

cd /mnt/data/dsh-remote-server
docker compose ps
```

### 查看 Relay 日志

```bash
cd /mnt/data/dsh-remote-server
docker compose logs -f server
```

### 查看 DSH 插件日志

```bash
sudo journalctl -u deepseek-harness -n 100 --no-pager |
  grep ds-harness-remote
```

### 重启 Relay

```bash
cd /mnt/data/dsh-remote-server
docker compose restart server
```

### 重启 DSH Host

```bash
sudo systemctl restart deepseek-harness
```

DSH Web token 会随服务重启变化。Host 重新启动后，`ds-harness-remote` 插件会自动重新连接 Relay。

### 停止和启动 Relay

```bash
cd /mnt/data/dsh-remote-server
docker compose stop server
docker compose start server
```

### 修改账号或密码

1. 备份 `/mnt/data/dsh-remote-server/.env`
2. 修改 `.env`
3. 重建容器环境：

   ```bash
   cd /mnt/data/dsh-remote-server
   docker compose up -d
   ```

4. DSH Web `Remote` 面板和手机 App 都需要重新登录

### 更新 Relay 源码

更新前必须确认：

- 当前手机远程使用正常
- 已备份 `.env` 和 Docker volume
- 明确目标版本与插件版本兼容

流程：

```bash
cd /mnt/data/dsh-remote-server/src
git fetch --all --tags
git checkout <目标版本标签>

cd /mnt/data/dsh-remote-server
docker compose build --no-cache server
docker compose up -d
docker compose ps
```

不要使用未确认的 `main` 分支直接更新生产服务。

### 8.10.1 同机 Relay 容器加固（2026-11-15 已实施）

为降低 Relay 被攻破后的影响面，对同机 Relay 容器增加了纵深防御：

```yaml
read_only: true
tmpfs:
  - /tmp
cap_drop:
  - ALL
security_opt:
  - no-new-privileges:true
stop_grace_period: 10s
```

加固说明：

- `read_only: true`：根文件系统只读，只有 `/data` volume 可写
- `tmpfs: [/tmp]`：临时目录放内存，不落盘
- `cap_drop: [ALL]`：移除全部 Linux capabilities
- `no-new-privileges`：禁止容器内进程提权
- 容器内运行用户仍是 `node`（非 root），`Privileged=false`
- 未改变端口、volume、环境变量和 relay 协议，不影响手机连接

验证：

```bash
sudo docker inspect dsh-remote-server-server-1 \
  --format 'Privileged={{.HostConfig.Privileged}} CapDrop={{.HostConfig.CapDrop}} ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} NoNewPrivs={{.HostConfig.SecurityOpt}}'
```

预期：

```text
Privileged=false CapDrop=[ALL] ReadonlyRootfs=true NoNewPrivs=[no-new-privileges:true]
```

回滚：

```bash
cd /mnt/data/dsh-remote-server
sudo docker compose up -d --force-recreate server
```

如果加固导致 relay 无法写状态或无法启动，先查看容器日志定位，不要直接删除 relay volume。

### 8.10.2 红线：不要触碰 SSH 家目录

本方案只修改 relay 的 Docker 配置。任何时候都不要为任何目的把
`/home/ubuntu` 改成组/其他可写，否则 OpenSSH `StrictModes` 会拒绝所有公钥认证，
导致机器无法登录。相关修复和红线见 `docs/06-security-audit.md`。

## 8.11 备份与恢复

### 需要备份的内容

```text
/mnt/data/dsh-remote-server/.env
/mnt/data/dsh-remote-server/compose.yaml
/mnt/data/dsh-remote-server/src 的当前 Git 版本
Relay Docker volume
```

查看 volume 名称：

```bash
docker volume ls | grep dsh-remote-server
```

通常为：

```text
dsh-remote-server_server-data
```

### 备份示例

```bash
sudo install -d -m 700 /mnt/data/dsh/backups/remote-server

sudo cp -a \
  /mnt/data/dsh-remote-server/.env \
  /mnt/data/dsh-remote-server/compose.yaml \
  /mnt/data/dsh/backups/remote-server/

sudo tar -C /var/lib/docker/volumes \
  -czf /mnt/data/dsh/backups/remote-server/server-data.tar.gz \
  dsh-remote-server_server-data
```

备份中包含账号密码和设备授权状态，必须加密或严格限制权限。

### 恢复思路

1. 恢复 `.env` 和 `compose.yaml`
2. 恢复 Docker volume
3. 启动 Relay
4. 如设备授权失效，在 DSH Web 和手机端重新登录授权

## 8.12 安全边界

### 暴露面

| 端口 / 入口 | 状态 | 说明 |
|---|---|---|
| `127.0.0.1:3080` | 仅本机 | DSH Web，不暴露公网 |
| `127.0.0.1:8080` | 仅本机 | Relay Server，不直接暴露 |
| `443` | 公网 | nginx，仅转发到 Relay |
| DSH Web token | 不进入公网域名 | 只通过 SSH 隧道使用 |

### 凭据风险

- Relay 账号密码可以连接 Host
- Host 登录后，手机端可查看项目并发起 Agent 任务
- Agent 具备当前工作区和审批策略下的能力

要求：

- 不共享 Relay 密码
- 不把 `.env`、token、API key 写入 Git
- 手机丢失或账号泄漏时立即修改 Relay 密码
- 修改密码后在 DSH Web 和手机端重新登录

### 数据传输

- Cloudflare 到 nginx 使用 HTTPS
- nginx 到 Relay 在本机回环地址通信
- Relay 与 Host、客户端使用项目自身通道

如果需要更强的网络层控制，可在 Cloudflare 增加 Access、WAF 或限流，但必须先验证不影响 WebSocket 和 App 连接。

### 关于 Relay 是否独立服务器

当前 Relay 与 DSH 同机，公网只暴露 `127.0.0.1:8080` + nginx 443，
源站 IP 已被 Cloudflare 隐藏，满足基本安全要求。

但同机意味着单一风险点：若 Relay 被攻破，可接触同机 DSH、项目代码和凭据。

可选改进（按成本排序）：

1. 保留同机，但限制 Relay 容器能力（禁用 Docker 特权、限制挂载、限制 `/mnt/data` 访问范围）
2. 改用 Cloudflare Tunnel 或 Tailscale，不暴露 nginx 公网端口
3. 把 Relay 放到独立轻量 VPS，只运行 Docker，不存放项目代码和凭据

当前保持同机部署，后续按需升级隔离。

> 状态：**计划中，暂不执行。** 需要另选方案（独立 VPS / Cloudflare Tunnel / Tailscale）
> 后再实施，当前不要改动 relay 或 nginx 配置，以免影响手机连接。

## 8.13 验收命令

```bash
# DSH Host
sudo systemctl is-active deepseek-harness

# Relay
cd /mnt/data/dsh-remote-server
docker compose ps

# HTTPS 入口
curl -I https://dsh.spectracodeai.com/app/login

# DNS 应返回 Cloudflare IP，不应暴露源站 IP
dig +short A dsh.spectracodeai.com

# DSH Web 仍然只绑定回环
sudo ss -lntp | grep 3080

# Relay 仍然只绑定回环
sudo ss -lntp | grep 8080

# 插件运行日志
sudo journalctl -u deepseek-harness -n 100 --no-pager |
  grep ds-harness-remote
```

验收通过标准：

- DSH 服务 active
- Relay 容器 healthy
- HTTPS 入口可访问
- DNS 返回 Cloudflare IP
- 3080 和 8080 都只监听 `127.0.0.1`
- 设备列表中 Host 与手机在线
- 手机可创建或继续 DSH 会话
