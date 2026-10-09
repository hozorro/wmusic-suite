# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# musicbase-web
#   一个镜像里完成 musicplayer(PWA) 与 musicman(管理后台) 的构建，
#   产物由 nginx 统一托管，并对 /api 做反向代理。
#
# 构建上下文必须是 umbrella 仓库根目录：
#   docker build -f docker/web/Dockerfile -t musicbase/web:latest .
# ---------------------------------------------------------------------------
ARG NODE_VERSION=22
ARG NGINX_VERSION=1.27

# ============================ Stage 1: musicplayer ==========================
FROM node:${NODE_VERSION}-alpine AS build-player
WORKDIR /app

# ---------------------------------------------------------------------------
# 依赖层（musicplayer）
# ---------------------------------------------------------------------------
ARG YARN_VERSION=1.22.22
ENV YARN_CACHE_FOLDER=/root/.cache/yarn
COPY musicplayer/package.json musicplayer/yarn.lock ./
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/yarn \
    set -eu; \
    if command -v yarn >/dev/null 2>&1; then \
        echo "[player] 使用基础镜像自带 yarn（不自作主张覆盖）"; \
    else \
        echo "[player] 基础镜像不含 yarn，全局安装 ${YARN_VERSION}"; \
        npm i -g "yarn@${YARN_VERSION}" --no-fund --no-audit >/dev/null; \
    fi; \
    yv="$(yarn --version)"; \
    case "${yv}" in \
        1.*) : ;; \
        *) echo "构建失败: 需要 yarn 1.x（yarn.lock 是 v1 格式），当前是 ${yv}" >&2; exit 1 ;; \
    esac; \
    [ "${yv}" = "${YARN_VERSION}" ] \
        || echo "[player] 提示: 自带 yarn ${yv}，与 YARN_VERSION=${YARN_VERSION} 不同（同为 1.x，不影响 v1 lockfile）"; \
    echo "[player] yarn ${yv}，锁文件: yarn.lock"; \
    yarn install --frozen-lockfile --non-interactive --network-timeout 600000

COPY musicplayer/ .

# ---------------------------------------------------------------------------
# musicplayer 构建期变量
# ---------------------------------------------------------------------------
ARG PLAYER_BASE=/
ARG VITE_CLIENT_TYPE=player
ARG VITE_TOKEN_PREFIX=player_
ENV VITE_CLIENT_TYPE=${VITE_CLIENT_TYPE} \
    VITE_TOKEN_PREFIX=${VITE_TOKEN_PREFIX}

RUN --mount=type=cache,target=/root/.npm \
    set -eu; \
    [ -n "${VITE_CLIENT_TYPE}" ] \
        || { echo "构建失败: VITE_CLIENT_TYPE 为空，请求头 X-Client-Type 会变成 undefined" >&2; exit 1; }; \
    [ -n "${VITE_TOKEN_PREFIX}" ] \
        || { echo "构建失败: VITE_TOKEN_PREFIX 为空" >&2; exit 1; }; \
    npm run build -- --base="${PLAYER_BASE}"; \
    grep -qF 'src="/assets/' dist/index.html \
        || { echo "构建失败: 产物 index.html 的资源前缀不是 /，说明 --base 没生效" >&2; exit 1; }

# ============================= Stage 2: musicman ============================
FROM node:${NODE_VERSION}-alpine AS build-man
WORKDIR /app

ARG YARN_VERSION=1.22.22
ENV YARN_CACHE_FOLDER=/root/.cache/yarn
COPY musicman/package.json musicman/yarn.lock ./
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/yarn \
    set -eu; \
    if command -v yarn >/dev/null 2>&1; then \
        echo "[man] 使用基础镜像自带 yarn（不自作主张覆盖）"; \
    else \
        echo "[man] 基础镜像不含 yarn，全局安装 ${YARN_VERSION}"; \
        npm i -g "yarn@${YARN_VERSION}" --no-fund --no-audit >/dev/null; \
    fi; \
    yv="$(yarn --version)"; \
    case "${yv}" in \
        1.*) : ;; \
        *) echo "构建失败: 需要 yarn 1.x（yarn.lock 是 v1 格式），当前是 ${yv}" >&2; exit 1 ;; \
    esac; \
    [ "${yv}" = "${YARN_VERSION}" ] \
        || echo "[man] 提示: 自带 yarn ${yv}，与 YARN_VERSION=${YARN_VERSION} 不同（同为 1.x，不影响 v1 lockfile）"; \
    echo "[man] yarn ${yv}，锁文件: yarn.lock"; \
    yarn install --frozen-lockfile --non-interactive --network-timeout 600000

COPY musicman/ .

# ---------------------------------------------------------------------------
# musicman 构建期变量
# ---------------------------------------------------------------------------
ARG MAN_BASE=/admin/
ARG VITE_CLIENT_TYPE=admin
ARG VITE_TOKEN_PREFIX=admin_
ARG VITE_BASE_URL=/api/
ENV VITE_CLIENT_TYPE=${VITE_CLIENT_TYPE} \
    VITE_TOKEN_PREFIX=${VITE_TOKEN_PREFIX} \
    VITE_BASE_URL=${VITE_BASE_URL}

RUN --mount=type=cache,target=/root/.npm \
    set -eu; \
    [ -n "${VITE_CLIENT_TYPE}" ] \
        || { echo "构建失败: VITE_CLIENT_TYPE 为空" >&2; exit 1; }; \
    [ -n "${VITE_TOKEN_PREFIX}" ] \
        || { echo "构建失败: VITE_TOKEN_PREFIX 为空" >&2; exit 1; }; \
    [ -n "${VITE_BASE_URL}" ] \
        || { echo "构建失败: VITE_BASE_URL 为空，封面 URL 会退化成 undefinedartwork/..." >&2; exit 1; }; \
    case "${VITE_BASE_URL}" in \
        */) : ;; \
        *) echo "构建失败: VITE_BASE_URL 必须以 / 结尾，当前为 ${VITE_BASE_URL}" >&2; exit 1 ;; \
    esac; \
    npm run build -- --base="${MAN_BASE}"; \
    grep -qF '/admin/assets/' dist/index.html \
        || { echo "构建失败: 产物 index.html 的资源前缀不是 /admin/，说明 --base 没生效" >&2; exit 1; }; \
    if grep -rqF 'undefinedartwork' dist/assets; then \
        echo "构建失败: VITE_BASE_URL 未生效，产物中出现 undefinedartwork 字面量" >&2; \
        exit 1; \
    fi

# ============================== Stage 3: nginx ==============================
FROM nginx:${NGINX_VERSION}-alpine

RUN rm -rf /usr/share/nginx/html/* \
    && rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /usr/share/nginx/html/player /usr/share/nginx/html/man \
    && mkdir -p /music /var/lib/musicbase/artwork /var/cache/nginx/client_temp

COPY docker/nginx/nginx.conf        /etc/nginx/nginx.conf
COPY docker/nginx/mime.types.audio  /etc/nginx/mime.types.audio
COPY docker/nginx/conf.d/           /etc/nginx/conf.d/
COPY --from=build-player /app/dist/ /usr/share/nginx/html/player/
COPY --from=build-man   /app/dist/ /usr/share/nginx/html/man/

# 静态资源统一放开读权限（容器内 nginx 以非 root 运行）
RUN chmod -R a+rX /usr/share/nginx/html

# ---------------------------------------------------------------------------
# 构建期静态自检
RUN set -eu; \
    echo "[nginx] conf.d 内容:"; ls -1 /etc/nginx/conf.d/; \
    [ ! -e /etc/nginx/conf.d/default.conf ] \
        || { echo "构建失败: 基础镜像自带的 /etc/nginx/conf.d/default.conf 仍在，它会成为 80 端口的默认 server，把用 IP 访问的请求全部劫走（403/404）" >&2; exit 1; }; \
    printf 'error_log stderr;\npid /tmp/nginx-mimecheck.pid;\nevents {}\nhttp {\n    include /etc/nginx/mime.types;\n    include /etc/nginx/mime.types.audio;\n}\n' > /tmp/nginx-mimecheck.conf; \
    out="$(nginx -t -c /tmp/nginx-mimecheck.conf 2>&1 || true)"; \
    rm -f /tmp/nginx-mimecheck.conf; \
    dups="$(printf '%s\n' "${out}" | grep -oE 'duplicate extension "[^"]+"' | sort -u || true)"; \
    if [ -n "${dups}" ]; then \
        echo "构建失败: 音频类型表重复定义了官方 /etc/nginx/mime.types 里已有的扩展名：" >&2; \
        echo "${dups}" | sed 's/^/  /' >&2; \
        echo "  下面是 nginx 的原话：" >&2; \
        printf '%s\n' "${out}" | sed 's/^/    | /' >&2; \
        echo "  重复定义不是「后写的覆盖先写的」那么简单（ngx_http_core_module.c 里" >&2; \
        echo "  确实会 type[n].value = content_type，但 nginx 只打一条 warn 就继续跑），" >&2; \
        echo "  结果就是「我改的类型到底生效没有」只能靠猜。修法：删掉 " >&2; \
        echo "  docker/nginx/mime.types.audio 里官方表已有的行 —— 补充表只留官方表没有的。" >&2; \
        exit 1; \
    fi; \
    printf '%s\n' "${out}" | grep -q 'test is successful' \
        || echo "[nginx] 提示: 类型表自检未跑完，已跳过该项（不影响本次构建）：${out}" >&2; \
    echo "[nginx] 构建期静态自检通过：conf.d 干净、音频类型表与官方表无重复"

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]

