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
#
# ⚠️ 锁文件必须【显式写出】，不能用通配符。
#    Docker 的 COPY 一旦通配符匹配不到任何文件，是直接以
#      COPY failed: no source files were specified
#    中断构建，而不是静默跳过。原写法 `COPY musicplayer/package-lock.json* ./`
#    在这里必定失败：两个前端都是 yarn 工程，根本没有 package-lock.json。
#
# ⚠️ yarn 版本显式钉住，不依赖 corepack 的内置默认值。
#    corepack 目前对 yarn 的 default 是 1.22.22（与 v1 lockfile 匹配），
#    但那个值随 corepack 版本变——基础镜像换 node 版本时可能悄悄变成 yarn 4，
#    而 yarn 4 读 v1 lockfile 又带 --frozen-lockfile 会直接报错。
#    两个前端的 yarn.lock 头都是 "# yarn lockfile v1"，没有 packageManager 字段。
#
# 若将来改用 npm / pnpm，这一整块都要改（锁文件名 + 安装命令），
# 不能只改一半——scripts/check.sh 会核对 COPY 的锁文件名与实际存在的是否一致。
# ---------------------------------------------------------------------------
ARG YARN_VERSION=1.22.22
ENV YARN_CACHE_FOLDER=/root/.cache/yarn
COPY musicplayer/package.json musicplayer/yarn.lock ./
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/yarn \
    set -eu; \
    npm i -g "yarn@${YARN_VERSION}" --no-fund --no-audit >/dev/null; \
    echo "[player] yarn $(yarn --version) 锁文件: yarn.lock"; \
    yarn install --frozen-lockfile --non-interactive --network-timeout 600000

COPY musicplayer/ .

# ---------------------------------------------------------------------------
# musicplayer 构建期变量
#
# 只注入源码真正读过的变量（依据：对 wmusicplayer 全仓 grep import.meta.env）：
#   src/apis/index.ts:73    X-Client-Type : import.meta.env.VITE_CLIENT_TYPE || 'player'
#   src/store/auth.ts:17    appType       : import.meta.env.VITE_CLIENT_TYPE
#   src/utilies/auth.ts:1   TOKEN_PREFIX  : import.meta.env.VITE_TOKEN_PREFIX || 'player_'
#
# ⚠️ 为什么必须在构建期给值，而不能靠项目里的 .env.production：
#    根目录 .dockerignore 有 `**/.env.*`，前端的 .env / .env.production 一律
#    进不了构建上下文。镜像里的取值 100% 由本文件决定，没有第二个来源。
#
# ⚠️ 优先级（已实测确认）：Vite 的 loadEnv() 先读 .env 文件，最后遍历
#    process.env 覆盖同名键。所以 Dockerfile 的 ENV 一定赢过仓库里的
#    .env.production——即便以后有人把 env 文件挪进了上下文，也不会出现
#    "两份值打架、谁生效看运气"的情况。
#
# 以下变量【故意不注入】，因为 wmusicplayer 源码里 0 引用（已 grep 全仓）：
#   VITE_API_BASE     —— 只被 vite.config.ts 的 dev server proxy 读取。
#                        生产环境的 API 基址在 src/apis/index.ts 里硬编码为 '/api/'，
#                        由 nginx 同源转发，构建期给不给值都一样。
#   VITE_MEDIA_BASE   —— 无用。封面/音频路径在 src/services/transform.ts 里硬编码 /media/...
#   VITE_ARTWORK_BASE —— 同上，0 引用
#   VITE_ENABLE_PWA   —— 无用。PWA 由 vite.config.ts 的 VitePWA 插件【无条件】启用，
#                        不注入也会正常产出 sw.js / manifest.webmanifest（已实测）
#   VITE_APP_NAME     —— 无用。PWA manifest 里的名字在 vite.config.ts 里写死为 'WMusicPlayer'
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

# 依赖层（musicman）—— 与 build-player 同理，锁文件必须显式写出。
# 详细理由见 Stage 1 的注释；两个前端用同一套 yarn v1 锁文件。
ARG YARN_VERSION=1.22.22
ENV YARN_CACHE_FOLDER=/root/.cache/yarn
COPY musicman/package.json musicman/yarn.lock ./
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/yarn \
    set -eu; \
    npm i -g "yarn@${YARN_VERSION}" --no-fund --no-audit >/dev/null; \
    echo "[man] yarn $(yarn --version) 锁文件: yarn.lock"; \
    yarn install --frozen-lockfile --non-interactive --network-timeout 600000

COPY musicman/ .

# ---------------------------------------------------------------------------
# musicman 构建期变量
#
# 依据：对 wmusicman 全仓 grep import.meta.env。
#   src/apis/index.ts:53,82        X-Client-Type : import.meta.env.VITE_CLIENT_TYPE || 'admin'
#   src/utils/auth.ts:1            TOKEN_PREFIX  : import.meta.env.VITE_TOKEN_PREFIX || 'admin_'
#   src/apis/methods/manage.ts:5   baseURL       : import.meta.env.VITE_BASE_URL   ← 没有兜底
#   src/layout/Main.vue:69 及 views 下 4 个组件   同上，合计 6 处
#
# ⚠️ VITE_BASE_URL 是这里唯一"缺了就直接出故障"的变量，坑值得记住：
#       const baseURL = import.meta.env.VITE_BASE_URL      // manage.ts:5
#       url = baseURL + `artwork/artist/${id}`             // 直接字符串相加，无兜底
#    变量缺失时 Vite 把 import.meta.env.VITE_BASE_URL 替换成 undefined，
#    产物里留下的是字面量 `undefinedartwork/default/...`——管理后台所有封面/图片
#    全部 404 裂图，而且【不报错、不进控制台】，只是静默失效。
#    （已用 --mode 模拟无 .env 环境实建复现：不注入时为 undefinedartwork，
#      注入 /api/ 后变为 "/api/"+`artwork/...`）
#
#    取值要点：
#      * 必须【带结尾斜杠】——它是拿来直接拼字符串的，不是给 URL 构造函数兜底的；
#      * 必须用相对路径 /api/，走 nginx 同源代理。不要填开发机地址：
#        wmusicman/.env.development.local 里的 http://192.168.137.247/api/
#        是 dev server 用的，打进镜像会变成硬编码内网 IP + 跨域请求。
#
# 与 musicplayer 同理，以下变量无需注入：
#   VITE_API_BASE     —— API 基址在 src/apis/index.ts 里硬编码 '/api/'
#   VITE_MEDIA_BASE / VITE_ARTWORK_BASE / VITE_APP_NAME —— 源码里 0 引用
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

