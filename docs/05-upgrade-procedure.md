# 5. 升级流程

## 5.1 升级前

1. 停止正在运行的 Agent 任务
2. 确认没有重要未提交代码
3. 备份:
```bash
sudo -iu dsh
/mnt/data/dsh/bin/dsh-backup.sh
```

4. 记录当前版本:
```bash
sudo -iu dsh
dsh -V
dsh-tui version
node -v
pnpm -v
```

5. 检查服务:
```bash
sudo systemctl status deepseek-harness
```

## 5.2 选择版本

升级前必须核对:
- DSH core 版本
- dsh-TUI peerDependencies
- ds-harness-remote 与 DSH Web、Android App、Relay Server 的兼容性
- dsh-mobile peerDependencies（旧插件暂保留）
- pi-ai 补丁是否仍适用

查询:
```bash
npm view @deepseek-ai/dsh versions --json
npm view @deepseek-harness-tui/dsh-tui@<version> peerDependencies --json
npm view dsh-mobile@<version> peerDependencies --json
npm view ds-harness-remote@<version> peerDependencies --json
```

不要使用 `latest` 直接升级。

## 5.3 升级 Harness

```bash
sudo -iu dsh
cd ~/apps/harness
npm install --save-exact @deepseek-ai/dsh@<version>
```

## 5.4 升级 TUI

```bash
sudo -iu dsh
cd ~/apps/dsh-tui
npm install --save-exact @deepseek-harness-tui/dsh-tui@<version>
```

## 5.5 升级 Remote 插件

```bash
sudo -iu dsh
dsh plugin --profile web add ds-harness-remote@<version>
```

当前 Android App 和自建 Relay Server 使用 0.6.4。升级前必须确认三端版本兼容，并先备份 Relay volume。

## 5.6 重新应用 pi-ai 补丁

所有依赖安装/更新后必须执行:
```bash
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh
```

如果目标文件结构变化导致脚本失败:
1. 不要强行修改
2. 打开:
```text
node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js
```
3. 查找 `choice.delta.content`
4. 将数组转 string 的逻辑重新适配到新结构
5. 更新补丁脚本和本文档

## 5.7 重启与验证

```bash
sudo systemctl daemon-reload
sudo systemctl restart deepseek-harness
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/verify-deployment.sh
```

## 5.8 回滚

如果升级失败:
1. 停止服务
2. 恢复备份中的 `/mnt/data/dsh/apps`
3. 恢复 profile
4. 重新应用补丁
5. 重启服务

版本降级可能影响会话格式。恢复数据前必须备份当前状态。

## 5.9 升级检查清单

- [ ] dsh -V 正确
- [ ] node >= 24.9
- [ ] Web 服务 active
- [ ] 只监听 127.0.0.1:3080
- [ ] Web 无 401/token 正常
- [ ] pi-ai 三份副本均 PATCHED
- [ ] headless 简单文本任务成功
- [ ] headless 工具任务能创建并运行文件
- [ ] TUI 可启动
- [ ] Relay 容器 healthy
- [ ] `ds-harness-remote` 插件仍加载
- [ ] 手机可以登录并连接 Host `aiapp`

## 5.10 实际升级记录：0.2.2-rc.2 → 0.2.2-rc.5（2026-11-19）

### 升级步骤

```bash
# 1. 备份
sudo -iu dsh
/mnt/data/dsh/bin/dsh-backup.sh

# 2. 升级 DSH 核心
cd /mnt/data/dsh/apps/harness
npm install --save-exact @deepseek-ai/dsh@0.2.2-rc.5

# 3. npm 11 拦截 install scripts，需批准
npm install-scripts approve @deepseek-ai/dsh-subprocess-local node-pty
npm install

# 4. 升级 web profile 的 pi-ai 插件（否则被判定不兼容而禁用）
dsh plugin --profile web add @deepseek-ai/dsh-llm-pi-ai@0.2.2-rc.5

# 5. 重新应用 pi-ai 补丁
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh

# 6. 重启
sudo systemctl restart deepseek-harness
```

### 踩坑记录

1. **pi-ai 插件版本不匹配**：升级 DSH core 后，web profile 里的 `dsh-llm-pi-ai@0.2.2-rc.2` 被 rc.5 判定不兼容并禁用，日志显示 `disabling profile plugin row "llm-pi-ai"`。必须用 `dsh plugin --profile web add @deepseek-ai/dsh-llm-pi-ai@0.2.2-rc.5` 同步升级。

2. **npm 11 install-scripts 拦截**：`@deepseek-ai/dsh-subprocess-local` 和 `node-pty` 的 postinstall/install 脚本被 npm 11 默认拦截。需 `npm install-scripts approve` 批准后重装。

3. **pnpm store 路径**：`dsh plugin` 用 pnpm 安装，如果 store 路径不一致会报 `ERR_PNPM_UNEXPECTED_STORE`。修复：`pnpm config set store-dir /mnt/data/dsh/.pnpm-store/v10 --global`。

4. **Google/OpenAI key 未进进程环境**：UI 配的 key 存在 `.credentials.yaml` 的 refs 里，但 systemd 的 `EnvironmentFile` 只读 `.env`。需把 key 同步写入 `.env`，否则 provider 被判定不可用，Gemini 模型列表不完整。

### 凭据同步方法

当 UI 新增 provider key 后，需同步到 `.env`：

```bash
sudo -iu dsh
# 从 .credentials.yaml refs 读取，写入 .env
python3 - <<'PY'
import yaml, os
with open('/mnt/data/dsh/home/.credentials.yaml', encoding='utf-8') as f:
    refs = (yaml.safe_load(f) or {}).get('refs') or {}
lines = []
with open('/mnt/data/dsh/home/.env', encoding='utf-8') as f:
    for line in f:
        key = line.split('=', 1)[0].strip() if '=' in line else None
        if key not in ('GOOGLE_API_KEY', 'OPENAI_API_KEY', 'PEKPIK_API_KEY'):
            lines.append(line)
for key in ('PEKPIK_API_KEY', 'GOOGLE_API_KEY', 'OPENAI_API_KEY'):
    if refs.get(key):
        lines.append(f'{key}={refs[key]}\n')
with open('/mnt/data/dsh/home/.env', 'w', encoding='utf-8') as f:
    f.writelines(lines)
os.chmod('/mnt/data/dsh/home/.env', 0o600)
PY
sudo systemctl restart deepseek-harness
```

### 升级后验证

```bash
# 版本
dsh -V  # 应为 0.2.2-rc.5

# pi-ai 未被禁用（日志无 disabling）
sudo journalctl -u deepseek-harness -n 30 --no-pager | grep disabling || echo 'OK'

# 进程环境有所有 key
sudo sh -c 'tr "\0" "\n" < /proc/$(systemctl show deepseek-harness -p MainPID --value)/environ | grep -cE "GOOGLE_API_KEY|OPENAI_API_KEY|PEKPIK_API_KEY"'
# 应输出 3

# 完整验收
./scripts/verify-deployment.sh
```
