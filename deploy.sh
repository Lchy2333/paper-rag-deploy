#!/usr/bin/env bash
# 一键部署/更新脚本：pull 三个业务仓 + compose 重建
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

for repo in paper-rag-agent paper-rag-backend paper-rag-fronted; do
  if [ -d "../$repo" ]; then
    echo "==> git pull $repo (dev)"
    git -C "../$repo" checkout dev
    git -C "../$repo" pull
  else
    echo "!! 缺少 ../$repo，请先 clone"
    exit 1
  fi
done

echo "==> docker compose build & up"
docker compose up -d --build

echo "==> 部署完成。检查状态："
docker compose ps
