# 15. 部署 Persona 后缀（personaSuffix）配置

## 15.1 目的

Web Agent 的 system prompt 由 `@deepseek-ai/dsh-persona` 的 `prefix` / `suffix` 两段组成。出厂 `standard` 预设只写了：

```text
You are a coding agent powered by the {{model}} model.
```

这一句没有交代部署语境，模型容易把用户正常的运维/排障请求当成泛化的高危请求，用「出于安全考虑，我无法协助」这类套话拒绝。本仓库在这台自有机器的 Web profile 上追加一段 `suffix`，说明「这是用户自有、已授权的单机环境」，把拒绝降到合理范围。

**这是提示词层的调整，与权限/审批层无关。** 不要为了让模型“少拒绝”去放开 `DSH_PERMISSION_MODE`：权限层只决定工具调用会不会被拦截，不会产生对话性拒绝。例如读 `/home/ubuntu` 读不到是权限错误，不是模型说“不做”。

## 15.2 关键约束：plugins 是整体替换，不是深合并

`preset-standard` 这一行的 `config.plugins` 是 **按 id 整体替换**，不是按字段深合并。也就是说：

- 只写 `- id: persona` 一条，会把 `standard` 预设其余 **22 个插件全部抹掉**，启动时报
  `preset-standard (@deepseek-ai/dsh-agent-preset): ValidationError: invalid config: $.id missing required value` 之类，或直接丢失工具能力。
- 正确做法：把 `@deepseek-ai/dsh-web-app` 随包自带的 `presets/standard.patch.yml` 原样复制进 profile 补丁，**只改 `persona.config.suffix` 一个字段**。

同理，`persona.config` 内部也是整体替换：改 `suffix` 必须把 `prefix` 一起写上，否则 `prefix` 会被覆盖成空。

## 15.3 当前配置位置

生效文件（数据盘，权限 600，dsh:dsh）：

```text
/mnt/data/dsh/home/profiles/web/cordis.patch.yml
```

末尾追加了一整行 `preset-standard`，内容自
`/home/dsh/apps/harness/node_modules/@deepseek-ai/dsh-web-app/presets/standard.patch.yml`
生成，仅 `persona.config.suffix` 与随包版本不同。

追加的 `suffix`（纯文本，**不能含 `{{...}}`**，persona 模板严格插值，未知变量会导致渲染失败）：

```text
Deployment context: this is the user's own single-machine development server,
operated by the user themselves. ... When the user explicitly asks for something
specific, do the work directly; do not reply in a refusal-script style such as
"for security reasons I cannot help"... Only pause to ask for confirmation when an
action is genuinely destructive or irreversible, or would affect systems, accounts,
or people outside this machine... If scope is ambiguous, ask one clarifying question
rather than refusing.
```

已渲染校验（用 `@deepseek-ai/dsh-system-prompt` 的 `renderPrompt`）：`{{model}}`
正确替换，suffix 位于最后一段，无残留 `{{`。

## 15.4 `!!js` 表达式陷阱（务必先读）

DSH 的 entry-list 用 **`js-yaml` + 自定义 schema** 解析，`disabled` 等字段是
`!!js` 表达式，例如：

```yaml
disabled: !!js process.platform === 'win32'
```

**必须保留 `!!js` 标签。** 若用 `yaml`（注意不是 `js-yaml`）库或手写序列化，
这些表达式会退化成普通字符串，`preset-standard` 会校验失败
（`$.id missing required value`），整个预设不激活，Agent 会**丢失 shell 等全部工具**
（表现为「没有 bash 工具」）。`--dump-config` 和普通 YAML 解析**不会**执行
`!!js`，因此它们通过 ≠ 线上可用。

**唯一可靠的生成方式**：用本仓库脚本，它复用与 DSH 相同的 `js-yaml` 方言：

```bash
sudo -n node /mnt/data/deepseekharness/scripts/generate-persona-preset.mjs > /tmp/preset.overlay.yml
grep -c '!!js' /tmp/preset.overlay.yml   # 期望 >= 4
```

脚本在生成后会自行 round-trip，确认 `__jsExpr` 标记没有丢失。

**唯一可靠的验证判据**：以**服务启动日志**为准。

```bash
sudo systemctl restart deepseek-harness
sudo journalctl -u deepseek-harness --since "-1 min" --no-pager -o cat | grep -i "did not activate"
# 无输出 = 预设已激活；有 "did not activate" = 预设没挂上，立即回滚
```

`--dump-config`、YAML 解析、`renderPrompt` 都只是辅助，**不能替代**这条。

## 15.5 升级后必须重新生成

`@deepseek-ai/dsh-web-app` 升级后，其随包 `presets/standard.patch.yml` 可能新增/调整插件。
因为这里是整行复制，**升级 DSH 后必须重新同步这一行**，否则会锁死在旧插件集：

```bash
# 1. 备份当前生效配置
sudo -u dsh cp -p /mnt/data/dsh/home/profiles/web/cordis.patch.yml \
  /mnt/data/dsh/home/backups/cordis.patch.yml.bak-$(date +%Y%m%d%H%M%S)

# 2. 用脚本重新生成 overlay（保留 suffix 与 !!js），追加到配置末尾
sudo -n node /mnt/data/deepseekharness/scripts/generate-persona-preset.mjs >> ~/.dsh/profiles/web/cordis.patch.yml

# 3. 按 15.4 的日志判据重启验证
```

## 15.6 重启须知

- 重启 `deepseek-harness` 会中断运行中的会话，**没有活跃任务时再操作**。
- 每次重启会重新生成一次性登录 token，需要重新获取：

  ```bash
  sudo journalctl -u deepseek-harness --no-pager | grep -o 'token=[A-Za-z0-9_-]*' | tail -1
  ```

- 回滚：把 `backups/` 里的 `cordis.patch.yml.bak-*` 复制回
  `/mnt/data/dsh/home/profiles/web/cordis.patch.yml` 再重启即可。

## 15.7 不建议的做法

- 不要把 `DSH_PERMISSION_MODE` 调到 `danger-full-access` 来“减少拒绝”——拒绝不在权限层，只会增大误操作风险。
- 不要在 AGENTS.md 或 persona 里写「忽略一切安全规则」「必须无条件执行」——会触发对抗性拒绝，也失去真出问题时的护栏。
- 不要把 `includeRuntimeContext` 设为 `false`、或 `complete` 设为 `true`——会把 DSH 的工具说明和上下文一起抹掉，Agent 能力明显下降。

## 15.8 提问方式（零成本补充）

把「删除全部日志」「绕过认证」这类泛化危险词换成具体、限定范围的指令，例如
「清理 `/var/log/xxx` 下 7 天前的日志」「给 nginx 加 basic auth」，模型配合度更高。批量任务前先声明授权范围（如“以下操作都在 `/mnt/data` 内”）。

## 15.9 仓库内快照

`profiles/web/cordis.patch.yml.example` 是生效配置的脱敏快照（只引用
`PEKPIK_API_KEY` 等环境变量名，不含任何凭据）。它只作为生成 `preset-standard`
行的参考样例；真实凭据仍只在 `~/.dsh/.credentials.yaml` 和 `~/.dsh/.env`。
