#!/usr/bin/env bash
# pull_all.sh —— 拉取 4 个仓库最新代码，并按需重新打包指定服务（发版）
#
# 前提：四个仓并列在同一父目录（deploy 仓与 agent/backend/fronted 同级）
#   ~/
#   ├── paper-rag-agent
#   ├── paper-rag-backend
#   ├── paper-rag-fronted
#   └── paper-rag-deploy   ← 本脚本所在目录
#
# 用法：cd ~/paper-rag-deploy && ./pull_all.sh
#   → 第 1 步：自动拉取 4 个仓（分支见 deploy.conf：业务仓 BRANCH / deploy 仓 main），并提示哪些有更新
#   → 第 2 步：输入空格分隔的数字，选择要重建的服务（可多选）
#       1 = agent      （paper-rag-agent）
#       2 = rag        （paper-rag-backend）
#       3 = fronted    （paper-rag-fronted）
#       4 = 全部重建    （paper-rag-deploy 编排变更，或整体重新发版）
#       0 = 跳过，不重建
#   → 对选中的服务执行：docker compose up -d --build <服务...>
set -uo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$DEPLOY_DIR")"

# 读取分支配置（缺省 dev；改 deploy.conf 即可切换 dev/main）
. "$DEPLOY_DIR/deploy.conf"
BRANCH="${BRANCH:-dev}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"

# 仓库名 -> 期望分支（业务仓走 BRANCH；deploy 仓走 DEPLOY_BRANCH）
REPOS=(
  "paper-rag-agent:$BRANCH"
  "paper-rag-backend:$BRANCH"
  "paper-rag-fronted:$BRANCH"
  "paper-rag-deploy:$DEPLOY_BRANCH"
)

# 仓库 -> 对应服务名（用于提示"本次更新应重建谁"）
declare -A REPO_SVC=(
  ["paper-rag-agent"]="agent"
  ["paper-rag-backend"]="rag"
  ["paper-rag-fronted"]="fronted"
  ["paper-rag-deploy"]="全部"
)

# ==================== 第 1 步：拉取最新代码 ====================
echo "==================== 1/2 拉取最新代码 ===================="
declare -A CHANGED
ok=0
fail=0

for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"
  branch="${entry##*:}"
  dir="$BASE_DIR/$repo"

  if [ ! -d "$dir/.git" ]; then
    echo "!! 缺少 $repo（期望目录：$dir），请先 clone 到与 deploy 同级"
    fail=$((fail + 1))
    continue
  fi

  before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"

  echo "==> [$repo] 切到 $branch"
  if ! git -C "$dir" checkout "$branch" >/dev/null 2>&1; then
    echo "!! [$repo] checkout $branch 失败（有未提交改动？先 git status / git stash）"
    git -C "$dir" status -sb | head -5
    fail=$((fail + 1))
    continue
  fi

  echo "==> [$repo] git pull --ff-only origin $branch"
  # 显式指定 origin/分支：不依赖本地的 tracking 配置
  if git -C "$dir" pull --ff-only origin "$branch" >/dev/null 2>&1; then
    after="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    if [ "$before" != "$after" ]; then
      CHANGED["$repo"]=1
      echo "   [$repo] 有更新 -> 对应服务：${REPO_SVC[$repo]}"
      git -C "$dir" log --oneline "$before..$after" | sed 's/^/     /'
    else
      echo "   [$repo] 已是最新"
    fi
    ok=$((ok + 1))
  else
    echo "!! [$repo] pull 失败（网络 / 上游分叉？）"
    git -C "$dir" status -sb | head -5
    fail=$((fail + 1))
  fi
done

echo "--------------------------------------------------------"
echo "拉取汇总：成功 $ok 个，失败 $fail 个"
if [ "$fail" -gt 0 ]; then
  echo "!! 有仓库拉取失败，请先确认 GitHub 可达后再重建，避免发布旧代码"
fi

# ==================== 第 2 步：选择要重建的服务 ====================
echo ""
echo "==================== 2/2 选择要重建的服务 ===================="
echo "  1 = agent      (paper-rag-agent)"
echo "  2 = rag        (paper-rag-backend)"
echo "  3 = fronted    (paper-rag-fronted)"
echo "  4 = 全部重建    (paper-rag-deploy 编排变更，或整体重新发版)"
echo "  0 = 跳过，不重建"

changed_hint=""
for repo in "${!CHANGED[@]}"; do
  changed_hint+="${REPO_SVC[$repo]} "
done
if [ -n "$changed_hint" ]; then
  echo "  -> 本次有更新的服务：${changed_hint}（建议重建它们）"
fi

read -r -p "输入服务编号，空格分隔可多选（如：1 2 3）> " choice
# 归一化输入：去 \r（CRLF 环境）、压缩连续空格、去首尾空格
choice="$(printf '%s' "$choice" | tr -d '\r' | tr -s ' ' | sed 's/^ *//; s/ *$//')"

skip_rebuild=0
rebuild_all=0
declare -a selected=()

if [ -n "$choice" ]; then
  for n in $choice; do
    case "$n" in
      1) svc="agent" ;;
      2) svc="rag" ;;
      3) svc="fronted" ;;
      4) rebuild_all=1 ;;
      0) skip_rebuild=1 ;;
      *) echo "!! 无效编号：$n（只接受 0-4）"; exit 1 ;;
    esac
    if [ "$rebuild_all" -ne 1 ] && [ "$skip_rebuild" -ne 1 ]; then
      dup=0
      for s in "${selected[@]}"; do
        [ "$s" = "$svc" ] && dup=1
      done
      [ "$dup" -eq 0 ] && selected+=("$svc")
    fi
  done
fi

if [ "$skip_rebuild" -eq 1 ]; then
  echo "已跳过重建。完成。"
  exit 0
fi
if [ "$rebuild_all" -ne 1 ] && [ "${#selected[@]}" -eq 0 ]; then
  echo "未选择任何服务，跳过重建。完成。"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "!! 未找到 docker 命令，无法重建"
  exit 1
fi

echo ""
if [ "$rebuild_all" -eq 1 ]; then
  echo "==> docker compose up -d --build （全部服务）"
  docker compose up -d --build
else
  echo "==> docker compose up -d --build ${selected[*]}"
  docker compose up -d --build "${selected[@]}"
fi

echo ""
echo "==> 容器状态："
docker compose ps
