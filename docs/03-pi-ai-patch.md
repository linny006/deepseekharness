# 3. pi-ai 兼容补丁

## 3.1 背景

pekpik 网关虽然自称 OpenAI 兼容, 但返回了非标准的 "content block" 格式。

非流式响应示例:
```json
{
  "message": {
    "role": "assistant",
    "content": [
      { "type": "thinking", "thinking": [{ "type": "text", "text": "..." }] },
      { "type": "text", "text": "2" }
    ]
  }
}
```

流式响应示例:
```json
{
  "choices": [
    {
      "delta": {
        "index": 0,
        "content": [
          {
            "type": "thinking",
            "thinking": [{ "type": "text", "text": "..." }]
          }
        ]
      }
    }
  ]
}
```

DSH 使用的 `@earendil-works/pi-ai` 在 `openai-completions.js` 中假定 `delta.content` 是 string:
```js
choice.delta.content.length > 0
block.text += choice.delta.content
```

当网关返回数组时, 后续协议校验失败, 最终报:
```text
text-delta text must be a string
```

## 3.2 根因定位过程

1. 用本地代理拦截 DSH 发出的请求和网关返回的流
2. 发现普通文本任务是字符串, 复杂/工具任务会出现 `content` 数组
3. 数组中元素为:
   - `{ type: "thinking", thinking: [{ type: "text", text: "..." }] }`
   - `{ type: "text", text: "..." }`
4. pi-ai 期望:
   - thinking -> `reasoning_content`
   - text -> `content`
5. 因此补丁在 pi-ai 接收到响应后做格式转换

## 3.3 补丁逻辑

在 pi-ai 的流式事件处理中, 若 `choice.delta.content` 是数组:

1. 提取所有 `type: "thinking"` 块中的 text
2. 拼接后追加到 `choice.delta.reasoning_content`
3. 提取所有 `type: "text"` 块的 text
4. 将 `choice.delta.content` 替换为拼接后的字符串
5. 后续继续走 pi-ai 原有逻辑

这样:
- thinking 进入 DSH 的 reasoning 事件
- text 进入 DSH 的 text delta 事件
- 工具调用不受影响
- 不丢弃模型思考内容

## 3.4 被修改的文件

本安装有三份 pi-ai 运行副本, 都必须打补丁:

1. Harness 主安装:
```text
/mnt/data/dsh/apps/harness/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js
```

2. Web profile:
```text
/mnt/data/dsh/home/profiles/web/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js
```

3. dsh-TUI profile:
```text
/mnt/data/dsh/home/profiles/dsh-tui/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js
```

每份原始文件备份为同目录下:
```text
openai-completions.js.orig
```

## 3.5 应用和检查补丁

应用:
```bash
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh
```

该脚本:
- 支持 `--check`
- 自动查找三份目标文件
- 已打补丁则跳过
- 未打补丁则先备份 `.orig`
- 替换前检查 needle
- 替换后运行 `node --check`
- 任一步失败立即退出

检查:
```bash
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh --check
```

重启 Web:
```bash
sudo systemctl restart deepseek-harness
```

## 3.6 为什么不修改 pekpik 网关

理想方案是让网关返回标准 OpenAI Chat Completions:
```json
{
  "delta": {
    "reasoning_content": "...",
    "content": "2"
  }
}
```

但网关不在本机:
- `aiapiv2.pekpik.com` 解析到 `168.138.221.6`
- 当前服务器出口为 `150.230.100.132`
- 本机 nginx 中没有 `aiapiv2.pekpik.com` 配置

因此当前采用 DSH 侧兼容补丁。若未来能控制网关, 应优先在网关侧修复。

## 3.7 升级时注意

任何以下操作都可能还原补丁:
- `npm install`
- `npm update`
- `pnpm install`
- `pnpm update`
- profile 插件更新
- 重装 profile
- HMR 或插件管理器重装依赖

升级后必须:
```bash
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh
sudo systemctl restart deepseek-harness
```

## 3.8 理想网关协议

非流式:
```json
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "2",
        "reasoning_content": "..."
      },
      "finish_reason": "stop"
    }
  ]
}
```

流式:
```json
data: {"choices":[{"delta":{"reasoning_content":"..."}}]}
data: {"choices":[{"delta":{"content":"2"}}]}
data: [DONE]
```

其他兼容要求:
- 不发送 `store` 字段, 或网关必须接受 `store:false`
- 使用 `max_tokens`
- `reasoning_effort` 仅支持 `none`, `low`, `high`, `xhigh`, `max`, 不支持 `medium`
