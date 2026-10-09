#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 构建前置自检：确保 umbrella 仓库结构完整、依赖清单到位、.env 已配置
#   make build 会自动先跑它
# ---------------------------------------------------------------------------
set -Eeuo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
err()  { echo "  ✗ $*"; fail=1; }
ok()   { echo "  ✓ $*"; }

# 取 compose 里某个服务的整段（`  <svc>:` 到下一个服务或文件末尾）
# 顶格行（`services:` / `networks:` / `volumes:` 等顶层键）视为服务段结束 ——
# 最后一个服务段后面就是顶层键，不这样切会把 networks/volumes 段也算进去。
svc_block() {
    awk -v want="$1" '
        /^[^[:space:]#]/ { inblk = 0 }
        /^  [A-Za-z0-9_-]+:/ {
            svc = $0; sub(/:.*/, "", svc); gsub(/^[ \t]+|[ \t]+$/, "", svc)
            inblk = (svc == want); next
        }
        inblk { print }
    ' docker-compose.yml
}

# 取某个服务 volumes: 段下的挂载行（已剥注释与引号）
# 必须限定在 volumes 段内，否则 ports: 里的 "8080:80" 会被当成挂载行。
svc_volumes() {
    svc_block "$1" | awk '
        /^    [a-zA-Z_]/ { invol = 0 }
        /^    volumes:/   { invol = 1; next }
        invol && /^      -/ { print }
    ' | sed 's/#.*//' | tr -d "\"'"
}

echo "== 目录结构"
for d in musicbase musicplayer musicman docker scripts; do
    [ -d "$d" ] && ok "$d/" || err "缺少目录 $d（先执行 ./scripts/init-umbrella.sh）"
done

echo "== 构建上下文必需文件"
[ -f docker-compose.yml ]      && ok "docker-compose.yml"      || err "缺少 docker-compose.yml"
[ -f docker/backend/Dockerfile ] && ok "docker/backend/Dockerfile" || err "缺少后端 Dockerfile"
[ -f docker/web/Dockerfile ]     && ok "docker/web/Dockerfile"     || err "缺少前端 Dockerfile"

echo "== 后端依赖清单"
if [ -f musicbase/pyproject.toml ]; then
    ok "musicbase/pyproject.toml"
else
    err "缺少 musicbase/pyproject.toml"
fi
if [ -s musicbase/uv.lock ]; then
    ok "musicbase/uv.lock"
elif [ -s musicbase/requirements.txt ]; then
    ok "musicbase/requirements.txt"
else
    err "musicbase 缺少 uv.lock 或 requirements.txt"
    echo "     修复：cd musicbase && uv lock     # 或 pip freeze > requirements.txt"
fi

echo "== 前端依赖清单与锁文件 COPY"
# COPY 的锁文件名必须与实际存在的锁文件一致。两个方向都会出事：
#   * 名字对不上     -> 镜像里没有锁文件，安装退化成 npm install，依赖版本不可复现；
#   * 用通配符且没匹配到 -> Docker 直接以
#                          COPY failed: no source files were specified
#                        中断构建（不是静默跳过）。
# 这条断言就是这两个坑的守卫：上游换了包管理器（比如从 yarn 换到 pnpm），
# 这里会立刻报出来，而不是等到 docker build 失败或线上依赖漂移。
df_copy="$(sed 's/#.*//' docker/web/Dockerfile 2>/dev/null | grep -E '^[[:space:]]*COPY' || true)"
for p in musicplayer musicman; do
    if [ -f "$p/package.json" ]; then ok "$p/package.json"; else err "缺少 $p/package.json"; continue; fi

    lock=""
    for cand in package-lock.json pnpm-lock.yaml yarn.lock; do
        if [ -s "$p/$cand" ]; then lock="$cand"; break; fi
    done
    if [ -z "$lock" ]; then
        err "$p 缺少锁文件"
        echo "     修复：cd $p && yarn install（或 npm install --package-lock-only）"
        continue
    fi
    ok "$p/$lock"

    if printf '%s\n' "$df_copy" | grep -qF "$p/$lock"; then
        ok "docker/web/Dockerfile 已显式 COPY $p/$lock"
    else
        err "docker/web/Dockerfile 没有显式 COPY $p/$lock"
        echo "     COPY 的名字与实际不符：轻则镜像里没有锁文件、安装退化成 npm install"
        echo "     （依赖版本不可复现），重则通配符匹配不到文件、构建直接失败。"
    fi
done

echo "== 前端依赖安装方式（yarn 要只用基础镜像自带的那份）"
# node:*-alpine 自带 yarn：官方 Dockerfile 把它解到 /opt，再在 /usr/local/bin 建两个
# 符号链接（yarn / yarnpkg）。此时若再 `npm i -g yarn@x`，npm 也往同一路径写符号链接，
# 撞上就是构建中断（实测 node:22-alpine）：
#     npm error code EEXIST
#     npm error path /usr/local/bin/yarn
#     npm error EEXIST: file already exists
# 正确做法：先 command -v yarn 探测，缺了才装；并断言主版本是 1.x（v1 lockfile 要求）。
if [ ! -f docker/web/Dockerfile ]; then
    err "缺少 docker/web/Dockerfile"
else
    web_inst="$(sed 's/#.*//' docker/web/Dockerfile)"

    # 逐 stage 检查：任何含 yarn install 的 stage 都必须同时有 command -v yarn 守卫。
    # 不分 stage 地全局 grep 会漏掉"只改了一个 stage"的情况。
    if printf '%s\n' "$web_inst" | awk '
            /^FROM / { if (s ~ /yarn install/ && s !~ /command -v yarn/) bad = 1; s = ""; next }
            { s = s " " $0 }
            END { if (s ~ /yarn install/ && s !~ /command -v yarn/) bad = 1; exit (bad ? 1 : 0) }
        '; then
        ok "各 stage 的 yarn 都有 command -v 守卫，不会覆盖基础镜像自带的那份"
    else
        err "有 stage 无守卫地安装 yarn：会撞上基础镜像 /usr/local/bin/yarn 的符号链接，npm 报 EEXIST"
        echo "     修复：if command -v yarn >/dev/null 2>&1; then 直接用; else npm i -g yarn@x; fi"
    fi

    if printf '%s\n' "$web_inst" | grep -qE '^[[:space:]]*1\.\*\)'; then
        ok "有 yarn 主版本守卫（主版本不是 1.x 就构建失败）"
    else
        err "缺少 yarn 主版本守卫：两个前端的 yarn.lock 是 v1 格式，换成 yarn 4 会直接报错"
    fi
fi

echo "== 前端构建期变量（web Dockerfile）"
# 大前提：两个前端仓库的 .env* 被 .dockerignore 的 `**/.env.*` 挡在构建上下文之外，
# 所以镜像里的 VITE_ 取值【只有一个来源】—— docker/web/Dockerfile。
# 一旦这里配错，本地 npm run build 是对的、容器里是错的，属于最难查的一类问题。
if [ ! -f docker/web/Dockerfile ]; then
    err "缺少 docker/web/Dockerfile"
else
    # 先剥注释再匹配：Dockerfile 的说明注释里会大段提到这些变量名，不剥必然误报。
    web_df="$(sed 's/#.*//' docker/web/Dockerfile)"

    # --- A) 不该注入的：在两个前端源码里 grep 结果都是 0 ---
    dead_hit=""
    for dead in VITE_API_BASE VITE_MEDIA_BASE VITE_ARTWORK_BASE VITE_ENABLE_PWA VITE_APP_NAME; do
        if printf '%s\n' "$web_df" | grep -q "$dead"; then
            dead_hit="$dead_hit $dead"
        fi
    done
    if [ -n "$dead_hit" ]; then
        err "docker/web/Dockerfile 仍在注入源码里 0 引用的变量:$dead_hit"
        echo "     其中 VITE_API_BASE 最容易被误解：它只服务 vite.config.ts 的 dev server proxy，"
        echo "     生产环境的 API 基址在 src/apis/index.ts 里硬编码为 '/api/'，由 nginx 同源转发。"
    else
        ok "未注入无引用的前端变量（API/MEDIA/ARTWORK_BASE、ENABLE_PWA、APP_NAME 已剔除）"
    fi

    # --- B) 该注入的：两个应用各自的身份常量 ---
    for kv in "VITE_CLIENT_TYPE=player" "VITE_TOKEN_PREFIX=player_" \
              "VITE_CLIENT_TYPE=admin"  "VITE_TOKEN_PREFIX=admin_" \
              "VITE_BASE_URL=/api/"; do
        if printf '%s\n' "$web_df" | grep -qF "$kv"; then
            ok "已注入 $kv"
        else
            err "docker/web/Dockerfile 缺少 $kv"
        fi
    done

    # --- C) VITE_BASE_URL 的两道保险 ---
    # 它和别的变量不同：源码里是 baseURL + `artwork/...` 直接字符串相加，没有兜底。
    if printf '%s\n' "$web_df" | grep -qE 'case[^;]*VITE_BASE_URL'; then
        ok "有 VITE_BASE_URL 结尾斜杠的构建期守卫"
    else
        err "缺少 VITE_BASE_URL 尾斜杠守卫：少了尾斜杠会拼出 /apiartwork/... 而非 /api/artwork/..."
    fi
    if printf '%s\n' "$web_df" | grep -qF "undefinedartwork"; then
        ok "有产物级断言：出现 undefinedartwork 立即构建失败"
    else
        err "缺少产物断言 undefinedartwork：VITE_BASE_URL 失效时不报错，只会静默裂图"
    fi

    # --- D) compose 里不残留（避免与 Dockerfile 形成第二份副本）---
    compose_code="$(sed 's/#.*//' docker-compose.yml)"
    cy_hit=""
    for dead in VITE_API_BASE VITE_MEDIA_BASE VITE_ARTWORK_BASE VITE_ENABLE_PWA; do
        if printf '%s\n' "$compose_code" | grep -q "$dead"; then
            cy_hit="$cy_hit $dead"
        fi
    done
    if [ -n "$cy_hit" ]; then
        err "docker-compose.yml 仍在透传前端变量:$cy_hit（应只在 Dockerfile 里定义）"
    else
        ok "compose 不再透传前端 VITE_ 变量"
    fi

    # --- E) 源码级交叉核对：上游加了新变量、或变量名拼错，这里都会炸 ---
    if [ -d musicplayer/src ] && [ -d musicman/src ]; then
        # 已知的上游缺陷白名单：报 `!` 而不是 `✗`，因为它不影响构建结果，但必须让人看见。
        #   wmusicman/src/store/auth.ts:17 写的是 VITE_APP_TYPE，
        #   而 wmusicplayer 同一行写的是 VITE_CLIENT_TYPE。前者在整个仓库里
        #   没有任何定义处，值恒为 undefined（好在目前没有消费方）。
        #   上游改正后删掉本行，检查会自动转为通过。
        known_upstream_bugs="VITE_APP_TYPE"

        for spec in "musicplayer:VITE_CLIENT_TYPE VITE_TOKEN_PREFIX" \
                    "musicman:VITE_CLIENT_TYPE VITE_TOKEN_PREFIX VITE_BASE_URL"; do
            p="${spec%%:*}"
            allowed="${spec#*:}"
            # ★ 必须先剔掉注释行：wmusicman/src/apis/methods/manage.ts 里有一行
            #   被注释掉的 `// const baseSrcURL = import.meta.env.VITE_BASE_SRC_URL;`
            #   不剔就会把它当成真实引用，报出一个假阳性。
            used="$(grep -rn --include=*.ts --include=*.vue --include=*.js -I \
                        -E "import\.meta\.env\.VITE_|import\.meta\.env\[['\"]VITE_" "$p/src" 2>/dev/null \
                    | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)" \
                    | grep -ohE "VITE_[A-Z0-9_]+" | sort -u | tr '\n' ' ' || true)"

            miss=""; extra=""; known=""
            for v in $used; do
                case " $allowed " in
                    *" $v "*) ;;
                    *) case " $known_upstream_bugs " in
                           *" $v "*) known="$known $v" ;;
                           *)         miss="$miss $v" ;;
                       esac ;;
                esac
            done
            for v in $allowed; do
                case " $used " in *" $v "*) ;; *) extra="$extra $v" ;; esac
            done

            if [ -n "$miss" ]; then
                err "$p 源码读取了镜像未注入的变量:$miss"
                echo "     若属上游新增，请补进 docker/web/Dockerfile；若属拼错，改源码而不是"
                echo "     注入错名——注入一个拼错的变量名只会把 bug 掩盖住。"
                for v in $miss; do
                    grep -rn --include=*.ts --include=*.vue --include=*.js -I "$v" "$p/src" 2>/dev/null \
                        | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)" | sed 's/^/       /' | head -3
                done
            else
                ok "$p：源码读取的 VITE_ 变量已全部注入"
            fi
            if [ -n "$extra" ]; then
                err "$p 注入了源码没有读取的变量:$extra"
            fi
            if [ -n "$known" ]; then
                echo "  ! $p 源码里有拼错的变量名$known（上游缺陷，非本套件配置问题）："
                for v in $known; do
                    grep -rn --include=*.ts --include=*.vue -I "$v" "$p/src" 2>/dev/null \
                        | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)" | sed 's/^/       /' | head -2
                done
                echo "     值恒为 undefined。当前无消费方，暂不阻塞构建。"
            fi
        done
    else
        echo "  ! 前端子项目未挂载（musicplayer/src、musicman/src 不存在），跳过源码级交叉核对"
    fi
fi

echo "== nginx 音频类型表（缺失会让 flac 变成 octet-stream 而播放失败）"
if [ -f docker/nginx/mime.types.audio ]; then ok "docker/nginx/mime.types.audio 存在"; else err "缺少 docker/nginx/mime.types.audio"; fi
grep -q "mime.types.audio" docker/nginx/nginx.conf \
    && ok "nginx.conf 已 include 音频补充表" \
    || err "nginx.conf 未 include mime.types.audio"
grep -q "^ *audio/flac " docker/nginx/mime.types.audio \
    && ok "audio/flac 已映射" || err "mime.types.audio 里没有 audio/flac"
grep -q "mime.types.audio" docker/web/Dockerfile \
    && ok "Dockerfile 已 COPY 音频补充表" || err "web Dockerfile 未 COPY mime.types.audio"
# 先剥掉 nginx 注释再匹配，否则说明文档里的 `types {}` 字样会造成误报
if sed 's/#.*//' docker/nginx/conf.d/*.conf | grep -qE "types[[:space:]]*\{[[:space:]]*\}"; then
    err "存在空的 types {} 块，会清空该 location 的整张类型表"
else
    ok "未发现清空类型表的空 types {} 块"
fi
# ---------------------------------------------------------------------------
# 补充表只能写【官方表没有的】扩展名。
#
# 重复定义的后果不是"更明确"，而是：nginx 每次启动刷一条
#     [warn] duplicate extension "m4a", content type: "audio/x-m4a",
#            previous content type: "audio/x-m4a" in /etc/nginx/mime.types.audio:26
# 源码里重复项确实会覆盖前一条（ngx_http_core_module.c: type[n].value = content_type），
# 但只打一条 warn 就继续跑 —— "我改的类型生效没有"只能靠猜。这条断言就是钉这个。
#
# 官方表清单（nginx:1.27-alpine，逐字核对过官方 conf/mime.types）：
#   audio/midi mid midi kar;   audio/mpeg mp3;   audio/ogg ogg;
#   audio/x-m4a m4a;           audio/x-realaudio ra;
#   application/vnd.apple.mpegurl m3u8;
# 注意 m3u8 在 application/ 段里，很容易看漏 —— 本套件就漏过一次。
# ---------------------------------------------------------------------------
OFFICIAL_MIME_EXTS="mid midi kar mp3 ogg m4a ra m3u8"
mime_exts="$(sed 's/#.*//' docker/nginx/mime.types.audio \
    | awk 'NF > 1 { for (i = 2; i <= NF; i++) { x = $i; gsub(/;/, "", x); if (x != "") print x } }')"
self_dup="$(printf '%s\n' "${mime_exts}" | sort | uniq -d | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
dup_official=""
for e in ${mime_exts}; do
    case " ${OFFICIAL_MIME_EXTS} " in
        *" ${e} "*) dup_official="${dup_official}${dup_official:+, }${e}" ;;
    esac
done
if [ -n "${self_dup}" ]; then
    err "mime.types.audio 内部重复定义了: ${self_dup}（后写的会覆盖先写的，但会打 duplicate extension 警告）"
else
    ok "mime.types.audio 内部无重复扩展名"
fi
if [ -n "${dup_official}" ]; then
    err "mime.types.audio 重复了官方 mime.types 已有的扩展名: ${dup_official}
       → nginx 每次启动都会打 [warn] duplicate extension（本套件踩过 m4a / m3u8），
         构建期的类型表自检也会直接失败。删掉它们，只补官方表没有的后缀。"
else
    ok "mime.types.audio 只补官方表缺失的扩展名（无 m4a / m3u8 之类重复）"
fi
# 构建期的等价护栏（那条是拿真 nginx 跑一个只含类型表的最小配置，不需要 DNS）
sed 's/#.*//' docker/web/Dockerfile | grep -qE 'nginx[[:space:]]+-t[[:space:]]+-c' \
    && ok "web Dockerfile 用「仅含类型表的最小配置」跑 nginx -t（不依赖 DNS，能抓 duplicate extension）" \
    || err "web Dockerfile 缺少类型表重复扩展名的构建期自检（别等 nginx 每次启动刷警告才发现）"

echo "== nginx 虚拟主机选择（基础镜像的 default.conf 会静默抢走整个站点）"
# nginx:alpine 自带 /etc/nginx/conf.d/default.conf：listen 80 + server_name localhost
# + root /usr/share/nginx/html。而 conf.d 是按文件名字典序 include 的，
# default.conf 排在 music.conf 之前，于是它就是 80 端口的【默认 server】。
# 用 IP 访问时 Host 匹配不上任何 server_name -> 落到 default.conf -> root 指向
# 已被清空的 /usr/share/nginx/html -> "/" 报 403、"/healthz" 报 404。
# 先剥掉注释再匹配：本套件的 Dockerfile/conf 里大量注释在解释这同一件事，
# 不剥的话断言会匹配到注释文字而变成空转（反向验证时踩到过）。
sed 's/#.*//' docker/web/Dockerfile | grep -qE 'rm[[:space:]]+-f[[:space:]]+/etc/nginx/conf\.d/default\.conf' \
    && ok "web Dockerfile 已删除基础镜像自带的 conf.d/default.conf" \
    || err "web Dockerfile 未删除 /etc/nginx/conf.d/default.conf：它会是 80 端口的默认 server，用 IP 访问得到 403/404"
n_default=$(sed 's/#.*//' docker/nginx/conf.d/music.conf | grep -cE '^[[:space:]]*listen[[:space:]]+.*default_server' || true)
n_listen=$(sed 's/#.*//' docker/nginx/conf.d/music.conf | grep -cE '^[[:space:]]*listen[[:space:]]+' || true)
if [ "${n_default}" -ge 2 ]; then
    ok "music.conf 的 listen 已声明 default_server（IPv4 + IPv6 各一条）"
elif [ "${n_default}" -eq 1 ]; then
    echo "  ! music.conf 只有 1 条 listen 带 default_server（共 ${n_listen} 条），IPv6 那条会退化成非默认 server"
else
    err "music.conf 的 listen 上没有 default_server —— server_name _ 并不构成 catch-all"
fi
n_conf=$(ls docker/nginx/conf.d/*.conf 2>/dev/null | wc -l | tr -d ' ')
if [ "${n_conf}" -eq 1 ]; then
    ok "conf.d 只有 1 个站点配置，不存在第二个 server 争抢默认 server"
else
    echo "  ! conf.d 下有 ${n_conf} 个 .conf：确认只有一个写了 default_server（同一端口重复声明会让 nginx 起不来）"
fi
# 构建期【不该】跑裸的 nginx -t —— 它在构建期必然失败，而且不是配置错误：
# nginx 在解析配置阶段就解析 upstream 里的主机名，而构建容器不在 musicbase-net 里，
# 于是每次 build 都以 [emerg] host not found in upstream "api:8000" 结束（真实踩过）。
# 曾用 compose 的 web.build.extra_hosts 试图补一条构建期 hosts，实测没落到构建容器
# 上，遂放弃。现在的分工：
#   * 构建期只做不需要 DNS 的静态自检（default.conf 已删 + 类型表无重复扩展名）
#   * 配置语法交给 nginx 自己在容器启动时校验（报错与 nginx -t 一字不差）
naive_t=0
sed 's/#.*//' docker/web/Dockerfile | grep -qE 'nginx[[:space:]]+-t[[:space:]]*$' \
    && naive_t=1
if [ "${naive_t}" = "1" ]; then
    err "web Dockerfile 在构建期跑了裸的 nginx -t：构建期没有 api 容器，
       它必然以 [emerg] host not found in upstream \"api:8000\" 结束整个构建 ——
       这不是配置错误，是「构建环境 ≠ 运行环境」。构建期请只跑不碰 upstream 的检查。
       （要校验语法又不想等启动：把它拆成"仅含类型表的最小配置"那种 nginx -t -c）"
else
    ok "构建期没有裸的 nginx -t（改为不需要 DNS 的静态自检）"
fi
if svc_block web | sed 's/#.*//' | grep -qE '^[[:space:]]*extra_hosts:'; then
    err "web 段还留着 extra_hosts：构建期已不再跑会碰 upstream 的 nginx -t，这条是死配置
       （实测 build.extra_hosts 也没落到构建容器的 /etc/hosts 上），留着会让人
       误以为护栏还在。删掉它。"
else
    ok "web 不再依赖 extra_hosts 兜底"
fi

echo "== API 反代前缀（前端 /api -> 后端 /api/v1）"
# 前端 baseURL='/api/'（两个项目一样），后端路由挂在 main.py 的 include_router(prefix=...)。
# 两边对不上就是"页面能打开、一操作就 404"，而且日志里只有后端 404，很容易查错方向。
API_PREFIX=""
if [ -f musicbase/app/main.py ]; then
    API_PREFIX=$(sed 's/#.*//' musicbase/app/main.py \
        | grep -oE 'include_router\(api_router[^)]*prefix="[^"]+"' \
        | sed -E 's/.*prefix="([^"]+)"$/\1/' | tail -n 1 || true)
fi
if [ -z "${API_PREFIX}" ]; then
    echo "  ! 读不到 musicbase/app/main.py 里 include_router(api_router, prefix=...) ，跳过反代前缀核对"
else
    ok "后端 api_router 挂在 ${API_PREFIX}（musicbase/app/main.py）"
    sed 's/#.*//' docker/nginx/conf.d/music.conf | grep -qF "proxy_pass http://musicbase_api${API_PREFIX}/;" \
        && ok "nginx 把 /api/ 反代到 ${API_PREFIX}/，前缀对得上" \
        || err "nginx 的 /api/ 没有反代到 ${API_PREFIX}/：前端请求 /api/auth/login，后端却在 ${API_PREFIX}/auth/login，全站 API 404"
    # 前端 dev server 的 rewrite 是同一份契约，三方（前端 dev / nginx / 后端）要一致
    for p in musicplayer musicman; do
        [ -f "$p/vite.config.ts" ] || continue
        grep -qF "replace(/^\\/api/, '${API_PREFIX}')" "$p/vite.config.ts" \
            && ok "$p 的 dev proxy rewrite 与后端前缀一致" \
            || echo "  ! $p/vite.config.ts 的 rewrite 与 ${API_PREFIX} 对不上，确认是刻意改过"
    done
fi

echo "== 静态分发路径（音频 /music internal vs 封面 /media public）"
# 读 nginx 里所有 `location ^~ /xxx/` 及其中是否标了 internal
# ⚠️ 必须在块结束时清空 cur：`location = /50x.html { ... internal; }` 里那个
#    internal 不属于任何 ^~ location，不问青红皂白地算给"上一个"会把
#    /media/ 误判成 internal（本断言第一次跑就踩了这个坑）。
LOCS=$(awk '
    /^[[:space:]]*location[[:space:]]+\^~[[:space:]]+/ {
        l = $0
        sub(/^[[:space:]]*location[[:space:]]+\^~[[:space:]]+/, "", l)
        sub(/[[:space:]]*\{.*$/, "", l)
        cur = l; seen[l] = 1; next
    }
    /^[[:space:]]*internal;[[:space:]]*$/ { if (cur != "") intern[cur] = 1 }
    /^[[:space:]]*\}[[:space:]]*$/ { cur = "" }
    END { for (k in seen) print k "\t" ((k in intern) ? "internal" : "public") }
' docker/nginx/conf.d/music.conf | sort)

# 后端拼的 X-Accel 前缀（compose 里那个变量）
SP=$(sed -n 's/^[[:space:]]*MUSIC_STATIC_PREFIX:[[:space:]]*\([^[:space:]#]*\).*/\1/p' docker-compose.yml | head -n 1 | tr -d '"')
case "${SP}" in
    "") err "compose 里没有 MUSIC_STATIC_PREFIX（后端默认值是不带结尾斜杠的 /music，会拼出 /musicArtist/...）" ;;
    /*/) ok "MUSIC_STATIC_PREFIX=${SP}（前后都有斜杠）" ;;
    *)   err "MUSIC_STATIC_PREFIX=${SP} 没有以 / 结尾：后端的 inner = PREFIX + track_path 是纯字符串相加，会拼成 ${SP}Artist/Album/a.flac" ;;
esac
if [ -n "${SP}" ]; then
    if printf '%s\n' "${LOCS}" | grep -qF "$(printf '%s\tinternal' "${SP}")"; then
        ok "音乐库前缀 ${SP} 有对应的 internal location（X-Accel 落点存在）"
    else
        err "music.conf 里没有 ${SP} 的 internal location：X-Accel-Redirect 找不到落点，会退回 location / 的 SPA 兜底（200 + HTML，播放器报解码错误）"
    fi
fi
# 封面必须是【公开】的静态路径（请求来自浏览器 <img>，不是后端放行）
if printf '%s\n' "${LOCS}" | grep -qF "$(printf '/media/\tpublic')"; then
    ok "/media/ 是公开静态（播放器的 <img src=\"/media/...\"> 能直连）"
else
    err "music.conf 里 /media/ 不是公开静态 location：封面会落到 SPA 兜底（200 + HTML 裂图），而后端 DEBUG=false 时也不提供这些文件"
fi
MEDIA_ALIAS=$(awk '
    /^[[:space:]]*location[[:space:]]+\^~[[:space:]]+\/media\/[[:space:]]*\{/ { f = 1; next }
    f && /^[[:space:]]*alias[[:space:]]/ { sub(/^[[:space:]]*alias[[:space:]]+/, ""); sub(/;.*$/, ""); print; exit }
' docker/nginx/conf.d/music.conf)
MEDIA_ALIAS_N="$(printf '%s' "${MEDIA_ALIAS}" | sed 's:/$::')"    # 去尾斜杠便于比对

# ---- 封面落点：nginx 的 /media/ alias 是在【web 容器里】解析的 ----
# 所以 web 必须把宿主目录挂到「覆盖这张 alias 指向的路径」的容器位置，
# 否则 nginx 老老实实回 404 —— 封面全裂图，而日志里只有 nginx 的 404，最难查。
#
# 自「不再使用独立 ARTWORK_DIR」之后，宿主上 artwork 就是 MEDIA_DIR/artwork，
# 于是 web 有两种合法挂法，本检查都接受：
#   ① 只挂封面子目录： <宿主>/artwork -> /var/lib/musicbase/media/artwork
#   ② 挂整个媒体根：   <宿主>         -> /var/lib/musicbase/media
# 两者都必须 :ro（web 只做分发，写操作一律走 API）。
MEDIA_ROOT_C=/var/lib/musicbase/media
# artwork 子目录名不靠猜：后端 config.py 里 ARTWORK_DIR = MEDIA_ROOT / '<name>'，
# 直接把那个名字读出来（子项目没挂载时退回默认名 artwork）。
# ⚠️ 末尾的 `|| true` 不能省：脚本开头是 `set -e` + `pipefail`，子项目没挂载时
#    第一个 grep 找不到文件会返回 1，整条管道随之非零 —— 赋值语句就会直接终止脚本
#    （本文件里其它「从源码里读事实」的赋值也都带 `|| true`，同一个理由）。
ART_SUB="$(grep -A3 -E 'def ARTWORK_DIR\(' musicbase/app/core/config.py 2>/dev/null \
    | grep -oE "MEDIA_ROOT[[:space:]]*/[[:space:]]*['\"][^'\"]+['\"]" \
    | head -n 1 | sed -E "s#.*/[[:space:]]*['\"]([^'\"]+)['\"]\$#\1#" || true)"
ART_SUB="${ART_SUB:-artwork}"
COVER_ROOT_C="${MEDIA_ROOT_C}/${ART_SUB}"
web_vols="$(svc_volumes web)"
mount_kind=""; mount_line=""
if printf '%s\n' "${web_vols}" | grep -qE ":${COVER_ROOT_C}(:ro)?$"; then
    mount_kind="exact"
    mount_line="$(printf '%s\n' "${web_vols}" | grep -E ":${COVER_ROOT_C}(:ro)?$" | head -n 1 || true)"
elif printf '%s\n' "${web_vols}" | grep -qE ":${MEDIA_ROOT_C}(:ro)?$"; then
    mount_kind="parent"
    mount_line="$(printf '%s\n' "${web_vols}" | grep -E ":${MEDIA_ROOT_C}(:ro)?$" | head -n 1 || true)"
    echo "  i web 挂的是整个 MEDIA_ROOT（里面还有 uploads/ 暂存区与 netease_cookies.json）。"
    echo "    只读挂载本身没问题（/media/ alias 只暴露 artwork/ 子目录），但若想收窄，"
    echo "    可改成只挂 \${MEDIA_DIR}/artwork -> ${COVER_ROOT_C}。"
fi

if [ -z "${MEDIA_ALIAS}" ]; then
    err "/media/ location 里读不到 alias，封面路径无法确定"
elif [ "${MEDIA_ALIAS_N}" != "${COVER_ROOT_C}" ]; then
    err "/media/ 的 alias(${MEDIA_ALIAS}) 不是 ${COVER_ROOT_C}（= 后端 ARTWORK_DIR = MEDIA_ROOT/${ART_SUB}）：封面 404"
elif [ -z "${mount_kind}" ]; then
    err "web 的 volumes 没有任何挂载覆盖 ${COVER_ROOT_C}（nginx /media/ 的落点）：
       容器里看不到这个目录 -> 封面一律 404 裂图，且 nginx 日志里只有 404，很难联想到挂载。
       修法二选一（都不要再引入独立的 ARTWORK_DIR）：
         - \"\${MEDIA_DIR}/${ART_SUB}:${COVER_ROOT_C}:ro\"
         - \"\${MEDIA_DIR}:${MEDIA_ROOT_C}:ro\""
elif [ "${mount_kind}" = "exact" ]; then
    ok "/media/ 的 alias(${MEDIA_ALIAS}) 与 web 挂载点(${COVER_ROOT_C}) 一致"
else
    ok "/media/ 的 alias(${MEDIA_ALIAS}) 落在 web 挂载的 ${MEDIA_ROOT_C} 之下"
fi
# web 侧必须是只读：放开写等于绕过后端的鉴权与目录校验
if [ -n "${mount_kind}" ] && ! printf '%s\n' "${mount_line}" | grep -qE ':ro$'; then
    err "web 的媒体挂载不是只读：${mount_line}
       web 只做分发，写操作一律走 API；可写挂载会让容器绕过鉴权改动媒体文件。"
fi

# ARTWORK_DIR 已废弃：后端 ARTWORK_DIR 是只读 property（= MEDIA_ROOT/artwork），
# 宿主侧就用 MEDIA_DIR/artwork，compose 不该再出现这个自变量。
if sed 's/#.*//' docker-compose.yml | grep -q "ARTWORK_DIR"; then
    err "compose 里仍有未注释的 ARTWORK_DIR：它会让 artwork 出现第二个落点（且可能与 MEDIA_DIR/artwork 相互遮蔽）"
else
    ok "compose 不再使用独立的 ARTWORK_DIR（artwork 统一落在 MEDIA_DIR/artwork）"
fi
# 后端 artwork 的挂载路径就是 /media/{artists,albums,tracks,playlists}，两边要对齐
if [ -f musicbase/app/main.py ]; then
    n_mount=$(sed 's/#.*//' musicbase/app/main.py | grep -cE "app\.mount\('/media/" || true)
    if [ "${n_mount}" -ge 1 ]; then
        ok "后端也把封面挂在 /media/ 下（DEBUG 模式），路径口径一致"
    else
        echo "  ! musicbase/app/main.py 里没看到 '/media/' 的 StaticFiles 挂载，确认上游是否改过封面路径"
    fi
fi

echo "== 容器间寻址（upstream -> api）"
grep -qE "^[[:space:]]+server[[:space:]]+api:8000" docker/nginx/conf.d/music.conf \
    && ok "nginx upstream 使用服务名 api:8000" \
    || err "upstream 里不是 api:8000，请检查 docker/nginx/conf.d/music.conf"
if sed 's/#.*//' docker/nginx/conf.d/music.conf | grep -qE "server[[:space:]]+(0\.0\.0\.0|127\.0\.0\.1)"; then
    err "upstream 里出现了本机地址，会连到 nginx 自身导致 502"
else
    ok "upstream 未误用本机地址"
fi
grep -q "ipv4_address" docker-compose.yml \
    && ok "api/db 已固定静态 IP（避免重启后端后 nginx 502）" \
    || err "compose 未设置 ipv4_address，api 重建后 nginx 会连到旧 IP"
grep -q "ipam" docker-compose.yml && ok "网络已配置静态 IPAM" || err "networks.musicbase 缺少 ipam 配置"

echo "== 顶层 .env（编排参数）"
if [ -f .env ]; then
    ok ".env 存在"
    set -a; source .env; set +a
    for v in POSTGRES_PASSWORD MUSIC_DIR MEDIA_DIR; do
        [ -n "${!v:-}" ] && ok "$v 已设置" || err "$v 未设置"
    done
    for v in MUSIC_DIR MEDIA_DIR; do
        d="${!v:-}"
        [ -n "$d" ] || continue
        if [ -d "$d" ]; then ok "$v 存在 ($d)"; else err "$v 目录不存在: $d"; fi
    done

    # 同文件系统检查：归档是 shutil.move，跨设备时它不会报错，而是静默降级成
    # 「复制后删除」——大文件慢，复制中途失败还会在音乐库里留半个文件。
    # 这类问题只在运行时才暴露，且现象是「归档偶尔留残file」，极难归因，所以前置拦截。
    if [ -d "${MUSIC_DIR:-}" ] && [ -d "${MEDIA_DIR:-}" ]; then
        if [ "$(uname -s)" = "Linux" ]; then
            dev_music=$(stat -c '%d' "${MUSIC_DIR}" 2>/dev/null || echo "?")
            dev_media=$(stat -c '%d' "${MEDIA_DIR}" 2>/dev/null || echo "?")
            if [ "$dev_music" = "$dev_media" ]; then
                ok "MUSIC_DIR 与 MEDIA_DIR 在同一文件系统（归档不会跨设备复制）"
            else
                err "MUSIC_DIR(dev=$dev_music) 与 MEDIA_DIR(dev=$dev_media) 不在同一文件系统：
       staging 归档用 shutil.move，跨设备会降级成复制+删除，慢且中断会留残file。
       修复：把 MEDIA_DIR 放到与 MUSIC_DIR 同一物理卷，例如
         MUSIC_DIR=/volume1/music   MEDIA_DIR=/volume1/docker/musicbase/media
       检查命令： stat -c '%d %n' \"$MUSIC_DIR\" \"$MEDIA_DIR\"   # 设备号必须相同"
            fi
        else
            echo "  ! 当前是 $(uname -s)：Docker Desktop 的 bind mount 走统一虚拟文件系统，跳过设备号比对"
        fi
    fi

    # ARTWORK_DIR 已废弃（compose 不再引用它），留着会让人以为它还在起作用
    if grep -qE "^ARTWORK_DIR=" .env; then
        echo "  ! .env 里还留着 ARTWORK_DIR，但 compose 已不再引用它"
        echo "    artwork 现在就是 MEDIA_DIR/artwork，删掉这一行即可"
    fi
else
    err "缺少 .env（cp .env.example .env 后修改）"
fi

echo "== 环境变量分层归属"
# 分层原则（详见 README §5）：每个变量只在一个地方定义，判据是「谁有权改它」
#   L1 镜像层 Dockerfile ENV —— 换了部署环境也不会变的（解释器行为 / locale / PATH）
#   L2 编排层 compose environment —— 与 volumes、服务名耦合的契约
#   L3 部署层 .env -> env_file —— 换了主机就要重新填的（密钥 / PUID / 调试开关）
# 越界 = 同一件事在两层都写，改一处忘一处，比不写更危险。

# Dockerfile 的 ENV 常用 `\` 续行折叠成多行，路径/密钥可能落在续行里，
# 单行 grep 匹配不到 —— 必须先把续行拼回一行再判断。
fold_continuations() {
    awk '{
        line = $0
        # 去掉行尾空白
        sub(/[ \t]+$/, "", line)
        while (line ~ /\\$/ && (getline nl) > 0) {
            sub(/\\$/, "", line)
            sub(/^[ \t]+/, "", nl)
            sub(/[ \t]+$/, "", nl)
            line = line " " nl
        }
        print line
    }' "$1"
}

# (a) L1 不得越界写编排层的路径（改了 volumes 不会同步改 Dockerfile）
if fold_continuations docker/backend/Dockerfile | sed 's/#.*//' | grep -qE "^[[:space:]]*(ENV|ARG)[[:space:]]+.*(/music|/var/lib/musicbase|/var/tmp/musicbase)"; then
    err "Dockerfile 里写了容器路径（属于编排层契约，应与 compose 的 volumes 放在一起）"
else
    ok "Dockerfile 未越界定义容器路径"
fi
if fold_continuations docker/backend/Dockerfile | sed 's/#.*//' | grep -qE "(_KEY|_PASSWORD|_SECRET|_TOKEN|_API)="; then
    err "Dockerfile 里出现密钥类变量（ENV 会固化进镜像层，docker history 可见）"
else
    ok "Dockerfile 未固化任何密钥"
fi

# (b) L2 不得重复 L1 已经定好的量（只查 api 服务——db 是 postgres 官方镜像，它有自己的一套）
# 只取 api 服务的 environment 键（db 是 postgres 官方镜像，变量名自成一套）。
# dev 覆盖层也要一起扫，否则那边偷偷加的死变量查不出来。
compose_files=()
for f in docker-compose.yml docker-compose.dev.yml; do [ -f "$f" ] && compose_files+=("$f"); done
api_env_keys() {
    awk '
        FNR==1 { svc=""; inenv=0 }
        /^  [a-zA-Z0-9_-]+:/  { svc=$0; sub(/:.*/,"",svc); gsub(/^[ \t]+|[ \t]+$/,"",svc) }
        /^    environment:/   { inenv = (svc=="api"); next }
        inenv && /^    [a-zA-Z_]/ { inenv=0 }
        inenv && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
            k=$0; sub(/^      /,"",k); sub(/:.*/,"",k); print k
        }' "${compose_files[@]}"
}
l1_dup=0
while IFS= read -r k; do
    case "$k" in
        PYTHONDONTWRITEBYTECODE|PYTHONUNBUFFERED|PYTHONUTF8|PIP_DISABLE_PIP_VERSION_CHECK|LANG|LC_ALL|PATH|PYTHONPATH)
            echo "  ⚠ ${k} 在 Dockerfile 已定义，compose 里重复（属于镜像层，应从 compose 删除）"
            l1_dup=1 ;;
    esac
done < <(api_env_keys)
[ "$l1_dup" = "0" ] && ok "compose 未重复 Dockerfile 的镜像层变量"

# (c) L2 的路径必须与 volumes 挂载点一致（否则容器里指向不存在的目录）
# 注意：YAML 里的挂载串通常带引号（"...:/music"），比对前先剥掉引号，
# 否则 ":${p}$" 匹配不到行尾而被误报成「没有挂载点」。
path_missing=0
for p in /music /var/lib/musicbase/media /var/lib/musicbase/logs; do
    if ! tr -d "\"'" < docker-compose.yml | grep -q ":${p}\(:\|$\)"; then
        err "compose 的 environment 用到 ${p}，但 volumes 里没有对应挂载点"
        path_missing=1
    fi
done
[ "$path_missing" = "0" ] && ok "编排层路径均在 volumes 中有对应挂载点"

# (d) 配置来源必须分离：env_file 指向后端子项目的 .env，而不是顶层 .env。
#     指向顶层 .env 会把 MUSIC_DIR/HTTP_PORT/BACKUP_DIR 这类宿主机概念灌进容器，
#     一旦后端将来新增同名字段，它会静默读到宿主机路径（在容器里根本不存在）。
if grep -qE "^[[:space:]]*-[[:space:]]*path:[[:space:]]*musicbase/\.env" docker-compose.yml; then
    ok "env_file 指向 musicbase/.env（应用配置与编排参数已分离）"
elif sed 's/#.*//' docker-compose.yml | grep -qE "^[[:space:]]*-[[:space:]]*\.env[[:space:]]*$"; then
    err "env_file 指向顶层 .env：会把宿主机路径/端口等编排参数一并灌进容器，应改为 musicbase/.env"
else
    echo "  ! 未识别到 env_file 配置，请确认 api 服务显式声明了它"
fi
# 顶层 .env 不该出现只属于后端的应用配置
top_leak=0
for k in SECRET_KEY ACOUSTID_API_KEY NETEASE_PLAYLIST_API NETEASE_SONG_API APP_NAME MUSIC_FILE_EXTENSIONS; do
    if [ -f .env ] && grep -qE "^${k}=" .env; then
        echo "  ⚠ $k 属于后端应用配置，应放在 musicbase/.env；顶层 .env 只做 compose 插值"
        top_leak=1
    fi
done
[ "$top_leak" = "0" ] && ok "顶层 .env 未混入后端应用配置"

# (e) 死变量：在 compose 里配了，但没有任何代码读它。
#     关键：判据必须是【后端 config.py 里真实存在的字段】，不能拿 .env.example
#     当清单——.env.example 是可以随便写注释和占位名的，照着它写会漏判；
#     也不能因为 entrypoint 提到了就算数（entrypoint 是我们自己写的，
#     自己消费自己设的变量同样等于空转）。
backend_cfg="musicbase/app/core/config.py"
if [ -f "$backend_cfg" ]; then
    backend_fields="$(
        { grep -oE '^[[:space:]]+[A-Z][A-Z0-9_]*:' "$backend_cfg" | tr -d ' :'
          grep -oE 'def [A-Z][A-Z0-9_]*' "$backend_cfg" | sed 's/def //'
        } | sort -u
    )"
    dead=0
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        case "$k" in
            # 容器运行时参数：后端不读，由 entrypoint / 镜像层消费，属于编排层正当职责
            PUID|PGID|UMASK|RUN_MIGRATIONS|WAIT_FOR_DB|UVICORN_WORKERS|CHOWN_LIBRARY) continue ;;
            TZ|LANG|LC_ALL|PYTHONUNBUFFERED|PYTHONUTF8|PYTHONDONTWRITEBYTECODE) continue ;;
        esac
        printf '%s\n' "$backend_fields" | grep -qx "$k" && continue
        grep -q "\b${k}\b" docker/backend/entrypoint.sh && continue
        echo "  ⚠ ${k} 在 compose 里配了，但后端 config.py 无此字段、entrypoint 也不读它——死变量（配了不生效）"
        dead=1
    done < <(api_env_keys)
    [ "$dead" = "0" ] && ok "未发现死变量（compose 里配的都有真实消费方）"
else
    echo "  ! 未找到 $backend_cfg（子项目未挂载），跳过死变量检测"
    echo "    注意：这项检测依赖后端源码，别只用 .env.example 判断字段是否存在"
fi

echo "== 音频指纹工具（fpcalc）"
# 后端上传流程会用 pyacoustid 生成指纹，pyacoustid 内部执行 fpcalc 可执行文件：
#     acoustid.py:  fpcalc = os.environ.get(FPCALC_ENVVAR, FPCALC_COMMAND)
# 所以镜像里必须有它，否则上传时指纹步骤会 NoBackendError。
BD=docker/backend/Dockerfile
grep -qE "COPY --from=fpcalc .*/usr/local/bin/fpcalc" "$BD" \
    && ok "fpcalc 已装进镜像 PATH" \
    || err "Dockerfile 未安装 fpcalc：后端生成音频指纹会 NoBackendError"
grep -q "FPCALC=/usr/local/bin/fpcalc" "$BD" \
    && ok "已显式声明 FPCALC（取值确定化，不再依赖 PATH 查找）" \
    || echo "  ! 未显式设置 FPCALC：acoustid 会按 PATH 找 'fpcalc'，一般也能用"
grep -q "fpcalc -version" "$BD" \
    && ok "构建期有 fpcalc 自检（架构不匹配/缺库会在 build 阶段就暴露）" \
    || echo "  ! 未做构建期自检：fpcalc 装错架构要等第一次上传才发现"
grep -q "TARGETARCH" "$BD" \
    && ok "fpcalc 按目标架构取二进制（amd64 / arm64）" \
    || echo "  ! 未处理多架构：NAS 若为 arm64 会装到 x86_64 二进制而无法执行"
# 反模式：apt 的 libchromaprint-tools 会连带装上 libchromaprint.so.1，
# 使 pyacoustid 的 have_chromaprint 变 True，从而【跳过 fpcalc 改走 audioread 分支】，
# 而 audioread 还需要 gstreamer 或 ffmpeg 可执行文件才能解码 —— fpcalc 就白装了。
if sed 's/#.*//' "$BD" | grep -qE "apt-get install.*libchromaprint"; then
    err "Dockerfile 用 apt 装了 libchromaprint，会让指纹走 audioread 分支而绕过 fpcalc：
       请改用 chromaprint 官方静态 fpcalc（见 Dockerfile 的 fpcalc stage），
       并确保不安装 libchromaprint.so.1。"
else
    ok "未安装 libchromaprint.so.1（不会劫持 pyacoustid 的 fpcalc 分支）"
fi

echo "== 音乐库监控服务（watcher）"
# 后端有两套 watcher 实现，互斥：
#   app/background/watcher.py          独立进程 ← 容器里用这个
#   app/background/watcher_manager.py  进程内，由管理端 /startwatcher 触发（开发用）
# 同时启用 → 同一个新文件被处理两次 → 重复 Track / 并发写库。
# （svc_block 定义在文件头部，静态分发那一节也在用）
if ! grep -qE "^  watcher:" docker-compose.yml; then
    err "compose 里没有 watcher 服务：音乐库变动不会被自动入库（只能手动全量扫描）"
else
    ok "compose 已定义 watcher 服务"
    sed 's/#.*//' < <(svc_block watcher) | grep -qE 'command:.*app\.background\.watcher' \
        && ok "以独立进程方式启动（python -m app.background.watcher）" \
        || err "watcher 的 command 不是 app.background.watcher"
    sed 's/#.*//' < <(svc_block watcher) | grep -q '<<: \*api-env' \
        && ok "复用 api 的环境锚点（两个进程的配置不会各自漂移）" \
        || err "watcher 未复用 api 的环境定义：两处配置会各自演化，迟早不一致"
    sed 's/#.*//' < <(svc_block watcher) | grep -qE 'RUN_MIGRATIONS:[[:space:]]*"false"' \
        && ok "watcher 不执行数据库迁移（迁移只由 api 跑一次）" \
        || err "watcher 会与 api 同时 alembic upgrade head，可能互相撞锁"
    sed 's/#.*//' < <(svc_block watcher) | grep -q "/var/lib/musicbase/logs/watcher" \
        && ok "watcher 日志目录已与 api 分离" \
        || err "watcher 与 api 共用 LOG_DIR：logger.py 的 RotatingFileHandler
       轮转不是多进程安全的，两个进程写同一个 app.log 会丢日志、轮转错乱。"
    sed 's/#.*//' < <(svc_block watcher) | grep -q "disable: true" \
        && ok "已关闭 watcher 的 HTTP 健康检查" \
        || err "watcher 继承了镜像的 /healthz 健康检查，它会永远显示 unhealthy"
fi
if [ -f musicbase/app/background/watcher.py ]; then
    if grep -q "PollingObserver" musicbase/app/background/watcher.py; then
        ok "watcher.py 可按 WATCH_MODE 切换 Observer/PollingObserver"
    else
        echo "  ⚠ watcher.py 里只有 Observer（inotify），WATCH_MODE 配了也不生效："
        echo "    Docker Desktop(Windows/macOS) 的 bind mount 与 NFS/SMB 上收不到 inotify 事件，"
        echo "    容器会正常启动并打印 'Watcher started'，但文件变动永远不触发 —— 静默失效。"
        echo "    补丁见 README「监控模式」一节（换成 PollingObserver）。"
    fi
fi
if [ -f musicbase/app/api/v1/admin/scan.py ] && grep -q "startwatcher" musicbase/app/api/v1/admin/scan.py; then
    echo "  ! 后端保留了 /api/v1/admin/startwatcher（进程内 watcher，开发用）"
    echo "    独立进程模式下请【不要】调用它，否则同一文件会被两个 watcher 各入库一次"
fi

echo "== env_file 的解析模式"
# format: raw 让 Compose 不做 ${} 插值，从而与本地 python-dotenv 的读取行为严格一致
# （否则同一个带 $ 的 SECRET_KEY，本地跑和容器跑会得到两个不同的值）。
# 代价是要求 Compose >= 2.30，版本不够会报「未知字段」。
if grep -qE "format:[[:space:]]*raw" docker-compose.yml; then
    cv="$(docker compose version --short 2>/dev/null | head -1 || true)"
    if [ -z "$cv" ]; then
        echo "  ! 本机取不到 Compose 版本：format: raw 需要 >= 2.30，请自行确认"
    else
        cv_major="${cv%%.*}"; cv_rest="${cv#*.}"; cv_minor="${cv_rest%%.*}"
        if [ "${cv_major:-0}" -gt 2 ] 2>/dev/null || { [ "${cv_major:-0}" -eq 2 ] && [ "${cv_minor:-0}" -ge 30 ]; } 2>/dev/null; then
            ok "Compose $cv 支持 env_file format: raw"
        else
            err "Compose $cv 不支持 format: raw（需 >= 2.30）：
       要么升级 Compose，要么删掉 docker-compose.yml 里的 format 行，
       并把 musicbase/.env 中值里的 \$ 写成 \$\$（注意：那样只有容器内被转义，
       本地直接跑后端时读到的仍是 \$\$，两边会不一致）。"
        fi
    fi
fi

echo "== 后端配置（musicbase/.env）"
if [ -f musicbase/.env ]; then
    ok "musicbase/.env 存在"
    # config.py 里 Field(...) 的必填字段：缺了后端直接起不来
    for k in SECRET_KEY ACOUSTID_API_KEY NETEASE_PLAYLIST_API NETEASE_SONG_API DB_USER DB_PASSWORD DB_NAME; do
        grep -qE "^${k}=.+" musicbase/.env \
            && ok "$k 已设置" \
            || err "$k 在 musicbase/.env 里为空或缺失：config.py 标了必填，后端起不来"
    done

    # 环境相关键在容器内会被 compose 的 environment 覆盖 —— 这不是冗余：
    # 本地起服务要用 127.0.0.1 和本地路径，容器里必须是 db 和容器内路径，
    # 一份文件服务两种运行方式，值本来就应该不同。
    n_env=0
    for k in HOST PORT DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME \
             MUSIC_LIBRARY_PATH MEDIA_ROOT LOG_DIR NETEASE_COOKIES_FILE MUSIC_STATIC_PREFIX; do
        grep -qE "^${k}=" musicbase/.env && n_env=$((n_env + 1))
    done
    [ "$n_env" -gt 0 ] && echo "  i 其中 $n_env 个是环境相关键（DB_* / 路径类）：容器内用 compose 的值，本地起服务用这里的值"

    if grep -qE "format:[[:space:]]*raw" docker-compose.yml \
       && grep -qE "^[^#]*=[^$]*\\\$" musicbase/.env; then
        echo "  i 检测到 \$ 符号：env_file 已用 format: raw，无需转义，本地与容器读取一致"
    fi
else
    err "缺少 musicbase/.env（cp musicbase/.env.example musicbase/.env 后填写 SECRET_KEY 等）"
fi

# 用后端自己的 .env.example 当清单，逐个核对每个键都有来源
if [ -f musicbase/.env.example ]; then
    miss=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in \#*|"") continue;; esac
        k="${line%%=*}"
        [ "$k" = "$line" ] && continue          # 没有 = 的行
        k="$(echo "$k" | tr -d '[:space:]')"
        if grep -qE "^${k}=" musicbase/.env 2>/dev/null \
           || grep -qE "^[[:space:]]+${k}:" docker-compose.yml; then
            continue
        else
            err "后端变量 ${k} 既不在 musicbase/.env、也不在 compose 的 environment 中"
            miss=1
        fi
    done < musicbase/.env.example
    [ "$miss" = "0" ] && ok "后端 .env.example 全部变量都有来源"
else
    echo "  ! 未找到 musicbase/.env.example（子项目未挂载），跳过键集合核对"
fi

echo
if [ "$fail" = "0" ]; then
    echo "自检通过 ✅  可以执行 docker compose build"
else
    echo "自检未通过 ❌  请按上面的提示修复后再构建"
    exit 1
fi

