# 15. 桌面版接入 veilo 网关（pekpik 渠道）与推理强度

> 2026-11-21 新增。适用于 **macOS 桌面版 DSH**（DeepSeek Harness Desktop，
> `/Applications/DeepSeek Harness.app`，当前 0.2.2-rc.5）。
> Ubuntu Host 的同类问题走 `scripts/apply-pi-ai-patch.sh`，见 4.1 节。

## 15.1 目标

把 pekpik 渠道的 `deepseek-v4-1-flash-1017` 接进桌面版，并支持
推理强度档位切换（低/高/超高/最高），且**不影响 google / openai 等其他
provider 配置**。

## 15.2 网关事实（实测 2026-11-21）

| 项目 | 值 |
|---|---|
| 域名 | `https://codex.veilo.dev/v1` |
| 协议 | 纯 OpenAI Chat Completions（**不支持** Anthropic `/v1/messages`） |
| 模型 | 仅 `deepseek-v4-1-flash-1017`（`supported_endpoint_types: ["openai"]`） |
| API key | `PEKPIK_API_KEY`（存在 `~/.dsh/.credentials.yaml`，600 权限，**不进 git**） |
| `reasoning_effort` 支持值 | `none` / `low` / `high` / `xhigh` / `max`（**不支持 `medium`**，报 400） |

浏览器直接 GET `https://codex.veilo.dev/v1` 返回 301/404 属正常，它是
API 端点不是网页。判断可用性用 `GET /v1/models`（带 Bearer key）。

## 15.3 三个必须的 compat 开关

把 `baseURL` 指向网关后，会连续踩三个坑，都在 pekpik 路由的 `compat` 里解决：

| 现象 | 根因 | 修复 |
|---|---|---|
| HTTP 422 `openai_error` | pi-ai 默认下发 `store` 字段，网关不认 | `compat.supportsStore: false` |
| HTTP 422 `openai_error` | 推理模型下 pi-ai 默认用 `role: "developer"` 发系统提示，网关只认 `system` | `compat.supportsDeveloperRole: false` |
| 输出被截断 / 422 | 网关只认 `max_tokens`，不认 `max_completion_tokens` | `compat.maxTokensField: max_tokens` |

其中 **`supportsDeveloperRole: false` 是 422 的核心原因**：实测把角色从
`developer` 改回 `system` 后，同一请求立即 200。

## 15.4 第四个坑：推理开启后 `text-delta text must be a string`

只要 `reasoning_effort` 不是 `none`，网关返回的 assistant `content`
就是**数组**（流式和非流式都是），例如：

```json
"content": [
  {"type": "thinking", "thinking": [{"type": "text", "text": "..."}], "closed": true},
  {"type": "text", "text": "最终回答"}
]
```

而 pi-ai 的 `openai-completions` 传输层要求 `delta.content` / `message.content`
是**纯字符串**（thinking 另走 `reasoning_content` 字符串字段）。它读到数组后
把数组当成 delta 文本下发，最终报：

```text
本轮运行失败text-delta text must be a string
```

各档位实测：

| 档位 | 网关返回的 content |
|---|---|
| `none` | 字符串（安全） |
| `low` / `high` / `xhigh` / `max` | 数组（带 thinking） |

即**除 `none` 外全部会触发**。用户之前"默认 normal、切 max 才报错"，
是因为默认档恰好那几轮模型没吐 thinking；一旦命中 thinking 就会报。

### 为什么桌面版不能照搬 Ubuntu 的补丁

Ubuntu 版的 `scripts/apply-pi-ai-patch.sh` 直接改磁盘上的
`pi-ai/dist/api/openai-completions.js`。桌面版的同一文件**只存在于
`app.asar` 内部**（路径
`app.asar/dsh/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js`），
且 asar 带 SHA256 integrity 校验，改内容会被拒；升级还会覆盖。

### 方案：本地兼容代理（最小改动、不碰 asar）

用一个本地 HTTP 代理坐在桌面版和网关之间，把数组 `content`
还原成标准 OpenAI 形状（`thinking` → `reasoning_content`，`text` → `content`），
其余字节原样转发。桌面版只改 pekpik 的 `baseURL` 指向本地代理。

脚本：[`scripts/veilo-compat-proxy.py`](../scripts/veilo-compat-proxy.py)

### 15.4.1 启动代理

手动（前台，用于调试）：

```bash
python3 scripts/veilo-compat-proxy.py --port 8081 --upstream https://codex.veilo.dev -v
```

常驻（launchd，开机自启、崩溃自重启）：

```bash
cp scripts/veilo-compat-proxy.py ~/.dsh/bin/veilo-compat-proxy.py
mkdir -p ~/.dsh/logs
cp scripts/veilo-compat-proxy.plist ~/Library/LaunchAgents/com.dsh.veilo-compat-proxy.plist
launchctl load ~/Library/LaunchAgents/com.dsh.veilo-compat-proxy.plist
```

自检：

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  http://127.0.0.1:8081/v1/models -H "Authorization: Bearer $PEKPIK_API_KEY"
# 期望 200
```

### 15.4.2 桌面版配置

在 `~/.dsh/profiles/desktop/cordis.patch.yml` 的 pekpik 路由里：

```yaml
      pekpik:
        displayName: pekpik
        apiKeyEnv: PEKPIK_API_KEY
        api: openai-completions
        baseURL: http://127.0.0.1:8081/v1      # 指向本地代理，不是网关
        compat:
          supportsStore: false
          maxTokensField: max_tokens
          supportsDeveloperRole: false
        models:
          - id: deepseek-v4-1-flash-1017
            name: deepseek-v4-1-flash-1017
            contextWindow: 1048576
            inputModalities:
              - text
            reasoningEfforts:
              off: none
              low: low
              high: high
              xhigh: xhigh
              max: max
```

> 只保留网关支持的 5 档，不要写 `medium`（网关报 400）。

默认档位在 `agent-default-model`：

```yaml
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: pekpik
    model: deepseek-v4-1-flash-1017
    reasoningEffort: max   # 可在 UI 里手动改成 low/high/xhigh/none
```

改完重启桌面版（见 15.5）。

## 15.5 重启桌面版

```bash
osascript -e 'quit app "DeepSeek Harness"'; sleep 3
open -a "DeepSeek Harness"
pgrep -fl "DeepSeek Harness.app/Contents/MacOS" | head -3
```

## 15.6 验收清单

1. 代理存活：`launchctl list | grep veilo` 第二列为 `0`。
2. `curl .../v1/models` 经代理返回 200。
3. 桌面版默认档（`max`）发消息正常，不再出现 `text-delta text must be a string`。
4. 切到 `low` / `high` / `xhigh` 也正常。
5. 切到 `none` 正常（走字符串路径，代理透传）。
6. google / openai provider 不受影响。

## 15.7 排查

代理不转发 → 看日志：

```bash
tail -20 ~/.dsh/logs/veilo-compat-proxy.err.log
```

看桌面版实际请求/响应 → 用 `-v` 前台跑代理观察访问日志。

代理端口被占 → 改 `--port` 并把桌面版 `baseURL` 同步改掉。

升级桌面版后 → asar 会被覆盖，但本方案不改 asar，升级不影响；只需确认
launchd 代理仍在运行、`baseURL` 未被动过。

## 15.8 待办

- `medium` 档：网关不支持，桌面版 UI 不要暴露。
- 若日后网关支持标准 `reasoning_content` 字符串返回，可去掉本地代理，
  把 `baseURL` 直接指回 `https://codex.veilo.dev/v1`。
- 若日后桌面版 pi-ai 升级到内置处理数组 `content`，同样可去掉代理。
