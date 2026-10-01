#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# musicbase 后端容器入口:
#   1) 对齐 PUID/PGID（保证对宿主机音乐库有读写权限）
#   2) 重建缓存/临时目录并 chown
#   3) 等数据库就绪
#   4) 执行数据库迁移（Alembic）
#   5) gosu 降权启动 uvicorn
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# 新建文件的默认权限（归档入库、标签改写生成的临时文件都受它影响）。
# 022 -> 644/755；002 -> 664/775（同组可写，适合音乐库按组共享的场景）
umask "${UMASK:-022}"

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
RUN_USER="${RUN_USER:-musicbase}"
# ⚠️ 只认后端 config.py 里真实存在的字段。TEMP_DIR / STAGING_DIR / ARTWORK_DIR
#    在那边是只读 property（由 MEDIA_ROOT 派生），用环境变量设它们是无效的，
#    所以这里也不能拿这些名字去 mkdir/chown —— 那样只会建出一堆没人用的空目录。
MEDIA_ROOT="${MEDIA_ROOT:-/var/lib/musicbase/media}"
LOG_DIR="${LOG_DIR:-/var/lib/musicbase/logs}"

log() { echo "[entrypoint] $*"; }

# ---------- 1. 用户 / 组 ----------
if [ "$(id -u)" = "0" ] && [ "${PUID}" != "0" ]; then
    if ! getent group "${PGID}" >/dev/null 2>&1; then
        groupadd -o -g "${PGID}" "${RUN_USER}"
    fi
    if ! id -u "${PUID}" >/dev/null 2>&1; then
        useradd -o -u "${PUID}" -g "${PGID}" -s /usr/sbin/nologin -d /app "${RUN_USER}"
    fi
fi

uid_for() { id -u "$1" 2>/dev/null || echo 0; }

# ---------- 2. 目录 ----------
# 后端启动时会自己 create_required_directories()，但那时已经降权成 PUID 了；
# 若宿主目录属主是 root，它会因权限不足而失败。所以在降权之前先把目录建好、属主对齐。
# 目录清单必须与 config.py 的 property 一致，多建少建都会导致运行时找不到路径。
MEDIA_SUBDIRS=(
    "artwork/tracks" "artwork/albums" "artwork/artists" "artwork/playlists" "artwork/tmps"
    "uploads/temp" "uploads/staging"
    "playlists/tmp"
)
mkdir -p "${MEDIA_ROOT}" "${LOG_DIR}"
for sub in "${MEDIA_SUBDIRS[@]}"; do
    mkdir -p "${MEDIA_ROOT}/${sub}"
done

if [ "$(id -u)" = "0" ]; then
    # MEDIA_ROOT / LOG_DIR 是应用自己的数据目录，属主必须归 PUID，否则标签改写、
    # 归档入库、日志写入都会 Permission denied。
    # 注意 ARTWORK_DIR 可能是独立挂载进来的宿主机目录，chown 会作用到宿主上——
    # 这是预期行为（它就是给本应用用的缓存目录）。
    chown -R "${PUID}:${PGID}" "${MEDIA_ROOT}" "${LOG_DIR}" 2>/dev/null || true
fi

# 音乐库是用户的目录，默认【不】碰它的属主。
# 若宿主机音乐库确实不可写，可打开开关由容器一次性修正（大库会很慢，谨慎！）
if [ "${CHOWN_LIBRARY:-false}" = "true" ] && [ "$(id -u)" = "0" ]; then
    log "CHOWN_LIBRARY=true，正在递归修正音乐库属主（大库会很慢）..."
    chown -R "${PUID}:${PGID}" "${MUSIC_LIBRARY_PATH:-/music}" 2>/dev/null || true
fi

# ---------- 3. 等数据库 ----------
if [ "${WAIT_FOR_DB:-true}" = "true" ]; then
    # 两种配置风格都支持：
    #   DATABASE_URL=postgresql+psycopg://... （compose 注入）
    #   或后端 Settings 真正在用的 DB_HOST / DB_PORT
    log "等待数据库就绪 ..."
    python - <<'PY'
import os, socket, sys, time
from urllib.parse import urlparse

url = os.environ.get("DATABASE_URL", "")
if url:
    u = urlparse(url)
    host, port = u.hostname, (u.port or 5432)
else:
    host = os.environ.get("DB_HOST") or "db"
    port = int(os.environ.get("DB_PORT") or 5432)

timeout = int(os.environ.get("WAIT_TIMEOUT", "60"))
for i in range(timeout):
    try:
        with socket.create_connection((host, port), timeout=2):
            print(f"[entrypoint] db {host}:{port} is up", flush=True)
            break
    except OSError:
        time.sleep(1)
else:
    sys.exit(f"[entrypoint] 数据库连接超时: {host}:{port}")
PY
fi

# ---------- 4. 迁移 ----------
cd /app
if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
    if [ -f "/app/alembic.ini" ] || [ -d "/app/migrations" ] || [ -d "/app/alembic" ]; then
        log "执行数据库迁移 ..."
        if [ "$(id -u)" = "0" ] && [ "${PUID}" != "0" ]; then
            gosu "${PUID}:${PGID}" python -m alembic upgrade head
        else
            python -m alembic upgrade head
        fi
    else
        log "未发现 Alembic 配置，跳过迁移"
    fi
fi

# ---------- 5. 启动 ----------
# UVICORN_WORKERS 来自 .env（部署层）。默认 1：本项目涉及标签改写、文件整理、
# 归档入库等会写同一个文件的操作，多 worker 会出现两个进程并发写同一首歌。
# 只有确认长任务都走独立任务队列后，才建议调大。
WORKERS="${UVICORN_WORKERS:-1}"
if [ "${WORKERS}" != "1" ]; then
    case " $* " in
        *" --workers "*) log "警告: CMD 已带 --workers，忽略 UVICORN_WORKERS=${WORKERS}" ;;
        *) set -- "$@" --workers "${WORKERS}" ;;
    esac
fi

log "启动: $*"
if [ "$(id -u)" = "0" ] && [ "${PUID}" != "0" ]; then
    exec gosu "${PUID}:${PGID}" "$@"
fi
exec "$@"

