# 7. 新会话快速接手

给后续维护者或 AI 助手的精简上下文。

## 必读文件

1. `AGENTS.md`
2. `docs/01-deployment-overview.md`
3. `docs/03-pi-ai-patch.md`
4. `docs/04-troubleshooting.md`

## 一句话状态

DSH 0.2.2-rc.2 + dsh-TUI 0.20.0 + dsh-mobile 0.8.8 已部署在 Ubuntu 22.04.5 aarch64, 所有数据在 `/mnt/data/dsh`, Web 服务只监听 `127.0.0.1:3080`, LLM 走 pekpik OpenAI 兼容网关, 并应用了 pi-ai thinking 数组兼容补丁。

## 必须记住的事实

- DSH 用户: `dsh`
- 数据根: `/mnt/data/dsh`
- `~/.dsh` 是软链
- Node 24 在 `dsh` 用户的 nvm 下
- 系统 Node 12 供其他生产服务使用, 不要动
- Web systemd unit: `/etc/systemd/system/deepseek-harness.service`
- Web profile: `/mnt/data/dsh/home/profiles/web`
- TUI profile: `/mnt/data/dsh/home/profiles/dsh-tui`
- headless overlay: `/mnt/data/dsh/home/overlays/pekpik.yml`
- `ds` 命令: `/home/dsh/.local/bin/ds`
- pekpik 网关返回非标准 thinking 数组
- pi-ai 补丁必须覆盖三份副本
- 凭据不在 Git, 在 `~/.dsh/.credentials.yaml` 和 `~/.dsh/.env`

## 常用命令

```bash
# 服务状态
sudo systemctl status deepseek-harness

# 登录 URL
sudo journalctl -u deepseek-harness -n 20 --no-pager |
  grep -o 'http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*' | tail -1

# 重启
sudo systemctl restart deepseek-harness

# 补丁检查
sudo -iu dsh
cd /mnt/data/deepseekharness
./scripts/apply-pi-ai-patch.sh --check

# 完整验收
./scripts/verify-deployment.sh
```

## 日常使用

```bash
sudo -iu dsh
cd /mnt/data/dsh/projects/demo
ds "任务"
```

Web UI 是最方便入口, 通过 SSH 隧道访问。

## 不要做

- 不要把 API key 或 Web token 提交到 Git
- 不要修改系统 Node 12
- 不要动 nginx、MySQL、Docker、aria2、sing-box 现有配置
- 不要把 3080、3443、3444 开公网
- 不要在未备份时升级或降级
- 不要假设 profile 是安全沙箱
- 不要给 `dsh` 用户加 sudo 或 docker 组

## 最重要的踩坑

1. Node 22 下 DSH CLI 静默退出, 必须用 Node 24
2. pekpik 不接受 `store:false`
3. pekpik 使用 `max_tokens`, 不接受 `max_completion_tokens`
4. pekpik `reasoning_effort` 不支持 `medium`
5. pekpik 把 thinking 塞进 `content` 数组, pi-ai 期望 string
6. dsh-TUI 0.20.0 的 headless CLI 白名单不含 0.2.2-rc.2, 但 Web/TUI 正常
7. Web profile 有独立 node_modules, 补丁只打主安装不够
