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

umask "${UMASK:-022}"

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
RUN_USER="${RUN_USER:-musicbase}"
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
    chown -R "${PUID}:${PGID}" "${MEDIA_ROOT}" "${LOG_DIR}" 2>/dev/null || true
fi

if [ "${CHOWN_LIBRARY:-false}" = "true" ] && [ "$(id -u)" = "0" ]; then
    log "CHOWN_LIBRARY=true，正在递归修正音乐库属主（大库会很慢）..."
    chown -R "${PUID}:${PGID}" "${MUSIC_LIBRARY_PATH:-/music}" 2>/dev/null || true
fi

# ---------- 3. 等数据库 ----------
if [ "${WAIT_FOR_DB:-true}" = "true" ]; then
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
RUNS_UVICORN=0
case " $* " in *uvicorn*) RUNS_UVICORN=1 ;; esac

WORKERS="${UVICORN_WORKERS:-1}"
if [ "${RUNS_UVICORN}" = "1" ] && [ "${WORKERS}" != "1" ]; then
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

