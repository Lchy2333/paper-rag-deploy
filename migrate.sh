#!/usr/bin/env bash
# migrate.sh —— 生产库增量迁移：query_usage.last_input_tokens（对应迁移 004）
#
# 设计要点：
#   1. SQL 内联，不依赖业务仓代码是否已拉取（可单独拷到服务器执行）；
#   2. 幂等：列已存在直接跳过，可重复运行；
#   3. lock_timeout=3s：抢不到表锁就快速失败，不会排队阻塞线上业务；
#   4. 只改元数据：PG11+ 增加"常量默认值"的列不重写表，秒级完成、无需停机。
#
# 用法：
#   bash migrate.sh                          # 默认 prg-postgres / postgres / paper_rag_agent
#   PG_CONTAINER=xxx PG_USER=yyy AGENT_DB=zzz bash migrate.sh
set -euo pipefail

CONTAINER="${PG_CONTAINER:-prg-postgres}"
PGUSER="${PG_USER:-postgres}"
DB="${AGENT_DB:-paper_rag_agent}"

run_sql() { docker exec -i "$CONTAINER" psql -U "$PGUSER" -d "$DB" -v ON_ERROR_STOP=1 "$@"; }

# ---------- 0. 容器健康检查 ----------
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "[FAIL] 容器 $CONTAINER 不存在"
  exit 1
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
  echo "[FAIL] 容器 $CONTAINER 未运行"
  exit 1
fi
echo "[OK] 容器 $CONTAINER 运行中，目标库 $DB"

# ---------- 1. 前置条件：003 必须已执行 ----------
if [ "$(run_sql -tAc "SELECT to_regclass('public.query_usage') IS NOT NULL")" != "t" ]; then
  echo "[FAIL] 缺少 query_usage 表，请先执行 migrations/003_query_usage.sql"
  exit 1
fi
echo "[OK] query_usage 表已存在"

# ---------- 2. 幂等执行 ----------
if [ "$(run_sql -tAc "SELECT count(*) FROM information_schema.columns
                       WHERE table_name = 'query_usage'
                         AND column_name = 'last_input_tokens'")" != "0" ]; then
  echo "[SKIP] last_input_tokens 已存在，无需迁移"
else
  echo "[..] 执行 ALTER TABLE query_usage ADD COLUMN last_input_tokens"
  run_sql <<'SQL'
SET lock_timeout = '3s';
ALTER TABLE query_usage
    ADD COLUMN IF NOT EXISTS last_input_tokens INT NOT NULL DEFAULT 0;
SQL
  echo "[OK] 加列完成"
fi

# ---------- 3. 校验 ----------
echo "[..] 列定义："
run_sql -c "SELECT column_name, data_type, column_default, is_nullable
              FROM information_schema.columns
             WHERE table_name = 'query_usage'
               AND column_name = 'last_input_tokens'"

echo "[..] 现有行数 / 水位为 0 的行数："
run_sql -c "SELECT count(*) AS rows,
                   count(*) FILTER (WHERE last_input_tokens = 0) AS zero_rows
              FROM query_usage"

cat <<'TIP'

[下一步]
  1) 确认迁移成功后再发版（./redeploy.sh）。顺序不能反：新代码 INSERT 需要该列。
  2) 历史行 last_input_tokens 恒为 0 → GET /threads/{id}/usage 返回 context_ratio=null
     → 前端隐藏环形指示器；该会话再问一句后才会出现，属预期行为。
TIP
