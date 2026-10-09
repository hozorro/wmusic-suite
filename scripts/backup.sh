#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 一体化备份：PostgreSQL + artwork 缓存 + 配置
#   用法： ./scripts/backup.sh [备份根目录]
#   产物： <备份根目录>/<时间戳>/{musicbase.dump, musicbase.sql, artwork.tar.gz, meta.json}
# ---------------------------------------------------------------------------
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

set -a; [ -f .env ] && source .env; set +a

BACKUP_ROOT="${1:-${BACKUP_DIR:-./backups}}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_ROOT}/${STAMP}"
RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-14}"

mkdir -p "${OUT}"
chmod 700 "${OUT}"        # 里面会放 env.bak（明文密钥），别让同机其他用户读到
echo "==> 备份目录: ${OUT}"

echo "==> 导出 PostgreSQL (custom format)"
docker compose exec -T db pg_dump \
    -U "${POSTGRES_USER:-musicbase}" \
    -Fc --no-owner --no-acl \
    "${POSTGRES_DB:-musicbase}" > "${OUT}/musicbase.dump"

echo "==> 导出 PostgreSQL (纯 SQL, 便于审阅/单表恢复)"
docker compose exec -T db pg_dump \
    -U "${POSTGRES_USER:-musicbase}" \
    --no-owner --no-acl \
    "${POSTGRES_DB:-musicbase}" > "${OUT}/musicbase.sql"

# 媒体根目录：artwork 缓存 + uploads/temp + uploads/staging（可能还有没归档的上传）
# artwork 就在 MEDIA_DIR/artwork 下面（没有独立的 ARTWORK_DIR 了），所以打这一份就够。
if [ -d "${MEDIA_DIR:-}" ]; then
    echo "==> 打包媒体目录（artwork / uploads / playlists）: ${MEDIA_DIR}"
    tar -czf "${OUT}/media.tar.gz" -C "${MEDIA_DIR}" .
else
    echo "==> MEDIA_DIR 未设置或不存在，跳过"
fi

# 两份配置都要存：顶层 .env 是编排参数，musicbase/.env 才含 SECRET_KEY。
# 恢复时按原路径放回，否则要么连不上库，要么起不来服务。
cp .env            "${OUT}/env.bak"           2>/dev/null || true
cp musicbase/.env  "${OUT}/musicbase.env.bak" 2>/dev/null || true

if docker compose ps -q api >/dev/null 2>&1; then
    echo "==> 打包后端日志卷"
    docker compose run --rm --entrypoint sh api -c \
        'tar -czf - -C /var/lib/musicbase/logs .' > "${OUT}/logs.tar.gz" 2>/dev/null \
        && echo "    完成" || echo "    跳过（获取日志失败）"
fi

cat > "${OUT}/meta.json" <<EOF
{
  "created_at": "$(date -Iseconds)",
  "image_tag": "${IMAGE_TAG:-latest}",
  "music_dir": "${MUSIC_DIR:-}",
  "media_dir": "${MEDIA_DIR:-}",
  "files": $(ls -1 "${OUT}" | sed 's/.*/"&"/' | paste -sd, -)
}
EOF

echo "==> 清理 ${RETAIN_DAYS} 天前的旧备份"
find "${BACKUP_ROOT}" -maxdepth 1 -type d -name '20*' -mtime "+${RETAIN_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true

du -sh "${OUT}"
echo "==> 完成: ${OUT}"

