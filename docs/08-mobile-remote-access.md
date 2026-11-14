# 8. 手机远程访问配置

## 8.1 架构

```
手机 (Android/iPhone)
    │
    │ HTTPS
    ▼
Cloudflare 橙色云代理 (隐藏真实 IP, WAF, DDoS 防护)
    │
    │ HTTPS (仅 Cloudflare IP 段可访问)
    ▼
nginx 443 (dsh.spectracodeai.com)
    │
    │ proxy_pass + WebSocket upgrade
    ▼
DSH Web (127.0.0.1:3080)
    │
    ├── Web UI
    ├── Mobile 插件
    └── WebSocket 实时通信 (/api/remote.mux)
```

## 8.2 域名和证书

- 域名: `dsh.spectracodeai.com`
- DNS: Cloudflare 托管, 橙色云 (Proxied)
- 真实 IP: 已隐藏, 外部只能看到 Cloudflare IP
- 证书: Let's Encrypt, 路径 `/etc/letsencrypt/live/dsh.spectracodeai.com/`
- 证书到期: 2027-02-12, certbot 自动续期

## 8.3 nginx 配置

文件:
```text
/etc/nginx/sites-available/dsh.spectracodeai.com.conf
/etc/nginx/sites-enabled/dsh.spectracodeai.com.conf (软链)
```

关键配置:
- `proxy_pass http://127.0.0.1:3080`
- WebSocket: `Upgrade` + `Connection "upgrade"`
- `proxy_read_timeout 300s` (WebSocket 长连接)
- `proxy_buffering off` (流式响应不缓冲)
- `client_max_body_size 50m` (文件上传)

## 8.4 防火墙

无需新增规则。现有防火墙已:
- 443 端口对 Cloudflare IP 段开放
- 443 端口对公网开放 (azurebobotos3-public-https)
- 3080 只监听 127.0.0.1, 不暴露

## 8.5 Cloudflare 注意事项

- WebSocket: Cloudflare 免费版默认支持, 无超时限制
- HTTP 超时: 100 秒 (返回 524), 但 DSH Mobile 核心通信走 WebSocket, 不受影响
- SSL/TLS 模式: 建议 Full 或 Full (strict), 因为 nginx 有真实证书
- 不要在 Cloudflare 开启 "Always Use HTTPS" 以外的额外重写, 避免破坏 WebSocket

## 8.6 访问方式

### 手机浏览器 (推荐, Android/iPhone 通用)

```
https://dsh.spectracodeai.com/?token=<token>
```

获取 token:
```bash
sudo journalctl -u deepseek-harness -n 20 --no-pager | grep -o 'token=[A-Za-z0-9_-]*' | tail -1
```

iPhone 可以在 Safari 打开后 "添加到主屏幕", 当作 PWA 使用。

### 电脑浏览器

直接打开同样的 URL, 不再需要 SSH 隧道。

## 8.7 安全注意事项

- token 等同密码, 不要分享或截图
- 服务重启后 token 会变化
- 如果 token 泄漏, 重启服务使其失效:
  ```bash
  sudo systemctl restart deepseek-harness
  ```
- 建议在 Cloudflare 开启 Access (零信任) 增加一层认证 (可选)

## 8.8 验证

```bash
# HTTPS 无 token (应返回 401)
curl -s -o /dev/null -w "%{http_code}" https://dsh.spectracodeai.com/

# HTTPS 带 token (应返回 303)
curl -s -o /dev/null -w "%{http_code}" "https://dsh.spectracodeai.com/?token=<token>"

# DNS 应返回 Cloudflare IP (不是真实 IP)
dig +short A dsh.spectracodeai.com
```

## 8.9 故障排查

### 无法访问
1. 检查 DNS 是否指向 Cloudflare IP
2. 检查 nginx: `sudo nginx -t && sudo systemctl reload nginx`
3. 检查 DSH 服务: `sudo systemctl status deepseek-harness`
4. 检查 Cloudflare SSL 模式是否为 Full

### 524 超时
- Cloudflare HTTP 100 秒超时
- DSH 的 WebSocket 通信不受影响
- 如果 HTTP 请求超时, 检查是否可以改用 WebSocket 通道

### WebSocket 断开
- 检查 nginx 的 `proxy_read_timeout` 是否足够
- 检查 Cloudflare 是否启用了 WebSocket (默认启用)
- 检查 `proxy_buffering off` 是否生效

### 证书过期
```bash
sudo certbot renew --dry-run
```
certbot 已配置自动续期。
