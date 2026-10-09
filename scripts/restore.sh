#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 恢复备份  ⚠️ 危险操作：会覆盖现有数据库与 artwork 缓存
#   用法： ./scripts/restore.sh <备份目录> [--yes]
#   例如： ./scripts/restore.sh ./backups/20260928-101900
# ---------------------------------------------------------------------------
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SNAP="${1:?用法: restore.sh <备份目录> [--yes]}"
ASSUME_YES="${2:-}"

[ -d "${SNAP}" ] || { echo "备份目录不存在: ${SNAP}"; exit 1; }
set -a; [ -f .env ] && source .env; set +a
[ -f "${SNAP}/env.bak" ] && set -a && source "${SNAP}/env.bak" && set +a

echo "=============================================================="
echo "⚠️  此操作非常危险，可能导致不可逆的数据丢失！"
echo "    目标数据库: ${POSTGRES_DB:-musicbase}"
echo "    媒体目录(artwork/uploads): ${MEDIA_DIR:-<未设置>}"
echo "    备份快照: ${SNAP}"
echo "    快照内容: $(ls -1 "${SNAP}" | tr '\n' ' ')"
echo "=============================================================="

if [ "${ASSUME_YES}" != "--yes" ]; then
    read -r -p "确认恢复？请输入 RESTORE 以继续: " ans
    [ "${ans}" = "RESTORE" ] || { echo "已取消"; exit 1; }
fi

echo "==> 停止业务容器（保留 db）"
docker compose stop api web

if [ -f "${SNAP}/musicbase.dump" ]; then
    echo "==> 重建 schema 并导入数据库"
    docker compose exec -T db psql -U "${POSTGRES_USER:-musicbase}" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${POSTGRES_DB:-musicbase}';"
    docker compose exec -T db dropdb -U "${POSTGRES_USER:-musicbase}" --if-exists "${POSTGRES_DB:-musicbase}"
    docker compose exec -T db createdb -U "${POSTGRES_USER:-musicbase}" "${POSTGRES_DB:-musicbase}"
    docker compose exec -T db pg_restore \
        -U "${POSTGRES_USER:-musicbase}" -d "${POSTGRES_DB:-musicbase}" \
        --no-owner --no-privileges < "${SNAP}/musicbase.dump"
elif [ -f "${SNAP}/musicbase.sql" ]; then
    docker compose exec -T db psql -U "${POSTGRES_USER:-musicbase}" -d "${POSTGRES_DB:-musicbase}" \
        < "${SNAP}/musicbase.sql"
else
    echo "!! 备份里没有数据库文件"
fi

if [ -f "${SNAP}/media.tar.gz" ] && [ -d "${MEDIA_DIR:-}" ]; then
    echo "==> 恢复媒体目录（artwork / uploads / playlists）"
    tar -xzf "${SNAP}/media.tar.gz" -C "${MEDIA_DIR}"
elif [ -f "${SNAP}/artwork.tar.gz" ]; then
    # 旧版备份格式：那时 artwork 还被当成独立目录（ARTWORK_DIR）。
    # 现在它恒等于 MEDIA_DIR/artwork，所以没设 ARTWORK_DIR 时落到那个位置。
    art_dst="${ARTWORK_DIR:-}"
    if [ -z "${art_dst}" ] && [ -n "${MEDIA_DIR:-}" ]; then
        art_dst="${MEDIA_DIR}/artwork"
    fi
    if [ -d "${art_dst}" ]; then
        echo "==> 恢复 artwork 缓存（旧版备份格式）: ${art_dst}"
        tar -xzf "${SNAP}/artwork.tar.gz" -C "${art_dst}"
    else
        echo "==> 备份里没有媒体文件，跳过"
    fi
else
    echo "==> 备份里没有媒体文件，跳过"
fi

if [ -f "${SNAP}/musicbase.env.bak" ]; then
    echo "==> 备份里含 musicbase/.env（后端密钥）。若确需一并回滚，请手动执行："
    echo "     cp '${SNAP}/musicbase.env.bak' musicbase/.env"
fi

if [ -f "${SNAP}/logs.tar.gz" ]; then
    echo "==> 恢复日志卷"
    docker compose run --rm --entrypoint sh api -c 'tar -xzf - -C /var/lib/musicbase/logs' \
        < "${SNAP}/logs.tar.gz"
fi

echo "==> 启动服务"
docker compose up -d
echo "==> 完成。音乐库文件本身属于宿主机资产，不在此备份范围内，请另行保障。"

