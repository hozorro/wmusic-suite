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

# ================== Stage 2: fpcalc（AcoustID 音频指纹工具）=================
# pyacoustid 生成指纹时要调用 fpcalc 可执行文件：
#     fpcalc = os.environ.get('FPCALC', 'fpcalc')   # acoustid.py 就是这么取路径的
# 所以只要把它放进 PATH，后端无需任何改动。
#
# 【为什么用官方 release 的二进制，而不是 apt install libchromaprint-tools】
#   ① 官方包是【完全静态】的：chromaprint 的 packaging/build.sh 用了
#      -DBUILD_SHARED_LIBS=OFF，linux-x86_64 还显式加了
#      -static -static-libgcc -static-libstdc++，FFmpeg 也换成 acoustid 自己
#      构建的 audio-only 静态包（8.0）。所以这 2MB 的 fpcalc 自带 mp3/flac
#      解码能力，不依赖系统上任何 .so，换发行版也不会挂。
#   ② Debian 的 libchromaprint-tools 会连带装上 libchromaprint.so.1，
#      而 pyacoustid 的分支判断是：
#          if have_audioread and have_chromaprint and not force_fpcalc:
#              return _fingerprint_file_audioread(...)   # ← 会走到这里
#          else:
#              return _fingerprint_file_fpcalc(...)
#      libchromaprint.so.1 一旦存在，have_chromaprint 变 True，指纹就【改走
#      audioread 分支】（在 Python 侧解码），而 audioread 还需要 gstreamer 或
#      ffmpeg 可执行文件才能解码；两者都没有时报 "Fingerprint generation failed"。
#      → 只装 fpcalc、不装 libchromaprint，后端才会稳定走 fpcalc 分支。
#
# 版本与 sha256 来源：https://github.com/acoustid/chromaprint/releases/tag/v1.6.1
# 连不上 GitHub 时：--build-arg FPCALC_MIRROR=https://<加速前缀>/https://github.com
# 该 stage 只产出 /out/fpcalc，apt 与临时文件都不会进入最终镜像。
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS fpcalc

ARG FPCALC_VERSION=1.6.1
# BuildKit 自动注入 TARGETARCH（amd64 / arm64）；老 builder 下用 uname -m 兜底
ARG TARGETARCH
# 留空则直连 GitHub；填前缀即可换镜像源，例如 https://ghfast.top/https://github.com
ARG FPCALC_MIRROR=

# slim 基础镜像里既没有 curl 也没有 wget（见 docker-library/python 的 slim 模板），
# 且 curl 只在运行时阶段装过、这里用不到 —— 本阶段自备，不进最终镜像。
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
#
# 例外说明：FPCALC 是个「路径」但不是「编排契约」——它指向的是镜像内自带的
#    工具（Stage 2 的产物），跟 volumes 无关，任何部署环境都相同，所以归 L1。
#    写它的目的是让 pyacoustid 的取值确定化：acoustid.py 默认按 PATH 找
#    'fpcalc'，显式给出绝对路径后，即使将来 PATH 被改动也不会突然找不到后端。
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
    FPCALC=/usr/local/bin/fpcalc \
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

# fpcalc：静态二进制，已在上一个阶段完成 sha256 校验与版本自检。
# 与 ENV FPCALC=/usr/local/bin/fpcalc 对应；放 /usr/local/bin 也在默认 PATH 上，
# 所以就算后端代码直接写死 'fpcalc' 也能找到。
COPY --from=fpcalc /out/fpcalc /usr/local/bin/fpcalc

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

# 健康检查：后端目前还没有 /healthz 路由，所以先探 /healthz，失败则退回 FastAPI
# 默认自带的 /openapi.json（返回 200 即说明进程与路由都已就绪）。
# 等后端补上 /healthz（见 README 的后端改动 checklist）后，第一个探测就会命中，
# 这里无需再改。⚠️ watcher 服务复用本镜像，但它在 compose 里关掉了健康检查。
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD curl -fsS http://127.0.0.1:8000/healthz >/dev/null 2>&1 \
        || curl -fsS -o /dev/null http://127.0.0.1:8000/openapi.json

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# 模块名已对齐真实代码：后端仓库根目录下有 app/ 包，入口是 app/main.py 里的 app 对象
# （与后端自带的 deploy/supervisor.conf.template 中 `uvicorn app.main:app` 一致）。
# API 路由统一挂在 /api/v1（app/main.py: include_router(api_router, prefix="/api/v1")）。
#
# ⚠️ exec 形式（JSON 数组）跨行【必须】在行尾写 `\`：Dockerfile 的续行只认行尾转义符，
#    不会因为"JSON 还没闭合"就自动接下一行 —— 少了反斜杠，第二行会被当成新指令，
#    报 `unknown instruction: "--host",`。⚠️ watcher 服务在 compose 里覆盖了本 CMD。
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--timeout-keep-alive", "75", \
     "--proxy-headers", "--forwarded-allow-ips=*"]

