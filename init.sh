#!/bin/bash
# PostgreSQL 首次初始化脚本（docker-entrypoint-initdb.d）
# 职责：① 创建两个业务库（paper_rag / paper_rag_agent）② 在各自库执行建表 SQL
# 仅在数据卷为空时执行一次（docker-entrypoint 机制）
set -e

echo "==> creating databases (paper_rag / paper_rag_agent)"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    SELECT 'CREATE DATABASE paper_rag' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'paper_rag')\gexec
    SELECT 'CREATE DATABASE paper_rag_agent' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'paper_rag_agent')\gexec
EOSQL

echo "==> init paper_rag (rag db/init.sql)"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "paper_rag" -f /sql/10-rag.sql

echo "==> init paper_rag_agent (agent migrations)"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "paper_rag_agent" -f /sql/20-agent-001.sql
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "paper_rag_agent" -f /sql/30-agent-002.sql

echo "==> postgres init done"
