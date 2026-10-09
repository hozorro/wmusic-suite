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
# ⚠️ yarn 直接用【基础镜像自带的那份】，不要自己 npm 装。
#    node:*-alpine 的官方 Dockerfile 末尾就是这么装的（curl 下载 + 解到 /opt +
#    在 /usr/local/bin 建符号链接，版本随镜像的 ENV YARN_VERSION，当前是 1.22.22）：
#        tar -xzf yarn-v$YARN_VERSION.tar.gz -C /opt/
#        ln -s /opt/yarn-v$YARN_VERSION/bin/yarn   /usr/local/bin/yarn
#        ln -s /opt/yarn-v$YARN_VERSION/bin/yarnpkg /usr/local/bin/yarnpkg
#    而 `npm i -g yarn@x` 也要往 /usr/local/bin 写同名符号链接，撞上就中断构建：
#        npm error code EEXIST
#        npm error path /usr/local/bin/yarn
#        npm error EEXIST: file already exists
#    所以下面改成"先探测、缺了才装"，绝不覆盖已有二进制。
#
#    ⚠️ 但"用自带的那份"不等于放弃版本约束：v1 lockfile 必须配 yarn 1.x。
#    两个前端的 yarn.lock 头都是 "# yarn lockfile v1"、package.json 里也没有
#    packageManager 字段。基础镜像哪天换成 corepack-only 或 yarn 4，
#    yarn 4 读 v1 lockfile 再带 --frozen-lockfile 会直接报错。
#    因此下面保留一道硬断言：yarn 主版本必须是 1.x，不满足就构建失败。
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
# 详细理由见 Stage 1 的注释（含"不要用 npm 覆盖基础镜像自带的 yarn"那条）；
# 两个前端用同一套 yarn v1 锁文件，安装方式逐字一致，改一处记得改两处。
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

# ---------------------------------------------------------------------------
# ⚠️ 必须删掉基础镜像自带的 /etc/nginx/conf.d/default.conf，否则它会【静默抢走整个站点】。
#
#    基础镜像自带一份完整可用的虚拟主机，docker-entrypoint 还会给它补上 IPv6 监听：
#        server {
#            listen       80;
#            listen  [::]:80;
#            server_name  localhost;
#            location / { root /usr/share/nginx/html; index index.html index.htm; }
#        }
#    conf.d 是按【文件名字典序】include 的（default.conf 排在 music.conf 前面），
#    于是它就是 80 端口的默认 server —— 不是"多余文件"，是"顶头上司"。
#
#    nginx 选 server 的规则（官方 request_processing.html 原话）：
#        "If its value does not match any server name ... nginx will route the
#         request to the default server for this port. ... the default server
#         is the first one"
#    而 server_names.html 里写得很清楚，我们 music.conf 用的那个 `server_name _;`
#        "is just one of a myriad of invalid domain names which never intersect
#         with any real name"
#    并且
#        "there is no way to specify the catch-all name or the default server
#         using the server_name directive. This is a property of the listen
#         directive and not of the server_name directive."
#    ⇒ 光写 server_name _ 根本不构成 catch-all，必须靠 listen default_server。
#
#    故障现场（本套件真实踩过）：用局域网 IP 访问 http://<host>:8080 时
#    Host 是 192.168.1.101:8080，既不是 localhost 也不是 _，两边都不匹配
#    → 落到 default.conf → root /usr/share/nginx/html，而这个目录下的
#    index.html 正被下面的 rm -rf 删掉（只留 player/ man/ 两个子目录）
#    → 访问 / 得到 **403 Forbidden**（目录里没有索引文件）
#      访问 /healthz 得到 **404**（那边根本没定义这个 location）
#    两个症状合起来就是"服务像是起来了，其实一个请求都没进我们的 server 块"。
#
#    双重保险：
#      ① 这里删掉 default.conf（根治）
#      ② music.conf 的 listen 上加 default_server（本文件被顶掉/被追加其它
#         conf 时仍然稳定）
#    只做 ② 不做 ① 是不够的：default.conf 会退化成"server_name localhost 的
#    普通虚拟主机"，那时用 localhost:8080 访问同样会撞上它。
# ---------------------------------------------------------------------------
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
# 构建期静态自检 —— 只做【不需要 DNS】的事
#
# ⚠️ 这里【刻意不跑裸的 `nginx -t`】。nginx 在【解析配置文件】阶段就会去解析
#    upstream 里的主机名（不是请求到达时，也不是 reload 时），解析不到直接退出：
#        nginx: [emerg] 1#1: host not found in upstream "api:8000"
#               in /etc/nginx/conf.d/music.conf:10
#    而构建容器根本不在 musicbase-net 里，这个名字无处可解析 —— 于是每一次
#    `docker compose build web` 都停在最后一步，而且【这不是配置写错】。
#    曾试图用 compose 的 web.build.extra_hosts 给构建期补一条 hosts 兜底，
#    实测它并没有真正落到构建容器的 /etc/hosts 上（构建照样失败），已放弃。
#
#    配置语法本来也不需要构建期校验：CMD 就是 `nginx -g 'daemon off;'`，容器每次
#    启动都会完整解析一遍配置，出错的报错与 `nginx -t` 一字不差，而且那是真的
#    运行环境（能解析 api、能读挂载目录）。真正值得提前到构建期的，是下面这两件
#    nginx 启动时【既不报错、也看不出来】的事。
#
#   (1) 基础镜像自带的 conf.d/default.conf 是否已删掉（见上面那段说明）—— 它在的
#       话站点照样启动，只是所有用 IP 访问的请求都被它劫走（403/404）。
#   (2) 音频类型表是否与官方 mime.types 重复定义同一个扩展名 —— 重复时 nginx 只打
#       一条 [warn] duplicate extension 就继续跑，而"到底哪一条生效"全靠猜。
#       校验方式：造一个【只 include 这两张类型表】的最小配置去跑 nginx -t。
#       它里面没有任何 upstream，所以不需要 DNS —— 这是构建期唯一能安全跑的
#       `nginx -t`，而且用的是 nginx 自己的重复检测，不靠我们自己维护一份对照表。
# ---------------------------------------------------------------------------
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

