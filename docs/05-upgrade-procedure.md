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
- dsh-mobile peerDependencies
- pi-ai 补丁是否仍适用

查询:
```bash
npm view @deepseek-ai/dsh versions --json
npm view @deepseek-harness-tui/dsh-tui@<version> peerDependencies --json
npm view dsh-mobile@<version> peerDependencies --json
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

## 5.5 升级 Mobile

```bash
sudo -iu dsh
dsh plugin --profile web add dsh-mobile@<version>
```

如需同步 TUI profile:
```bash
dsh plugin --profile dsh-tui add <package>@<version>
```

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
- [ ] Mobile 插件仍加载
