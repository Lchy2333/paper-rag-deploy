# paper-rag-deploy

论文 RAG 助手的**生产部署编排仓**。用 docker-compose 一键拉起 4 个服务：
`postgres + rag + agent + fronted(nginx)`。

> 部署过程中的踩坑记录见同目录 [《部署避坑指南》](避坑指南.md)（GitHub 网络 / 国内源 / PG18 挂载点 / gojieba cgo / 多 worker 撞表 等 12 项）。
>
> 本仓提供三套部署脚本 + 统一分支配置，见 [「部署脚本与分支管理」](#部署脚本与分支管理)。

> 三个业务仓库（agent / backend / fronted）作为同级目录被 `build:` 引用，
> clone 时保持并列：

```
D:\Project\   （或 ~/）
├── paper-rag-agent       # FastAPI + LangGraph（业务）
├── paper-rag-backend     # Go + Gin（业务）
├── paper-rag-fronted     # Vue3（业务）
└── paper-rag-deploy      # 本仓（编排）
```

## 快速开始（服务器）

```bash
# 1. clone 四个仓库（保持并列）
git clone https://github.com/Lchy2333/paper-rag-agent.git
git clone https://github.com/Lchy2333/paper-rag-backend.git
git clone https://github.com/Lchy2333/paper-rag-fronted.git
git clone https://github.com/Lchy2333/paper-rag-deploy.git

# 2. 配置密钥
cd paper-rag-deploy
cp .env.example .env            # 填 POSTGRES_PASSWORD（compose 顶层）
mkdir -p env
# 手动创建 env/agent.prod.env 和 env/rag.prod.env（见下面模板）

# 3. 首次拉起（脚本会自动把业务仓切到 deploy.conf 配置的分支）
chmod +x deploy.sh pull_all.sh redeploy.sh   # 只需第一次
./deploy.sh                                  # 拉代码 + 全量构建启动

# 4. 验证
docker compose ps                 # 4 个容器都 healthy
curl http://localhost/health      # agent 分层健康检查
curl http://localhost/api/health  # 前端经 Nginx
```

## 部署脚本与分支管理

**分支统一收敛到 `deploy.conf`，改一处、三个脚本全局生效：**

```ini
# deploy.conf
BRANCH=dev              # 业务仓（agent/backend/fronted）部署分支：dev=开发 / main=正式
DEPLOY_BRANCH=main      # 编排仓（本仓）分支，一般不用改
```

| 脚本 | 用途 | 交互 |
|---|---|---|
| `deploy.sh` | 拉 3 个业务仓 + 全量重建重启 | 无 |
| `pull_all.sh` | 拉 4 个仓 + 输入数字选服务重建 | 有 |
| `redeploy.sh` | **一键重新部署**：拉 4 个仓 + 全量重建重启 | 无 |

### 日常发版（推荐）

改代码推送业务仓后，服务器上一条命令完成发版：

```bash
cd ~/paper-rag-deploy && ./redeploy.sh
```

### 只重建部分服务

```bash
./pull_all.sh
# 拉取后按提示输入空格分隔的服务编号（可多选）：
#   1 = agent   2 = rag   3 = fronted   4 = 全部重建   0 = 跳过
```

### 切换部署分支（dev ↔ main）

```bash
# 1. 本地编辑 deploy.conf：BRANCH=main（或 dev）
# 2. 提交并推送（本仓改动统一走 main）
git add deploy.conf && git commit -m "chore: 部署分支切到 main" && git push origin main
# 3. 服务器同步 + 一键部署
cd ~/paper-rag-deploy && git pull && ./redeploy.sh
```

> ⚠️ **切分支前确认**：
> - `main` 已通过 PR 合入最新 `dev` 代码（否则会发旧版）；
> - 目标分支与当前数据库 schema 兼容（数据库卷共用，业务仓之间的迁移差异会影响启动）。

## 数据库迁移（增量脚本）

> `docker-entrypoint-initdb.d` 只在**数据卷为空**时跑一次（由 `init.sh` 依次执行 001→004）。
> **已有生产库升级时，必须手工执行对应增量脚本**，否则新代码 INSERT 会因缺列/缺表失败。

| 脚本 | 内容 | 引入功能 |
|---|---|---|
| `003_query_usage.sql` | 建 `query_usage` 表 | token 用量统计（会话累计事实源） |
| `004_query_usage_last_input.sql` | 加 `last_input_tokens` 列 | 上下文水位持久化（切会话恢复环形指示器） |

```bash
# 0) 备份（建议）
docker exec prg-postgres pg_dump -U postgres -d paper_rag_agent > backup_agent.sql

# 1) 确认前置表存在（003 未执行会报 relation "query_usage" does not exist）
docker exec prg-postgres psql -U postgres -d paper_rag_agent -c "\d query_usage"

# 2) 执行增量脚本（幂等，可重复跑；lock_timeout 避免排队阻塞业务）
docker cp ../paper-rag-agent/migrations/004_query_usage_last_input.sql prg-postgres:/tmp/004.sql
docker exec prg-postgres psql -U postgres -d paper_rag_agent -v ON_ERROR_STOP=1 \
  -c "SET lock_timeout='3s';" -f /tmp/004.sql

# 3) 校验列已存在
docker exec prg-postgres psql -U postgres -d paper_rag_agent -c \
  "SELECT column_name,data_type,column_default FROM information_schema.columns \
   WHERE table_name='query_usage' AND column_name='last_input_tokens'"

# 4) 迁移成功后再发版（顺序不能反）
./redeploy.sh
```

> `ADD COLUMN ... DEFAULT 0` 在 PG11+ 只改元数据、不重写表，`ACCESS EXCLUSIVE` 锁极短；
> 旧代码不认识新列也不受影响，因此可以"先迁移、后发版"。

## 密钥模板

### `env/agent.prod.env`

```ini
APP_ENV=prod
LLM_BASE_URL=https://ark.cn-beijing.volces.com/api/plan/v3/
LLM_API_KEY=<方舟 key>
LLM_MODEL=deepseek-v4-flash
RAG_BASE_URL=http://rag:8080
RAG_API_KEY=<与 rag 一致的 key>
DATABASE_URL=postgresql://postgres:<密码>@postgres:5432/paper_rag_agent
JWT_SECRET=<随机串>
JWT_EXPIRE_MINUTES=10080
# 上下文窗口（可选，默认 1048576）：>0 直接使用、不联网；填 0 才回退 models.dev 目录
# LLM_CONTEXT_WINDOW=1048576
# LLM_PROVIDER_ID=volcengine-coding-plan
```

### `env/rag.prod.env`

```ini
POSTGRES_PASSWORD=<密码，与 .env 的 POSTGRES_PASSWORD 一致>
POSTGRES_HOST=postgres            # 容器内连 compose 服务名（必须）
SILICONFLOW_API_KEY=<硅基流动 key>
RAG_API_KEY=<与 agent 一致的 key>
```

> ⚠️ **一致性要求**：
> - `DATABASE_URL` 里的密码 = `rag.prod.env` 的 `POSTGRES_PASSWORD` = 顶层 `.env` 的 `POSTGRES_PASSWORD`（三者同值）；
> - agent 与 rag 的 `RAG_API_KEY` 必须同值（服务间鉴权）。
>
> 生成随机值：
> ```bash
> python3 -c "import secrets; print(secrets.token_urlsafe(16))"  # PG 密码
> python3 -c "import secrets; print(secrets.token_urlsafe(32))"  # RAG_API_KEY
> python3 -c "import secrets; print(secrets.token_urlsafe(48))"  # JWT_SECRET
> ```

## rag 的 config.yaml

服务器上 clone 后，从模板复制一份（已配好 SiliconFlow 云 API）：

```bash
cp ~/paper-rag-backend/config/config.example.yaml ~/paper-rag-backend/config/config.yaml
```

## 常用命令

```bash
# —— 部署 / 发版 ——
./redeploy.sh                       # 一键：拉 4 仓 + 全量重建重启（推荐）
./pull_all.sh                       # 拉 4 仓 + 选服务重建
./deploy.sh                         # 拉 3 业务仓 + 全量重建重启

# —— docker compose 直接操作 ——
docker compose up -d --build        # 构建 + 启动
docker compose up -d --build agent  # 只重建指定服务（agent / rag / fronted）
docker compose ps                   # 状态
docker compose logs -f agent        # 看 agent 日志
docker compose logs -f rag          # 看 rag 日志
docker compose down                 # 停止（保留数据卷）
docker compose down -v              # 停止并清空数据（慎用！会删数据库和上传文件）
```

## 端口与安全

| 端口 | 用途 | 安全组 |
|---|---|---|
| 22 | SSH | 建议仅放行你的 IP |
| 80 | 前端 + API（Nginx） | 放行（对外） |
| 443 | HTTPS（如启用） | 放行 |

> 数据库 5432 和业务端口**不对外暴露**（只在 compose 内网），容器间通过服务名互访。
