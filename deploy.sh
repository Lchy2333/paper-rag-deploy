#!/usr/bin/env bash
# deploy.sh —— 一键部署/更新脚本：pull 四个业务仓（分支见 deploy.conf）+ compose 重建
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

# 读取分支配置（缺省 dev）
. "$DEPLOY_DIR/deploy.conf"
BRANCH="${BRANCH:-dev}"

for repo in paper-rag-agent paper-rag-backend paper-rag-fronted paper-rag-mcp; do
  if [ -d "../$repo" ]; then
    echo "==> [$repo] git pull ($BRANCH)"
    git -C "../$repo" checkout "$BRANCH"
    git -C "../$repo" pull --ff-only origin "$BRANCH"
  else
    echo "!! 缺少 ../$repo，请先 clone"
    exit 1
  fi
done

echo "==> docker compose build & up"
docker compose up -d --build

echo "==> 部署完成（分支 $BRANCH）。检查状态："
docker compose ps
