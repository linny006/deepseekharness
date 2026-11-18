# 11. 性能审计与配置修正（2026-11-18）

## 11.1 背景

用户反馈 Web UI 体验「不够好、特别慢」。本次审计对全链路做了量化测量，定位真实瓶颈，并修正了两处配置缺陷。

**核心结论：硬件、网络、DSH 本身均无异常。慢的根因是 Agent 循环的串行模型往返次数，不是配置问题。** 本次修正的两项配置分别解决"故障时卡死过久"和"档位映射名实不符"，**不改变日常响应速度**。

## 11.2 排除项（实测数据）

| 检查项 | 实测值 | 判定 |
|---|---|---|
| CPU | 4 核 Neoverse-N1, load 0.68 | 空闲 |
| 内存 | 23 GiB, 可用 13 GiB, 无 swap | 充足 |
| DSH 进程 | CPU 0.4%, RSS ~420 MB, 11 线程 | 极低 |
| 磁盘 | `/` 72%, `/mnt/data` 69% | 略满，不影响 |
| 网关 DNS | 1.4 ms | 正常 |
| 网关 TCP 握手 | 2.0 ms | 正常 |
| 网关 TLS | 50 ms | 正常 |
| 网关 TTFB | 50–60 ms | 优秀 |
| 本机 Web 响应 | 1.5–2.7 ms | 正常 |
| 前端主 JS（gzip） | 370 KB, 加载 33 ms | 正常 |
| gzip 压缩 | 已启用 | 正常 |
| 工具执行总计 | 205 次调用共 53 s | 可忽略 |
| 插件激活告警 | 无 | 干净 |

## 11.3 真实瓶颈

### 11.3.1 单轮耗时拆解

以一次长会话（`session-a353b4b5`）为样本：

| 轮次 | 总耗时 | 步数 | 模型请求数 |
|---|---|---|---|
| turn 4 | 92.8 s | 18 | 18 |
| turn 6 | 66.1 s | 12 | 12 |
| turn 10 | 95.4 s | 15 | 15 |
| turn 11 | 107.0 s | 21 | 21 |
| **turn 12** | **337.7 s** | **54** | **54** |

该会话合计约 754 s，其中工具执行仅 53 s（**7%**），**93% 时间在等待模型。**

### 11.3.2 往返次数是线性成本

```
141–199 次模型请求
每次往返中位 4.7 s / 均值 5.5 s
54 步 × ~6 s ≈ 324 s   →  实测 337.7 s   （吻合）
```

### 11.3.3 上下文规模对单次延迟的影响

| 上下文区间 | 到下一次响应的中位耗时 |
|---|---|
| 0–40k tokens | 4.62 s |
| 40–80k | 5.34 s |
| 80–120k | 5.01 s |
| 120–160k | 5.46 s |
| **160–200k** | **7.01 s** |

该会话后半程有 82 次请求落在 160k+ 区间，每次多耗约 2.4 s。

### 11.3.4 每轮固定开销

用本地 mock 后端（零网络延迟）隔离测量：

```
DSH 进程总墙钟        3,594 ms
其中模型往返耗时         72 ms
→ 框架固定开销 ≈ 3.5 s/次运行
```

**持久化 web 服务内**测得每轮固定开销中位 **1.86 s**（p10 0.20 s，p90 7.32 s），主要来自 31 个工具的 JSON Schema（31,662 字符 ≈ 8k tokens）与系统提示词的组装。

### 11.3.5 Prompt 缓存有效

| 指标 | 值 |
|---|---|
| 未缓存输入 tokens | 1,244,036 |
| 缓存读取 tokens | 35,288,960 |
| **命中率** | **96.6%** |

末段请求命中率稳定在 99%+。缓存工作正常，不是瓶颈。

## 11.4 修正项

### 11.4.1 `medium` 档位映射：`high` → `low`

**问题**：配置中 `reasoningEfforts.medium: high`，但网关明确不支持 `medium` 这个值：

```
HTTP 400: reasoning_effort 'medium' is not supported for this model;
          supported values: ['none', 'low', 'high', 'xhigh', 'max']
```

原映射导致 UI 选「中」实际发送 `high`，档位名实不符，失去调节意义。

**修正**：

```yaml
reasoningEfforts:
  off: none
  low: low
  medium: low      # 原为 high
  high: high
  xhigh: xhigh
  max: max
```

**传输层验证**（经记录代理抓取实际出站字段）：

| DSH 档位 | 修正前实际发送 | 修正后实际发送 |
|---|---|---|
| low | `low` | `low` |
| **medium** | **`high`** | **`low`** |
| high | `high` | `high` |
| xhigh | `xhigh` | `xhigh` |

> **注意**：默认档位 `agent-default-model.reasoningEffort` 仍为 `high`，本次**未改动**。Web UI 选择器显示 `high` 是正确行为，不是缓存或回滚问题。

**为何不直接删除 `medium`**：删除后 UI 仅显示 5 档（更诚实），但若任何会话已持久化 `medium`，加载时会抛 `UNSUPPORTED_REASONING_EFFORT`：

```
dsh: UNSUPPORTED_REASONING_EFFORT: provider "pekpik" model
"deepseek-v4-1-flash-1017" does not support reasoning effort "medium"
```

保留映射是零风险方案，避免历史会话报错。

### 11.4.2 重试策略：`maxRetries: 6` → `3` 并显式配置 backoff

**问题**：`retryPolicy.maxRetries: 6` 配合默认退避（500 ms 起翻倍，上限 10 s），网关故障时最长静默等待 **27 s**，体感等同卡死。

**修正**：

```yaml
retryPolicy:
  mode: normal
  maxRetries: 3            # 原为 6
  backoff:
    initialDelayMs: 500
    maxDelayMs: 8000
    jitterRatio: 0.3
  retryableCodes:
    - EMPTY_RESPONSE
    - RATE_LIMIT
    - SERVER
    - TIMEOUT
    - TRANSPORT
    - STREAM_CLOSED
```

**实测对比**（端点不可达，新旧交替各 3 轮，消除时间漂移）：

| 轮次 | 旧配置 | 新配置 | 降幅 |
|---|---|---|---|
| 1 | 28,203 ms | 7,079 ms | 74% |
| 2 | 29,032 ms | 6,813 ms | 76% |
| 3 | 28,079 ms | 6,963 ms | 75% |

平均 **28.4 s → 7.0 s，降幅 75%**。

**配置陷阱**：`jitterRatio` 属于 `backoff` 子对象，写在 `retryPolicy` 顶层会被 schema 拒绝：

```
llm-pi-ai: provider "pekpik" retryPolicy: unknown key "jitterRatio"
→ dsh: NO_ADAPTER: no adapter registered for provider "pekpik"
```

该错误会导致 provider 完全不可用，修改时必须嵌套正确。

## 11.5 未采纳的建议及理由

审计过程中提出过若干优化建议，经实测后**证据不足或有副作用**，均未采纳：

| 建议 | 实测结果 | 结论 |
|---|---|---|
| 设 `maxTokens: 16384` 提高压缩阈值 | 模型未配 `maxTokens` 时 `reservedCompletionTokens` 为 **0**，阈值实际为 **196,608（75% 窗口）**；若设 16384 反而降到 180,224 | 方向相反，不采纳 |
| 降低默认 `reasoningEffort` | 简单任务 high vs none 差异 < 0.3 s（噪声内）；难题 high 4.25 s vs low 3.39 s，但输出质量更高 | 属用户可见取舍，不擅自改 |
| 精简工具集 | 工具数 0/5/31 时延迟 1.74/1.42/2.02 s，落在噪声内 | 无收益，不采纳 |
| 关闭 `ds-harness-remote` | 日志显示每分钟均有 RPC 调用，属**活跃使用** | 会破坏功能，不采纳 |
| 调紧工具结果裁剪阈值 | 436 条工具结果中仅 6 条超 8192 字符，已正常裁剪 | 无需改动 |
| 关闭遥测 | OTel 端点返回 502，但为异步批处理（scheduledDelay 10 s），不在关键路径 | 无收益 |

### 11.5.1 压缩阈值计算说明（易错点）

`compaction-basic` 的阈值计算：

```
reservedCompletionTokens = header.config.maxTokens ?? modelInfo.defaultMaxTokens ?? 0
messageBudgetTokens      = contextWindow - reservedCompletionTokens
pressureBudgetTokens     = messageBudgetTokens - headroomTokens
thresholdTokens          = min(contextWindow × thresholdRatio, pressureBudgetTokens)
```

关键：`modelInfo.defaultMaxTokens` 仅在模型配置**显式**声明 `maxTokens` 时才被填充（见 `dsh-llm-pi-ai/lib/index.js` 中 `if (entry.maxTokens !== void 0) configuredMaxTokens.set(...)`）。当前配置未声明，故 `reservedCompletionTokens = 0`。

代入当前参数：

```
contextWindow = 262144, headroomTokens = 65536 (默认), thresholdRatio = 0.8
threshold = min(209715, 262144 - 0 - 65536) = 196,608
```

会话实测峰值上下文 195,859 tokens，距触发阈值仅 749 tokens —— 说明压缩机制正常工作，先前"压缩失效"的判断是误判。

### 11.5.2 重试耗时的正确对照基线

早期测量曾记录"26,414 ms → 3,423 ms（降幅 87%）"。该数字使用单次最低值作基线，受噪声影响偏乐观。本节采用新旧配置**交替各 3 轮**的方式，基线更可靠（28.4 s → 7.0 s，降幅 75%）。以本表为准。

## 11.6 变更文件

三份配置同步修改，内容一致：

| 文件 | 用途 |
|---|---|
| `/mnt/data/dsh/home/profiles/web/cordis.patch.yml` | Web UI 主配置 |
| `/mnt/data/dsh/home/overlays/pekpik.yml` | CLI/Hook 叠加层 |
| `/mnt/data/dsh/home/profiles/dsh-tui/cordis.patch.yml` | TUI 配置 |

备份位置：`/mnt/data/dsh/home/backups/20261118-073418/`

完整 diff：

```diff
-              medium: high
+              medium: low

-          maxRetries: 6
+          maxRetries: 3
+          backoff:
+            initialDelayMs: 500
+            maxDelayMs: 8000
+            jitterRatio: 0.3
```

## 11.7 验证记录

| 验证项 | 方法 | 结果 |
|---|---|---|
| 三份配置结构 | 用 DSH 自带 `yaml` 库解析 | 全部正确 |
| 配置合成 | `dsh --profile web --dump-config` | exit=0，新值正确合成 |
| 启动无错误 | `journalctl -u deepseek-harness` | 无 warn/error |
| 服务重启 | PID 变更 + 启动时间 | 2027983 → 1622521 |
| medium 映射 | 记录代理抓取出站 `reasoning_effort` | 修正前 `high` / 修正后 `low` |
| 重试降级 | 新旧交替各 3 轮，端点不可达 | 28.4 s → 7.0 s |
| 端到端应答 | `dsh headless` 真实网关 | 正常返回 |
| 多步工具调用 | `uname -r` 往返验证 | 结果准确 |
| 完整 Web 启动 | 另起 3081 端口 | 监听正常、可访问 |

## 11.8 生效方式

配置修改后必须重启服务才进入运行进程：

```bash
sudo systemctl restart deepseek-harness
```

验证：

```bash
systemctl is-active deepseek-harness
journalctl -u deepseek-harness -n 20 --no-pager | grep -i error   # 应无输出
```

> **注意**：agent 会话进程是 systemd 服务进程的子进程，无法自行 `systemctl restart`（会自杀）；且 `dsh` 用户无 sudo 权限（no-new-privileges），必须由有权限的用户执行重启。

## 11.9 后续建议

本次修正**不改变**日常响应速度。若要实质提升体验，需从减少串行往返入手：

1. **任务拆小**：分多个会话执行，缩短上下文，降低单次往返延迟（160k+ 区间单次慢约 2.4 s）
2. **并行子代理**：用 `subagent` 处理相互独立的子任务，压缩墙钟时间
3. **按需调整档位**：简单任务手动切「低」，实测单次快 20–39%

单次往返的框架固定开销（约 1.86 s）由工具 schema 与系统提示词决定，属架构成本，配置层面无法消除。

## 11.10 审计过程中的错误更正

本审计初期存在若干误判，已全部通过重测更正。记录在此以免后人重复踩坑：

| 初期结论 | 实际 | 成因 |
|---|---|---|
| 压缩阈值 68,608（26% 窗口） | **196,608（75%）** | 误将 `reservedCompletionTokens` 当作 128000；实际未配 `maxTokens` 时为 0 |
| 建议设 `maxTokens: 16384` 提高阈值 | 会使阈值**降到** 180,224 | 未理解 `defaultMaxTokens` 的填充条件 |
| Prompt 缓存未生效（`cached: 0`） | 命中率 **96.6%** | 误读单条记录字段，未看会话汇总 |
| 每轮固定开销 6–7 s | 持久服务内 **1.86 s** | 把 CLI 启动开销算进了单轮成本 |
| 重试降幅 87% | **75%** | 基线取单次最低值，偏乐观 |
| 建议关闭 `ds-harness-remote` | 该插件**正被活跃使用** | 未核查调用日志即下结论 |
| `/mnt/data` 只读是磁盘故障（建议查 SMART） | 真因是 systemd `ProtectSystem=strict`，**与磁盘无关** | 未核查 unit 沙箱配置即归因硬件 |
| 「系统内无任何 SSH 私钥」 | dsh 用户没有；`ubuntu` 用户有，但 dsh 无权读取 | 表述未限定用户范围 |

## 11.11 运维坑：systemd 沙箱与 Git 对象权限

本节记录在 `/mnt/data/deepseekharness` 提交文档时踩到的两个权限问题。二者成因完全不同，容易混淆，务必区分。

### 11.11.1 症状：写入报 `Read-only file system`（而非 Permission denied）

`deepseek-harness.service` 启用了 systemd 沙箱加固：

```ini
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/home/dsh /mnt/data/dsh /mnt/data/deepseekharness \
              /mnt/data/github-project-intelligence /mnt/data/gks \
              /mnt/data/haijiao-scraw /mnt/data/gpi-probe-results
```

`ProtectSystem=strict` 会把**整个文件系统**（含 `/mnt/data`）以只读 bind mount 方式挂入服务的 mount namespace，仅 `ReadWritePaths` 列出的路径例外。因此从 agent 进程内观察到的挂载视图与宿主不同：

```
# 宿主视角
/dev/sdb1 on /mnt/data type ext4 (rw,noatime,stripe=256)

# 服务 namespace 内视角（/proc/self/mountinfo）
1691 1575 8:17 / /mnt/data ro,nosuid,noatime shared:693 master:34 - ext4 /dev/sdb1 rw,stripe=256
                                                ↑ 挂载点 ro        ↑ 超级块仍 rw
```

**关键判别点**：

| 错误信息 | 含义 | 处理方向 |
|---|---|---|
| `Read-only file system`（EROFS） | mount 层只读，多见于沙箱 | 改 `ReadWritePaths` |
| `Permission denied`（EACCES） | 文件/目录 DAC 权限不足 | 改属主/权限/组 |

**不要因为看到 ro 就去 `chmod` 或 `remount`** —— 对沙箱造成的只读完全无效，因为限制在 mount 层而非权限位。也不要据此判断磁盘故障：确认磁盘健康应查 `tune2fs -l`、`journalctl -k`、`dmesg`（需 `kernel.dmesg_restrict=0`）；OCI 云块存储无 SMART 信息，`smartctl` 报 `Unavailable` 属正常。

**修正方式**：在 unit 的 `ReadWritePaths` 追加目标路径，然后：

```bash
sudo systemctl daemon-reload
sudo systemctl restart deepseek-harness
```

**副作用提示**：每追加一个路径就多一个可写面，属攻击面扩大。仅对确需 agent 写入的项目目录开放，其余保持只读。

### 11.11.2 症状：`git commit` 报 `insufficient permission for adding an object`

放开目录写权限后，`git add` 可能成功而 `git commit` 仍失败：

```
error: insufficient permission for adding an object to repository database .git/objects
fatal: git-write-tree: error building trees
```

**成因**：`.git/objects/` 下的二级子目录（按对象 SHA-1 前两位分片）**属主不一致**。该仓库历史上由 `ubuntu` 与 `dsh` 两个用户交替操作，导致部分分片目录属 `ubuntu:ubuntu`（权限 `drwxrwxr-x`）。`dsh` 不在 `ubuntu` 组，无法写入这些分片。

实测数据（82 个分片，45 个不可写）：

```bash
$ for d in .git/objects/*/; do [ -w "$d" ] || stat -c '%A %U:%G %n' "$d"; done | head -3
drwxrwxr-x ubuntu:ubuntu .git/objects/04/
drwxrwxr-x ubuntu:ubuntu .git/objects/05/
drwxrwxr-x ubuntu:ubuntu .git/objects/0e/
```

注意 `.git/objects` 与 `.git` 本身属 `dsh:ubuntu`（组可写），所以**目录列表可读写，但子分片不行**——这也是 `git add` 能成功、`git commit` 才失败的原因：blob 落在可写分片，而新 tree 对象恰好落在不可写分片。

**为何 `chmod` 也救不了**：`chmod` 要求属主或 CAP_FOWNER，而服务 unit 设了 `CapabilityBoundingSet=`（清空）且 `NoNewPrivileges=true`，`dsh` 既非属主也无特权。

**标准解法（需 `ubuntu` 或 root 执行）**：

```bash
# 统一属主，一劳永逸
sudo chown -R ubuntu:ubuntu /mnt/data/deepseekharness/.git
# 或让 dsh 进入 ubuntu 组（需重新登录生效）
sudo usermod -aG ubuntu dsh
sudo chmod -R g+w /mnt/data/deepseekharness/.git
```

**应急解法（本文采用）：`objects/info/alternates`**

若暂时无法取得 `ubuntu` 身份，可用 Git 原生的 alternate object store，把新对象写入 dsh 可写的位置，再由主库引用：

```bash
POOL=/mnt/data/dsh/git-objects-pool/deepseekharness
mkdir -p "$POOL"
export GIT_OBJECT_DIRECTORY="$POOL"
export GIT_ALTERNATE_OBJECT_DIRECTORIES=/mnt/data/deepseekharness/.git/objects
cd /mnt/data/deepseekharness && git commit ...
echo "$POOL" > .git/objects/info/alternates
```

写入 `.git/objects/info/alternates` 后即**持久生效**，之后无需再设置环境变量，`git log`/`fsck`/`push` 均正常。

> ⚠️ **维护警告**：`/mnt/data/dsh/git-objects-pool/` 是提交数据的实际存放位置，**删除该目录会导致提交损坏**。待能以 `ubuntu` 身份操作时，应收编为主库：

```bash
cd /mnt/data/deepseekharness
git repack -ad                        # 把 alternates 中的对象并入主库
rm .git/objects/info/alternates
rm -rf /mnt/data/dsh/git-objects-pool/deepseekharness
git fsck --no-progress                # 确认无 error
```

### 11.11.3 长驻修复建议

该仓库长期由多用户共用，建议在部署阶段统一 `.git` 属主，避免同类问题复发：

```bash
# 二选一，保持全仓库一致
sudo chown -R ubuntu:ubuntu /mnt/data/deepseekharness        # 归 ubuntu
# 或
sudo chown -R dsh:ubuntu /mnt/data/deepseekharness && sudo chmod -R g+w /mnt/data/deepseekharness
```

同时把推送所需的 SSH 凭据显式化。当前 `origin` 指向 `git@github.com-dsh:linny006/deepseekharness.git`，该别名定义在 `ubuntu` 用户的 `~/.ssh/config` 中，`dsh` 用户既无该配置也无私钥，因此 **agent 无法直接 `git push`**。两种可选方案：

1. 由 `ubuntu` 身份推送：`sudo -u ubuntu git -C /mnt/data/deepseekharness push origin main`
2. 为 `dsh` 配置独立 deploy key，并在 GitHub 仓库添加对应公钥（推荐，权限可单独回收）

### 11.11.4 Git 状态损坏的恢复

排查过程中若误用 `GIT_OBJECT_DIRECTORY` 指向临时库并提交，会把 `refs/heads/main` 指向主库不存在的对象，导致：

```
fatal: bad object HEAD
```

恢复步骤（对象本身通常未丢失）：

```bash
# 1. 确认原提交对象仍在
git cat-file -t d7b05c5        # 应输出 commit

# 2. 重置 ref
echo d7b05c5... > .git/refs/heads/main

# 3. 清理 reflog 中的无效行
grep -v '<失效 SHA>' .git/logs/HEAD > /tmp/h && mv /tmp/h .git/logs/HEAD

# 4. 重建 index（不要 rm 后直接 git add，会写只读 objects）
git read-tree HEAD

# 5. 验证
git fsck --no-progress | grep -v dangling   # 应为空
```
