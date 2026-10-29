#!/usr/bin/env bash
# redeploy.sh —— 一键重新部署（发版）：拉取 5 个仓最新代码 + 全量重建重启
#
# 与 pull_all.sh 的区别：全程无交互，适合"确认要发版"后一条命令搞定。
# 分支由 deploy.conf 的 BRANCH 控制（dev / main），改配置即可切换部署目标。
#
# 用法：cd ~/paper-rag-deploy && ./redeploy.sh
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEPLOY_DIR"

. "$DEPLOY_DIR/deploy.conf"
BRANCH="${BRANCH:-dev}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"

echo "================ 重新部署：业务分支 $BRANCH / 编排分支 $DEPLOY_BRANCH ================"

# ---------- 1. 拉取 5 个仓 ----------
for repo in paper-rag-agent paper-rag-backend paper-rag-fronted paper-rag-mcp; do
  if [ ! -d "../$repo/.git" ]; then
    echo "!! 缺少 ../$repo，请先 clone 到与 deploy 同级"
    exit 1
  fi
  echo "==> [$repo] checkout $BRANCH + git pull"
  git -C "../$repo" checkout "$BRANCH"
  git -C "../$repo" pull --ff-only origin "$BRANCH"
done

# deploy 仓自己也拉最新（可能包含新版脚本 / compose 配置）
echo "==> [paper-rag-deploy] checkout $DEPLOY_BRANCH + git pull"
git checkout "$DEPLOY_BRANCH"
git pull --ff-only origin "$DEPLOY_BRANCH"

# ---------- 2. 全量重建重启 ----------
echo "==> docker compose up -d --build"
docker compose up -d --build

# ---------- 3. 状态确认 ----------
echo ""
echo "==> 容器状态："
docker compose ps
echo ""
echo "==> 部署完成（业务分支 $BRANCH）。"
