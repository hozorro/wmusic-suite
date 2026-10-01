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

# 依赖层。（若你用的是 pnpm/yarn，把下面的 package-lock.json 换成对应锁文件）
COPY musicplayer/package.json ./
COPY musicplayer/package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then \
        npm ci; \
    elif [ -f pnpm-lock.yaml ]; then \
        corepack enable pnpm && pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
        corepack enable yarn && yarn install --frozen-lockfile; \
    else \
        echo "!! 找不到锁文件，退回 npm install（建议提交锁文件）" && npm install; \
    fi

COPY musicplayer/ .

# 构建期注入运行时配置（Vite 会自动把 VITE_ 前缀变量打进包里）
ARG PLAYER_BASE=/
ARG VITE_API_BASE=/api
ARG VITE_MEDIA_BASE=/media
ARG VITE_ARTWORK_BASE=/artwork
ARG VITE_ENABLE_PWA=true
ENV PLAYER_BASE=${PLAYER_BASE} \
    VITE_API_BASE=${VITE_API_BASE} \
    VITE_MEDIA_BASE=${VITE_MEDIA_BASE} \
    VITE_ARTWORK_BASE=${VITE_ARTWORK_BASE} \
    VITE_ENABLE_PWA=${VITE_ENABLE_PWA}
RUN --mount=type=cache,target=/root/.npm \
    npm run build -- --base="${PLAYER_BASE}"

# ============================= Stage 2: musicman ============================
FROM node:${NODE_VERSION}-alpine AS build-man
WORKDIR /app

COPY musicman/package.json ./
COPY musicman/package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then \
        npm ci; \
    elif [ -f pnpm-lock.yaml ]; then \
        corepack enable pnpm && pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
        corepack enable yarn && yarn install --frozen-lockfile; \
    else \
        echo "!! 找不到锁文件，退回 npm install（建议提交锁文件）" && npm install; \
    fi

COPY musicman/ .

ARG MAN_BASE=/admin/
ARG VITE_API_BASE=/api
ARG VITE_MEDIA_BASE=/media
ARG VITE_ARTWORK_BASE=/artwork
ENV MAN_BASE=${MAN_BASE} \
    VITE_API_BASE=${VITE_API_BASE} \
    VITE_MEDIA_BASE=${VITE_MEDIA_BASE} \
    VITE_ARTWORK_BASE=${VITE_ARTWORK_BASE}
RUN --mount=type=cache,target=/root/.npm \
    npm run build -- --base="${MAN_BASE}"

# ============================== Stage 3: nginx ==============================
FROM nginx:${NGINX_VERSION}-alpine

RUN rm -rf /usr/share/nginx/html/* \
    && mkdir -p /usr/share/nginx/html/player /usr/share/nginx/html/man \
    && mkdir -p /music /var/lib/musicbase/artwork /var/cache/nginx/client_temp

COPY docker/nginx/nginx.conf        /etc/nginx/nginx.conf
COPY docker/nginx/mime.types.audio  /etc/nginx/mime.types.audio
COPY docker/nginx/conf.d/           /etc/nginx/conf.d/
COPY --from=build-player /app/dist/ /usr/share/nginx/html/player/
COPY --from=build-man   /app/dist/ /usr/share/nginx/html/man/

# 静态资源统一放开读权限（容器内 nginx 以非 root 运行）
RUN chmod -R a+rX /usr/share/nginx/html

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]

