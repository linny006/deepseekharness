# 13. Gemini 模型接入与"拉不到最新模型"根因

> 2026-11-19 新增。适用于 Mac Host（DSH 0.2.2-rc.5），Ubuntu Host 同理。

## 13.1 现象

在 Web UI 的 Models 页面配置了 `google` 路由、填了 Google API key，
但模型列表里只看到 pi-ai 打包时内置的那批 Gemini 型号，
Google 后续新出的模型（如 `gemini-4-neon`、`gemini-4-carbon`、
`gemini-4-hydrogen`）不出现，"刷新"也没有用。

## 13.2 根因

DSH 的 LLM 适配层 `@deepseek-ai/dsh-llm-pi-ai` 在做模型发现
（`discoverModels`）时，第一段逻辑是：

> 如果该 provider 在 pi-ai 内置 catalog 里有条目，直接返回内置列表，
> **完全不联网请求 Google 的 `/v1beta/models` 接口**。

内置 catalog 是 pi-ai 发布时用 `catalog/generate.ts` 生成的 JSON 快照
（`node_modules/@earendil-works/pi-ai/dist/providers/data/google.json`），
打包后固定不变。Google 侧新增模型不会自动出现在快照里，所以界面永远看不到。

`resolveRouteModels` 的合并语义也决定了修复方式：

> 一旦在 provider 路由上写了 `models:` 列表，它就**完全替换**内置
> catalog，不是追加。所以要让新模型出现，必须在 `models:` 里把要用的
> 模型全部列出来。

## 13.3 第二个坑：route 级 `reasoning` 字段

Google 的 Gemini 模型在内置 catalog 里只标了 `reasoning: true`（布尔），
没有像 pekpik 那样配 `reasoningEfforts` 档位映射。如果在 google 路由上写
`reasoning: high`（字符串），pi-ai 会把它当作 reasoning effort 下发给模型，
对没有声明 effort 档位的模型直接报：

```
UNSUPPORTED_REASONING_EFFORT: pi-ai provider "google" model "gemini-4-neon"
does not support reasoning effort "high"
```

正确做法是 **google 路由上不要写 `reasoning` 字段**，让每个模型继承内置
catalog 的 `reasoning: true`；pi-ai 会按模型自身能力处理 thinking。

## 13.4 正确配置

在 `~/.dsh/profiles/web/cordis.patch.yml`（以及 TUI、overlays 同名文件）
的 `llm-pi-ai` 插件 `providers` 下写：

```yaml
google:
  displayName: Google Gemini
  apiKeyEnv: GOOGLE_API_KEY
  api: google-generative-ai
  baseURL: https://generativelanguage.googleapis.com/v1beta
  models:
    - id: gemini-4-argon
      name: Gemini 4 Argon
      contextWindow: 1048576
      maxTokens: 32768
    - id: gemini-4-neon
      name: Gemini 4 Neon
      contextWindow: 1048576
      maxTokens: 65536
    - id: gemini-4-carbon
      name: Gemini 4 Carbon
      contextWindow: 1048576
      maxTokens: 32768
    - id: gemini-4-hydrogen
      name: Gemini 4 Hydrogen
      contextWindow: 1048576
      maxTokens: 65536
    # ... 其余内建 chat 模型按需列出
```

要点：

- `apiKeyEnv: GOOGLE_API_KEY` 是凭据引用名，不是环境变量名本身。
  DSH 会先查 credentials 存储（Web Models 页面写入的 key 就存在这里），
  再查 `~/.dsh/.env`。两者任一有 `GOOGLE_API_KEY` 即可。
- `api` 和 `baseURL` 必须写，因为 `models:` 列表会替换内置 catalog，
  列表里的模型不再从内置 provider 定义继承 baseUrl/api。
- 不要写 route 级 `reasoning`。
- `contextWindow` / `maxTokens` 可从 Google API 的
  `GET /v1beta/models/<id>` 取 `inputTokenLimit` / `outputTokenLimit`。

## 13.5 凭据存放位置

`GOOGLE_API_KEY` 有两个生效位置，任选其一：

1. **Web Models 页面**（推荐）：在 DSH Web UI 的 Models → Google 路由里
   填 key，写入 `~/.dsh/.credentials.yaml` 的 `refs` 段。当前已存在，
   前缀 `AIza`，长度 39。
2. **`~/.dsh/.env`**：加一行 `GOOGLE_API_KEY=AIza...`，权限 600。
   适合 headless / 命令行场景。

注意：pi-ai 内置 `google` provider 的默认 env var 名是 `GEMINI_API_KEY`，
但 DSH 的 `apiKeyEnv` 机制是按**引用名**解析，与 pi-ai 内置名无关。只要
`apiKeyEnv` 和凭据存储/`.env` 里的名字一致即可。本部署统一用
`GOOGLE_API_KEY`。

## 13.6 验证

配置写完重启 Web 后，可用 headless 模式做端到端调用验证：

```bash
export PATH="$HOME/.nvm/versions/node/v24.22.3/bin:$PATH"
export GOOGLE_API_KEY="<your key>"
cd ~/apps/harness
cat > /tmp/gemini-test.yml <<'EOF'
- id: llm-pi-ai
  config:
    providers:
      google:
        apiKeyEnv: GOOGLE_API_KEY
        api: google-generative-ai
        baseURL: https://generativelanguage.googleapis.com/v1beta
        models:
          - id: gemini-4-neon
            name: Gemini 4 Neon
            contextWindow: 1048576
            maxTokens: 65536
- id: agent-default-model
  config:
    provider: google
    model: gemini-4-neon
EOF
node node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless \
  --patch /tmp/gemini-test.yml headless --approval-policy never \
  "Reply with exactly: GEMINI_OK"
# 期望输出: GEMINI_OK
```

也可用裸 curl 直接测某个模型是否可调用：

```bash
curl -s -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-neon:generateContent" \
  -H "x-goog-api-key: $GOOGLE_API_KEY" -H "content-type: application/json" \
  -d '{"contents":[{"parts":[{"text":"say ok"}]}]}'
```

## 13.7 哪些 Google 模型不要加进列表

Google API 的 `/models` 列表里有些模型不适合作为对话模型，已验证排除：

| 模型 | 原因 |
|---|---|
| `gemini-omni-1.1-flash` / `1.2-flash` / `flash-preview` | 只支持 Interactions API，`generateContent` 返回 400 |
| `*-tts` / `*-transcribe` | 语音合成/转录，非对话 |
| `lyria-*` | 音乐生成 |
| `antigravity-*` | Agent 专用 |
| `*-image` / `nano-banana-*` | 图像生成 |

## 13.8 后续 Google 新增模型怎么办

pi-ai 内置 catalog 不会自动更新。Google 出了新模型后：

1. 用 `curl /v1beta/models?pageSize=1000` 拿到完整列表。
2. 用 `generateContent` 测一遍新模型是否可调用（排除 Interactions-only）。
3. 把可调用的加进 `models:` 列表，写上 `contextWindow` / `maxTokens`。
4. 重启 Web。

升级 pi-ai 版本时，内置 catalog 可能会补充新模型，届时可酌情精简
`models:` 列表（不写则用内置全量）。
