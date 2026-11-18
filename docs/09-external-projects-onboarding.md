# 9. 外部项目接入 DSH 开发与安全部署

## 9.1 背景

本机 `/mnt/data` 下有三个 `ubuntu` 用户原来运维的项目，需要交给 `dsh` 用户通过 DSH 开发和验证：

- `/mnt/data/gks`（GitHub Key Scrawl，生产服务）
- `/mnt/data/github-project-intelligence`（GPI，生产服务）
- `/mnt/data/gpi-probe-results`（GPI Probe 数据目录）

当前 `/mnt/data` 已递归归属 `dsh:dsh`，`dsh` 在 `docker` 组。但这些项目的生产部署、凭据和 systemd 定时任务仍以 `ubuntu` 或 `root` 运行。

## 9.2 各项目现状

### gks

| 层 | 路径 | 属主 | 说明 |
|---|---|---|---|
| 开发源码 | `/mnt/data/gks/repository` | `dsh:dsh` | git 仓库，origin = `git@github.com-gks:linny006-tecch/github-key-scawl.git` |
| 生产部署 | `/opt/gks/deploy/` | `ubuntu:ubuntu`（700） | docker-compose.yml + .env（root:root 644，dsh 不可读） |
| 生产容器 | `deploy-verifier-1` 等 5 个 | root | 通过 `/opt/gks/deploy/docker-compose.yml` 运行 |
| systemd timer | `gks-yield-monitor.timer` 等 | root | `User=root`，调用容器内脚本或 `/opt/gks/` 下脚本 |
| GitHub deploy key | `/mnt/data/gks/github-deploy-key` | `dsh:dsh`（600） | 项目专用 SSH deploy key |
| venv | `/mnt/data/gks/repository/.venv` | `dsh:dsh` | 当前不可用，需要重建 |

生产凭据隔离：

- `/opt/gks/deploy/.env` 是 `root:root 644`，`dsh` 不能读取
- `/mnt/data/gks/repository/deploy/production-runtime.env` 是 `dsh:dsh 664`，`dsh` 能读取（开发用，非生产凭据）
- `dsh` 在 docker 组，能看到 `deploy-*` 容器，但不能读生产 `.env`

### github-project-intelligence

| 层 | 路径 | 属主 | 说明 |
|---|---|---|---|
| 开发源码 | `/mnt/data/github-project-intelligence` | `dsh:dsh` | git 仓库，origin = `git@github.com:linny006/github-project-intelligence.git` |
| 部署配置 | `deploy/docker-compose.yml` | `dsh:dsh` | 十一服务 compose，含 PostgreSQL/Redis 依赖 |
| deploy/.env | 不存在于开发目录 | — | 生产 `.env` 在别处，开发目录无生产凭据 |
| AGENTS.md | 项目根 | `dsh:dsh` | 指定开发机器 `oraclecloud_APP_bt`（本机） |
| Python | `.venv` + `uv` | `dsh:dsh` | 使用 `uv sync --frozen --extra dev --python 3.12` |

### gpi-probe-results

| 项 | 说明 |
|---|---|
| 路径 | `/mnt/data/gpi-probe-results` |
| 权限 | `700 dsh:dsh` |
| 性质 | GPI Probe Service 的结果数据目录，不是代码仓库 |
| 作用 | 被 GPI 通过 Docker 内网调用 `gpi-probe-service` 写入 |

## 9.3 安全原则

在把项目交给 `dsh` 开发时，必须遵守以下原则：

1. 开发与生产凭据分离：`dsh` 只能接触开发源码和开发环境凭据，不能读生产 `.env`
2. 不碰生产部署：`/opt/gks/deploy/` 下的 `.env`、compose、容器由 `ubuntu`/`root` 管理，`dsh` 不直接修改
3. 不碰 systemd timer：`gks-*` 定时任务以 root 运行，不改属主和配置
4. 不碰 SSH：绝对不修改 `/home/ubuntu` 权限（SSH 红线，见 `docs/06-security-audit.md`）
5. Docker 能力限制：`dsh` 虽在 docker 组，但不重启、重建或停止生产容器，除非明确授权
6. Git 推送需授权：commit、push、PR、部署均须用户明确同意（gks AGENTS.md 已有此约定）

## 9.4 接入方案（推荐）

### 步骤 1：在 DSH 中注册工作区

在 DSH Web UI 或手机端，把以下目录添加为工作区：

```text
/mnt/data/gks/repository
/mnt/data/github-project-intelligence
```

`gpi-probe-results` 是数据目录，不需要注册为工作区。

### 步骤 2：重建 gks 开发环境

gks 的 `.venv` 当前不可用，需要重建：

```bash
sudo -iu dsh
cd /mnt/data/gks/repository

# 使用项目内 python 缓存
export UV_PYTHON_INSTALL_DIR=/mnt/data/gks/repository/.python
export UV_CACHE_DIR=/mnt/data/gks/repository/.cache/uv

# 同步依赖
uv sync --frozen --extra dev --python 3.12

# 验证
uv run --frozen --extra dev python -m pytest -q tests/ 2>&1 | tail -20
uv run --frozen gks --help
```

注意：gks 的 AGENTS.md 指定 `/home/ubuntu/.local/bin/uv`，`dsh` 可能没有权限读。
如果不可用，用 `pip install uv` 或 `curl -LsSf https://astral.sh/uv/install.sh | sh` 安装到 `dsh` 家目录。

### 步骤 3：重建 gpi 开发环境

```bash
sudo -iu dsh
cd /mnt/data/github-project-intelligence

export UV_PYTHON_INSTALL_DIR=/mnt/data/github-project-intelligence/.python
export UV_CACHE_DIR=/mnt/data/github-project-intelligence/artifacts/cache/uv

uv sync --frozen --extra dev --python 3.12

# 验证
uv run --frozen --extra dev python -m pytest -q tests/ 2>&1 | tail -20
uv run --frozen gpi --help
```

### 步骤 4：验证 DSH Agent 能开发

在 DSH Web UI 或 TUI 中，选择 `gks/repository` 工作区，发送测试任务：

```text
分析当前项目结构，确认依赖安装是否正常，运行测试并报告结果。
不要修改任何生产配置，不要推送 Git。
```

Agent 应能：

- 读取项目代码
- 运行 `uv run pytest`
- 报告结果
- 不接触 `/opt/gks/` 生产目录

## 9.5 生产部署方式（由 ubuntu/root 管理，非 dsh）

### gks 生产部署

当前生产部署在 `/opt/gks/deploy/`，由 `ubuntu` 用户操作：

```bash
# 以 ubuntu 用户操作，不是 dsh
cd /opt/gks/deploy
docker compose ps
docker compose logs -f --tail 50
```

`dsh` 可以查看容器状态但不能操作：

```bash
# dsh 只读查看
docker ps --filter name=deploy-
docker logs deploy-verifier-1 --tail 20
```

### gpi 生产部署

gpi 的生产部署在 `deploy/docker-compose.yml`，但生产 `.env` 由 `ubuntu` 管理。
`dsh` 可以用开发环境运行测试，但不能启动生产服务。

## 9.6 风险与控制

| 风险 | 控制 |
|---|---|
| `dsh` 能读 `production-runtime.env`（664） | 该文件是开发用运行时配置，不含生产密钥；真正密钥在 `/opt/gks/deploy/.env`（root:root，dsh 不可读） |
| `dsh` 在 docker 组能操作容器 | 不授权 `dsh` 执行 `docker restart/stop/rm` 生产容器 |
| `dsh` 能读 GitHub deploy key | 该 key 是项目专用只读 key，不是账号级 token；已 600 |
| `dsh` 能写源码目录 | 这是开发预期行为；生产部署不受影响 |
| systemd timer 以 root 运行 | 不改属主和配置，`dsh` 不碰 |

## 9.7 待确认事项

1. `dsh` 是否需要 `uv` 工具？当前 `uv` 在 `/home/ubuntu/.local/bin/`，`dsh` 可能无权读
2. gks 和 gpi 是否需要给 `dsh` 配置项目专用 Git deploy key（类似 DSH 文档仓库的做法）
3. 是否需要让 `dsh` 参与生产部署流程？当前建议：`dsh` 只做开发验证，生产部署仍由 `ubuntu` 执行
4. `gpi-probe-results` 是否需要调整权限让 GPI 容器写入？当前 700 dsh:dsh，容器以 root 运行应可写
