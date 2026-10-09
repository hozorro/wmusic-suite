#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 把 3 个独立仓库挂到 umbrella 仓库下
#
#   方式 A（推荐·保留独立版本控制）：git submodule
#       ./scripts/init-umbrella.sh submodule  <musicbase-url> <musicplayer-url> <musicman-url>
#
#   方式 B（单一仓库·一次 clone 就齐全）：git subtree
#       ./scripts/init-umbrella.sh subtree    <musicbase-url> <musicplayer-url> <musicman-url>
#
# 说明见 DEVDOC.md §2「仓库整合：submodule vs subtree」
# ---------------------------------------------------------------------------
set -Eeuo pipefail

MODE="${1:?submodule|subtree}"
MB_URL="${2:?请把 musicbase 仓库地址作为参数传入}"
MP_URL="${3:?请把 musicplayer 仓库地址作为参数传入}"
MM_URL="${4:?请把 musicman 仓库地址作为参数传入}"
BRANCH="${BRANCH:-main}"

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -d .git ] || git init -b "${BRANCH}"

case "${MODE}" in
  submodule)
    echo "==> 添加子模块（submodule）"
    git submodule add -b "${BRANCH}" --name musicbase    "${MB_URL}" musicbase
    git submodule add -b "${BRANCH}" --name musicplayer  "${MP_URL}" musicplayer
    git submodule add -b "${BRANCH}" --name musicman     "${MM_URL}" musicman
    git submodule update --init --recursive
    echo "==> 完成。别人克隆时需要： git clone --recurse-submodules <umbrella-url>"
    ;;
  subtree)
    echo "==> 合并子树（subtree，保留各自提交历史）"
    git subtree add --prefix=musicbase   "${MB_URL}" "${BRANCH}"
    git subtree add --prefix=musicplayer "${MP_URL}" "${BRANCH}"
    git subtree add --prefix=musicman    "${MM_URL}" "${BRANCH}"
    echo "==> 完成。"
    echo "    拉取上游更新: git subtree pull --prefix=musicbase ${MB_URL} ${BRANCH}"
    echo "    反向推送更新: git subtree push --prefix=musicbase ${MB_URL} ${BRANCH}"
    ;;
  *)
    echo "未知模式: ${MODE}（submodule|subtree）"; exit 1;;
esac

echo "==> 当前目录结构:"
ls -d musicbase musicplayer musicman docker scripts docker-compose.yml 2>/dev/null || true

