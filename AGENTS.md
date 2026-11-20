# AGENTS.md — DeepSeek Harness 部署仓库

本仓库记录 DSH（DeepSeek Harness）在本机的部署、配置、补丁与维护流程。

## 环境
- 主机: Ubuntu 22.04.5 LTS, aarch64, 4 核, 23 GB RAM
- 数据盘: /mnt/data (独立 ext4 挂载, noatime,_netdev,nofail)
- DSH 运行用户: dsh (uid 1002, 无 sudo, 已加入 docker 组)
- Node.js: v24.22.3 (通过 nvm 安装在 dsh 用户下; 系统 /usr/bin/node 为 v12, 不可动)
- 共存服务: nginx (多域名), MySQL, Docker, aria2, sing-box — 本部署不得触碰

## 版本组合
- DSH core: @deepseek-ai/dsh@0.2.2-rc.5
- TUI: @deepseek-harness-tui/dsh-tui@0.20.1
- Remote: ds-harness-remote@0.6.5 + 自建 Relay Server
- LLM 网关: pekpik (OpenAI 兼容, https://aiapiv2.pekpik.com/v1)

## 关键约束
- 所有 DSH 数据在数据盘: /mnt/data/dsh/{home,apps,projects,backups}
- dsh 家目录的 .dsh, apps, projects 是指向数据盘的软链
- Web 服务只监听 127.0.0.1:3080, 不暴露公网
- 远程 Relay 只监听 127.0.0.1:8080, 公网只通过 Cloudflare -> nginx 443 转发
- 凭据 (API key) 存在 ~/.dsh/.credentials.yaml 和 ~/.dsh/.env, 权限 600, 不进 git
- pekpik 网关返回非标准 thinking 数组, 需要 pi-ai 兼容补丁 (见 docs/03-pi-ai-patch.md)

## 维护入口
- 部署总览: docs/01-deployment-overview.md
- 操作手册: docs/02-operations-manual.md
- 补丁详情: docs/03-pi-ai-patch.md
- 故障排查: docs/04-troubleshooting.md
- 手机远程访问: docs/08-mobile-remote-access.md
- 升级流程: docs/05-upgrade-procedure.md
- 安全审计: docs/06-security-audit.md
- 外部项目接入: docs/09-external-projects-onboarding.md
- 新机器部署: docs/10-new-machine-install.md
- Gemini 模型接入: docs/13-gemini-provider-config.md
- Web 端控制 Mac (Computer Use): docs/14-web-computer-use.md
- 性能审计与配置修正: docs/11-performance-audit-2026-11.md
- macOS Host 部署与使用: docs/12-macos-host-install.md
- 补丁脚本: scripts/apply-pi-ai-patch.sh
- macOS pi-ai 补丁: scripts/apply-pi-ai-patch-macos.sh
- 验收测试: scripts/verify-deployment.sh
