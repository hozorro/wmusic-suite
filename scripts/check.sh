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

echo "== 前端依赖清单"
for p in musicplayer musicman; do
    if [ -f "$p/package.json" ]; then ok "$p/package.json"; else err "缺少 $p/package.json"; continue; fi
    if   [ -s "$p/package-lock.json" ]; then ok "$p/package-lock.json"
    elif [ -s "$p/pnpm-lock.yaml"    ]; then ok "$p/pnpm-lock.yaml"; echo "     ! Docker 里默认只 COPY package-lock.json，请把该文件行改成 pnpm-lock.yaml"
    elif [ -s "$p/yarn.lock"         ]; then ok "$p/yarn.lock";      echo "     ! Docker 里默认只 COPY package-lock.json，请把该文件行改成 yarn.lock"
    else
        err "$p 缺少锁文件"
        echo "     修复：cd $p && npm install --package-lock-only"
    fi
done

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
    for v in POSTGRES_PASSWORD MUSIC_DIR MEDIA_DIR ARTWORK_DIR; do
        [ -n "${!v:-}" ] && ok "$v 已设置" || err "$v 未设置"
    done
    for v in MUSIC_DIR MEDIA_DIR ARTWORK_DIR; do
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
svc_block() {
    awk -v want="$1" '
        /^  [A-Za-z0-9_-]+:/ { svc=$0; sub(/:.*/,"",svc); gsub(/^[ \t]+|[ \t]+$/,"",svc); inblk=(svc==want); next }
        inblk { print }
    ' docker-compose.yml
}
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

