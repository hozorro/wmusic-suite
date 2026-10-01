# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# musicbase-api (FastAPI / Python 3.13)
#
# 构建上下文必须是 umbrella 仓库根目录：
#   docker build -f docker/backend/Dockerfile -t musicbase/api:latest .
#
# 依赖管理器优先 uv + uv.lock；退回 requirements.txt；再退回 pyproject 直装。
# ---------------------------------------------------------------------------
ARG PYTHON_VERSION=3.13

# ============================ Stage 1: 构建依赖 ============================
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1

# uv 官方静态二进制（体积 <20MB，比 pip 快一个数量级）
COPY --from=ghcr.io/astral-sh/uv:0.7.13 /uv /usr/local/bin/uv

WORKDIR /src

# 先只拷依赖清单 —— 最大化 Docker 层缓存（改代码不会重装依赖）
# ⚠️ musicbase/pyproject.toml 必须存在，且必须带上 uv.lock 或 requirements.txt 之一
#    （缺失时用 `make check` 会提前报错；`uv lock` / `pip freeze > requirements.txt` 二选一）
COPY musicbase/pyproject.toml /src/pyproject.toml
COPY musicbase/uv.lock*          /src/uv.lock
COPY musicbase/requirements.txt* /src/requirements.txt
COPY musicbase/README.md*        /src/README.md

RUN --mount=type=cache,target=/root/.cache/uv \
    set -eux; \
    if [ -s uv.lock ]; then \
        echo "[deps] uv.lock -> uv sync (锁版本)"; \
        uv sync --frozen --no-install-project --no-dev; \
    elif [ -s requirements.txt ]; then \
        echo "[deps] requirements.txt -> uv pip install"; \
        uv pip install --python /opt/venv/bin/python -r requirements.txt; \
    else \
        echo "[deps] 无锁文件 -> 依据 pyproject 编译后安装（建议提交 uv.lock）"; \
        uv pip compile pyproject.toml -o /tmp/req.txt \
          && uv pip install --python /opt/venv/bin/python -r /tmp/req.txt; \
    fi

# 再拷源码，安装项目自身（不含 dev 依赖）
COPY musicbase/ /src/
RUN --mount=type=cache,target=/root/.cache/uv \
    if [ -s uv.lock ]; then \
        uv sync --frozen --no-dev; \
    else \
        uv pip install --python /opt/venv/bin/python --no-deps .; \
    fi

# ============================ Stage 2: 运行时 ==============================
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG INSTALL_FFMPEG=false

# ---------------------------------------------------------------------------
# 环境变量分层：本层【只放镜像作者才知道、且换了部署环境也不会变的东西】
#
#   L1 镜像层（本文件）    —— 与镜像构建绑定的：解释器行为、locale、PATH
#   L2 编排层（compose）   —— 与 volumes / 服务名耦合的契约：/music、DB_HOST=db
#   L3 部署层（.env）      —— 换了主机就要改的：密钥、PUID/PGID、宿主机路径
#
# ⚠️ 刻意【不在】本层写任何路径类变量（/music、/var/lib/musicbase/*）：
#    那些是「编排契约」，值由 docker-compose.yml 的 volumes 决定。写在这里会
#    造成两处定义——改了挂载点却忘了改 ENV，路径就静默指向不存在的目录。
#    需要默认值时请在 compose 的 environment 里写（与 volumes 同一处可见）。
#
# ⚠️ 也【不写】任何密钥：ENV 会固化进镜像层，docker history / inspect 可见。
# ---------------------------------------------------------------------------
# 中文歌名/艺人名：必须强制 UTF-8 文件系统编码，否则 open() 会抛 UnicodeEncodeError
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONUTF8=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app \
    APP_HOME=/app \
    RUN_USER=musicbase \
    TZ=Asia/Shanghai

# TZ 是唯一允许「镜像给默认、部署可覆盖」的变量：构建期要用它配置 tzdata，
# 运行期由 .env -> env_file 覆盖（env_file 优先级高于 Dockerfile ENV）。

# 运行时依赖：gosu 降权、tzdata 时区、curl 健康检查、libpq psycopg2 用
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates tzdata curl gosu libpq5 \
        $(if [ "$INSTALL_FFMPEG" = "true" ]; then echo ffmpeg; fi); \
    rm -rf /var/lib/apt/lists/*; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo $TZ > /etc/timezone

# 只搬 venv 过来，不带走构建缓存
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY musicbase/ /app/
COPY docker/backend/entrypoint.sh /usr/local/bin/entrypoint.sh

# 只建「挂载点」，具体子目录（artwork/ uploads/ playlists/）交给 entrypoint ——
# 它需要先对齐属主再降权，见 entrypoint.sh 第 2 段。
# 这里创建的只是空目录，挂载后会被宿主机目录覆盖，作用是「没挂载时也不至于报错」。
RUN set -eux; \
    chmod +x /usr/local/bin/entrypoint.sh; \
    mkdir -p /app /music /var/lib/musicbase/media /var/lib/musicbase/logs; \
    chown -R 1000:1000 /var/lib/musicbase /app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD curl -fsS http://127.0.0.1:8000/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# ⚠️ 请按实际包结构调整包名：例如 app.main:app / src.musicbase.main:app
CMD ["uvicorn", "musicbase.main:app",
     "--host", "0.0.0.0", "--port", "8000",
     "--timeout-keep-alive", "75",
     "--proxy-headers", "--forwarded-allow-ips=*"]

