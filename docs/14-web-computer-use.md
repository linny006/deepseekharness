# 14 · Web 端控制 Mac(Computer Use)

> 文档记录如何在 DSH Web 版上开启 Computer Use,让 AI Agent 直接操作这台 Mac 的桌面应用。

## 14.1 能力概述

DSH 的 cua(Computer Use Agent)能力让 AI Agent 在 PTC 会话中获得一组工具,直接操作运行 DSH 的这台 Mac:

| 能力 | 工具 | 说明 |
|---|---|---|
| 看屏幕 | `getScreenshot` | 截取指定窗口 |
| 读 UI 树 | `getAccessibilityTree` | 读取当前辅助功能树(语义结构) |
| 找应用 | `listApps`、`findApps`、`getApp` | 列出运行中/已安装的应用,按名称/Bundle ID/路径选择 |
| 激活应用 | `activate`、`show` | 激活应用、显示/取消隐藏窗口 |
| 查状态 | `getState`、`getCapabilities` | 查当前运行状态、权限和锁屏状态 |
| 鼠标 | `click`、`mouseMove`、`drag`、`scroll` | 点击、移动、拖拽(按住拖动)、滚动 |
| 键盘 | `typeText`、`pressKey`、`sendKeyEvent`、`paste` | 输入文本、按键、粘贴 |
| 元素操作 | `invoke`、`listActions` | 执行元素的内置 action |

本质上:Agent 像人一样看屏幕、点按钮、打字。打开某个 App、在输入框填内容、点按钮、滚动列表、截图确认——都能做。

## 14.2 前提条件(三个串联,缺一不可)

1. **cua 组合包已选中** — bundle 加到 profile 的 bundles 列表
2. **系统权限已授予** — `DSH Computer Use.app` 拿到辅助功能 + 屏幕录制权限
3. **会话是 PTC preset** — cua 工具只在 PTC 会话注册,普通会话拿不到

## 14.3 开启方式

### 路线 A:Web 界面操作(官方推荐)

1. 用浏览器打开 Web 界面(本机 `http://127.0.0.1:3080/?token=...`)
2. 左侧进入 **Plugins(插件)** 面板
3. 点击 **More(更多)** 进入实验性插件列表
4. 找到 **Computer Use** 开关,打开它
5. 打开后组合包出现在插件主列表中,关闭后只留在实验性列表
6. 进入详情页,按需点击"设为 PTC"设置新会话默认模式

开关状态写入 `~/.dsh/profiles/web/package.json` 的 `dsh.profile.bundles` 字段。

### 路线 B:直接编辑配置文件

编辑 `~/.dsh/profiles/web/package.json`,在 `dsh.profile.bundles` 数组中加入 `"@deepseek-ai/dsh-cua-bundle"`:

```json
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {
    "ds-harness-remote": "0.6.4"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "ds-harness-remote",
        "@deepseek-ai/dsh-cua-bundle"
      ]
    }
  }
}
```

保存后重启 Web:

```sh
launchctl kickstart -k gui/$(id -u)/com.deepseek.harness.web
```

两条路线等价,都是往 bundles 列表加一个字符串。A 多了界面引导和权限设置入口。

## 14.4 授予系统权限

开启 cua 后需要给 `DSH Computer Use.app` 授两个权限。这个只能用户在系统设置里手动做,Agent 改不了 TCC 权限。

helper app 路径(本机 Apple Silicon):

```
~/apps/harness/node_modules/@deepseek-ai/dsh-experimental-cua-macos/native/bin/darwin-arm64/<hash>/DSH Computer Use.app
```

步骤:

1. **系统设置 → 隐私与安全性 → 辅助功能** — 添加 `DSH Computer Use.app` 并打钩
2. **系统设置 → 隐私与安全性 → 屏幕录制** — 添加 `DSH Computer Use.app` 并打钩

首次操作时 cua 会自动弹出原生悬浮引导框,拖入应用并开启开关即可。如果没弹,手动到设置页添加。

> 在 Computer Use 详情页(插件 → Computer Use → 详情)可以查看权限状态,有"前往设置"按钮。远程访问时,需要在运行 DSH 的电脑上完成授权,不能远程代授。

## 14.5 设置 PTC 会话

cua 工具只在 `agentPreset: ptc` 的会话中注册。两种方式:

- **新会话默认设为 PTC**:插件详情页点击"设为 PTC"按钮,写入 `agent-preset-registry.selectedDefault: ptc`
- **单次会话手动切换**:在会话中手动把 preset 改成 PTC

当前 profile 默认模型是 `google / gemini-4-carbon`。如果要配合 cua 使用,需要确保会话用的 preset 是 PTC。

## 14.6 验证

开启后执行验证:

```sh
# 1. dump-config 应出现 cua 相关条目
cd ~/apps/harness
node node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --dump-config 2>/dev/null | grep cua
# 期望输出: cua-provider-registry、cua、ui-cua 三个条目

# 2. 跑验收脚本
bash scripts/verify-deployment-macos.sh
# 期望: 20 项全通过

# 3. 重启 Web
launchctl kickstart -k gui/$(id -u)/com.deepseek.harness.web

# 4. 获取 Web URL
grep -o 'token=[A-Za-z0-9_-]*' ~/dsh/backups/web.out.log | tail -1
```

## 14.7 cua 组合包挂载定义

`@deepseek-ai/dsh-cua-bundle/cordis.patch.yml` 挂载三个组件:

```yaml
- insert:
    - id: cua-provider-registry       # provider 注册表
      name: '@deepseek-ai/dsh-computer-use'
    - id: cua                          # macOS 原生 provider
      name: '@deepseek-ai/dsh-experimental-cua-macos'
      disabled: !!js process.platform !== 'darwin'  # 非 macOS 自动禁用
      config:
        agentPreset: ptc
    - id: ui-cua                       # 权限页面和 UI 贡献
      name: '@deepseek-ai/dsh-cua'
```

## 14.8 配置字段参考

cua-macos provider 的常用配置(在 profile 的 `cordis.patch.yml` 中 `cua` 节点下设置):

| 字段 | 默认值 | 说明 |
|---|---|---|
| `agentPreset` | `ptc` | 仅绑定该 preset 的 Agent 注册工具;`false` 全局注册 |
| `timeoutMs` | `30000` | 单次操作超时 |
| `axTimeoutMs` | `3000` | 单次 Accessibility 系统调用超时 |
| `maxElements` | `5000` | 读辅助功能树的元素上限 |
| `maxDepth` | `50` | 读 UI 树深度上限 |
| `maxClickHoldMs` | `5000` | 点击按住时长上限 |
| `requireSystemPointerApproval` | `true` | 首次移动系统指针需确认 |
| `screenshotTimeoutMs` | `5000` | 截图超时(含排队) |
| `connectTimeoutMs` | `5000` | 连接/启动 helper 超时 |

完整字段见 `~/apps/harness/node_modules/@deepseek-ai/dsh-experimental-cua-macos/README.zh.md`。

## 14.9 应用授权机制

- 每个应用首次操作时单独弹授权卡(带 Risks 标签)
- 授权记在 `~/.dsh/storages/cua_permissions_<sha256(profile)>.json`
- 按"会话+应用"粒度持久化,跨 turn、连接、DSH 重启、cua 开停保留
- 只在原对话里生效,其他对话需单独授权
- 可以在 Computer Use 详情页撤销授权

## 14.10 使用限制

- **锁屏失效**:屏幕锁定时观察/输入被拒绝,需解锁后继续
- **macOS 14+ 要求**:低于 macOS 14 不支持
- **后台操作**:默认不抢前台焦点,需要前台时 Agent 先 `activate`
- **非录制回放**:每次操作都是模型实时决策,不是脚本回放
- **单机操作**:只操作运行 DSH 的这台 Mac,不能跨设备
- **键盘输入节奏**:`textEventIntervalMs` 默认 0.25ms,可调
- **拖拽行为**:`dragDurationMs=400ms` / `dragSteps=20`,可调

## 14.11 包版本

| 包 | 版本 | 说明 |
|---|---|---|
| `@deepseek-ai/dsh-cua-bundle` | 0.2.2-rc.5 | 组合包入口 |
| `@deepseek-ai/dsh-cua` | 0.2.2-rc.5 | 共享 cua API 和权限 UI |
| `@deepseek-ai/dsh-experimental-cua-macos` | 0.2.2-rc.5 | macOS 原生 provider(含签名 helper) |
| `@deepseek-ai/dsh-computer-use` | 0.2.2-rc.5 | provider 注册表 |

helper 二进制已随包分发、已签名公证(teamId `NAN929V4UM`),开启时无需下载。

## 14.12 不能做什么

- **操作 iPhone 真机**:cua 只操作本机,无远程设备驱动能力。iPhone 真机测试另需 WDA/tidevice 等独立工具链,见 docs/15。
- **操作 iOS 模拟器**:技术上可以,因为模拟器是 Mac 上的 App,cua 会当普通 App 操作;但这是模拟器,不是真机。
- **多设备并行**:一台 Mac 一个 cua provider,只操作本机一台。

## 14.13 关键文件路径

| 用途 | 路径 |
|---|---|
| bundle 选择(开关写入) | `~/.dsh/profiles/web/package.json` |
| profile 用户覆盖 | `~/.dsh/profiles/web/cordis.patch.yml` |
| cua-bundle 挂载定义 | `~/apps/harness/node_modules/@deepseek-ai/dsh-cua-bundle/cordis.patch.yml` |
| cua-macos README | `~/apps/harness/node_modules/@deepseek-ai/dsh-experimental-cua-macos/README.zh.md` |
| cua 共享 API README | `~/apps/harness/node_modules/@deepseek-ai/dsh-cua/README.zh.md` |
| helper app(arm64) | `~/apps/harness/node_modules/@deepseek-ai/dsh-experimental-cua-macos/native/bin/darwin-arm64/<hash>/DSH Computer Use.app` |
| 应用授权存储 | `~/.dsh/storages/cua_permissions_<sha256(profile)>.json` |
| Web 启动日志 | `~/dsh/backups/web.out.log` |
| Web 错误日志 | `~/dsh/backups/web.err.log` |
