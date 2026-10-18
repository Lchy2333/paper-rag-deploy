# paper-rag-deploy

论文 RAG 助手的**生产部署编排仓**。用 docker-compose 一键拉起 4 个服务：
`postgres + rag + agent + fronted(nginx)`。

> 部署过程中的踩坑记录见同目录 [《部署避坑指南》](避坑指南.md)（GitHub 网络 / 国内源 / PG18 挂载点 / gojieba cgo / 多 worker 撞表 等 12 项）。

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
cd paper-rag-agent && git checkout dev && cd ..
cd paper-rag-backend && git checkout dev && cd ..
cd paper-rag-fronted && git checkout dev && cd ..

# 2. 配置密钥
cd paper-rag-deploy
cp .env.example .env            # 填 POSTGRES_PASSWORD（compose 顶层）
mkdir -p env
# 手动创建 env/agent.prod.env 和 env/rag.prod.env（见下面模板）

# 3. 拉起
docker compose up -d --build

# 4. 验证
docker compose ps                 # 4 个容器都 healthy
curl http://localhost/health      # agent 分层健康检查
curl http://localhost/api/health  # 前端经 Nginx
```

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
docker compose up -d --build     # 构建 + 启动
docker compose ps                # 状态
docker compose logs -f agent     # 看 agent 日志
docker compose logs -f rag       # 看 rag 日志
docker compose down              # 停止（保留数据卷）
docker compose down -v           # 停止并清空数据（慎用！会删数据库和上传文件）

# 更新代码后重新部署
git -C ../paper-rag-agent pull
git -C ../paper-rag-backend pull
git -C ../paper-rag-fronted pull
docker compose up -d --build
```

## 端口与安全

| 端口 | 用途 | 安全组 |
|---|---|---|
| 22 | SSH | 建议仅放行你的 IP |
| 80 | 前端 + API（Nginx） | 放行（对外） |
| 443 | HTTPS（如启用） | 放行 |

> 数据库 5432 和业务端口**不对外暴露**（只在 compose 内网），容器间通过服务名互访。
