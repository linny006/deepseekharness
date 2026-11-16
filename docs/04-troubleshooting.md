# 4. 故障排查

## 4.1 `text-delta text must be a string`

### 原因
pekpik 网关把 thinking 放进 `delta.content` 数组, pi-ai 期望 string。

### 处理
```bash
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh
sudo systemctl restart deepseek-harness
```

验证:
```bash
cd /mnt/data/dsh/projects/demo
ds "创建 test.js 打印 123, 然后运行"
```

或在 Web UI 重新发送任务。

### 注意
如果重启后又失败, 检查是否 Web profile 的 pi-ai 文件未打补丁:
```bash
sudo -iu dsh
grep -n "Array.isArray(choice.delta.content)" \
  ~/.dsh/profiles/web/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js
```

没有输出则重新应用补丁。

## 4.2 `MISSING_CREDENTIAL`

现象:
```text
MISSING_CREDENTIAL: llm-pi-ai: no credential for provider route "pekpik"; its profile resolves PEKPIK_API_KEY
```

检查:
```bash
sudo -iu dsh
grep -n "PEKPIK_API_KEY" ~/.dsh/.credentials.yaml
stat -c "%A %U:%G %n" ~/.dsh/.credentials.yaml ~/.dsh/.env
```

期望:
- `refs` 中存在 `PEKPIK_API_KEY`
- 文件权限 `600`
- 属主 `dsh:dsh`

headless profile 的 credentials 服务是 disabled, 因此 `ds` 脚本会 source `~/.dsh/.env`。

## 4.3 HTTP 422 / `openai_error`

常见触发字段:
- `store:false`
- `reasoning_effort:"medium"`
- `thinkingFormat: deepseek`

当前 profile 配置已规避:
- `compat.supportsStore: false`
- `compat.maxTokensField: max_tokens`
- `reasoningEfforts` 映射:
  - off -> none
  - low -> low
  - medium -> high
  - high -> high
  - xhigh -> xhigh
  - max -> max

如果出现 422, 检查这些字段是否被 UI 或配置覆盖。

## 4.4 Web 401

原因:
- token 过期或错误
- 服务已重启, 旧 token 失效

获取新 URL:
```bash
sudo journalctl -u deepseek-harness --no-pager | grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*' | tail -1
```

## 4.5 Web 无法访问

检查服务:
```bash
sudo systemctl status deepseek-harness
```

检查监听:
```bash
sudo ss -lntp | grep 3080
```

期望:
```text
127.0.0.1:3080
```

如果你在本地电脑访问:
- 必须先开 SSH 隧道
- 隧道命令在本地电脑执行, 不是服务器执行

## 4.6 `ADAPTER_UNAVAILABLE`

如果运行:
```bash
dst run "..."
```

可能遇到:
```text
This adapter validates DSH 0.2.0-rc.2, 0.2.1-rc.2, ...; use dst dsh for another runtime
```

原因:
- dsh-TUI 0.20.0 的 headless CLI adapter 白名单硬编码到 `0.2.1-rc.5`
- 未包含 `0.2.2-rc.2`

处理:
- 使用官方 headless:
```bash
dsh --profile headless --patch ~/.dsh/overlays/pekpik.yml "任务"
```
- 或使用包装脚本:
```bash
ds "任务"
```

## 4.7 CLI 卡住或无输出

- `dsh --profile dsh-tui ...` 是交互式 TUI, 不适合非交互脚本
- 非交互任务应使用 headless 或 `ds`
- 超时可加 `timeout`

## 4.8 会话恢复失败

检查 session id:
```bash
sudo -iu dsh
ls -lt ~/.dsh/sessions | head
```

确认 cwd 一致。headless 恢复要求当前目录与会话记录的工作目录一致。

## 4.9 服务启动失败

```bash
sudo systemctl status deepseek-harness
sudo journalctl -u deepseek-harness -n 100 --no-pager
```

常见检查:
- `/mnt/data` 是否挂载
- `/home/dsh/.dsh` 软链是否有效
- `/mnt/data/dsh/home/.env` 是否存在且权限 600
- Node 24 路径是否正确

## 4.10 Docker socket 风险

本机存在既有问题:
```text
/var/run/docker.sock 权限 666
```

`dsh` 用户可通过 docker 提权到 root。此问题早于本部署存在。

当前部署未修改该配置。如需修复, 需评估对现有生产容器和运维流程的影响。

## 4.11 SSH 公钥认证被拒绝（StrictModes）

现象：其他服务器连本机报公钥错误，`auth.log` 显示：

```text
Authentication refused: bad ownership or modes for directory /home/ubuntu
```

根因：`/home/ubuntu` 被改成组/其他可写（如 `ubuntu:dsh` + `2770`）。

修复：

```bash
sudo chown ubuntu:ubuntu /home/ubuntu
sudo chmod 0755 /home/ubuntu
sudo chmod 0700 /home/ubuntu/.ssh
sudo chmod 0600 /home/ubuntu/.ssh/authorized_keys
sudo sshd -t
```

修复后从其他机器重新测试连接。该问题会让所有 SSH 登录失效，务必避免再次改动家目录权限。
