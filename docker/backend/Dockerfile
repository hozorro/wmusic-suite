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

COPY --from=ghcr.io/astral-sh/uv:0.7.13 /uv /usr/local/bin/uv

WORKDIR /src

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

COPY musicbase/ /src/
RUN --mount=type=cache,target=/root/.cache/uv \
    if [ -s uv.lock ]; then \
        uv sync --frozen --no-dev; \
    else \
        uv pip install --python /opt/venv/bin/python --no-deps .; \
    fi

# ================== Stage 2: fpcalc（AcoustID 音频指纹工具）=================
FROM python:${PYTHON_VERSION}-slim-bookworm AS fpcalc

ARG FPCALC_VERSION=1.6.1
ARG TARGETARCH
# 留空则直连 GitHub；填前缀即可换镜像源，例如 https://ghfast.top/https://github.com
ARG FPCALC_MIRROR=

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    arch="${TARGETARCH:-}"; \
    [ -n "$arch" ] || arch="$(uname -m)"; \
    case "$arch" in \
        amd64|x86_64)  arch=x86_64; sha=fc16cd37a70168040bc9ceb45f1d4d1216f5a75bc4c9cf8564bea70ac6a45733 ;; \
        arm64|aarch64) arch=arm64;  sha=7eaf5d655c4aa172ab28e3c870b8bb61dd2c327ac94de145676f88842cf6215a ;; \
        *) echo "不支持的架构: $arch （chromaprint 官方只提供 linux x86_64 / arm64 两种）" >&2; exit 1 ;; \
    esac; \
    name="chromaprint-fpcalc-${FPCALC_VERSION}-linux-${arch}"; \
    url="${FPCALC_MIRROR:-https://github.com}/acoustid/chromaprint/releases/download/v${FPCALC_VERSION}/${name}.tar.gz"; \
    echo "[fpcalc] ${FPCALC_VERSION} / linux-${arch} <- ${url}"; \
    curl -fsSL --retry 3 --retry-delay 2 -o /tmp/fpcalc.tgz "$url"; \
    echo "${sha}  /tmp/fpcalc.tgz" | sha256sum -c -; \
    tar -xzf /tmp/fpcalc.tgz -C /tmp; \
    mkdir -p /out; \
    cp "/tmp/${name}/fpcalc" /out/fpcalc; \
    chmod 0755 /out/fpcalc; \
    rm -rf /tmp/fpcalc.tgz "/tmp/${name}"; \
    /out/fpcalc -version

# ============================ Stage 3: 运行时 ==============================
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG INSTALL_FFMPEG=false

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
    FPCALC=/usr/local/bin/fpcalc \
    TZ=Asia/Shanghai

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates tzdata curl gosu libpq5 \
        $(if [ "$INSTALL_FFMPEG" = "true" ]; then echo ffmpeg; fi); \
    rm -rf /var/lib/apt/lists/*; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo $TZ > /etc/timezone

COPY --from=builder /opt/venv /opt/venv

COPY --from=fpcalc /out/fpcalc /usr/local/bin/fpcalc

WORKDIR /app
COPY musicbase/ /app/
COPY docker/backend/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN set -eux; \
    chmod +x /usr/local/bin/entrypoint.sh; \
    mkdir -p /app /music /var/lib/musicbase/media /var/lib/musicbase/logs; \
    chown -R 1000:1000 /var/lib/musicbase /app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD curl -fsS http://127.0.0.1:8000/healthz >/dev/null 2>&1 \
        || curl -fsS -o /dev/null http://127.0.0.1:8000/openapi.json

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--timeout-keep-alive", "75", \
     "--proxy-headers", "--forwarded-allow-ips=*"]

