# wmusic-suite

把三个各自独立的仓库编排成一个 `docker compose` 服务栈：**PostgreSQL + FastAPI（含独立文件监控进程）+ nginx（双前端静态站）**。一条命令完成构建、数据库迁移、上线。

| 子项目        | 角色                    | 容器内落点                            |
| ---------- | --------------------- | -------------------------------- |
| `musicbase`  | FastAPI 后端 + 迁移 + 音频指纹 | `api`（uvicorn）、`watcher`（同镜像另一入口） |
| `musicplayer` | PWA 播放器（可添加到主屏幕）      | nginx `/`                        |
| `musicman`   | 管理后台                  | nginx `/admin/`                  |

> 本文件是**使用说明**。设计取舍、踩坑记录、每条配置为什么这么写，都在 [`DEVDOC.md`](DEVDOC.md) 里，排查疑难时去看它。

---

## 1. 架构与端口

```
                     浏览器 / PWA
                          │
              http://<宿主IP>:8080      ← 唯一对外暴露的端口
                          │
                 ┌────────▼─────────┐
                 │   web (nginx)    │   静态：player / man
                 │  musicbase-web   │   反代：/api/  → api:8000/api/v1/
                 └───┬──────────┬───┘   音频：/music/（internal + X-Accel-Redirect）
                     │          │       封面：/media/ → MEDIA_DIR/artwork（公开只读）
          /api/      │          │ 静态只读
                     ▼          ▼
        ┌────────────────────┐  ┌──────────────────────────┐
        │ api   uvicorn:8000 │  │ 宿主机 MUSIC_DIR   :/music │
        │ watcher（文件监控） │  │ 宿主机 MEDIA_DIR   :/media │
        └─────────┬──────────┘  └──────────────────────────┘
                  │ SQL
        ┌─────────▼──────────┐   ┌──────────────────────────┐
        │ db  postgres:17    │   │ 卷 wmusic_pgdata（数据库）  │
        │ musicbase-db       │   │ 卷 wmusic_app_data（日志）  │
        └────────────────────┘   └──────────────────────────┘

   网络 musicbase-net（bridge，静态 IPAM 172.28.0.0/16）
```

- **只有 `web` 映射端口**（`HTTP_PORT`，默认 8080）。`db`、`api`、`watcher` 都只在内部网络里，宿主机访问不到 —— 这是刻意的。
- `api` 与 `watcher` 是**同一份镜像、同一份配置**（YAML 锚点复用），差别只有三项：`RUN_MIGRATIONS=false`、`LOG_DIR` 指向子目录、健康检查关闭。
- 数据库名 / 用户名默认都是 `musicbase`，密码取 `.env` 的 `POSTGRES_PASSWORD`。

访问入口：

- `http://<宿主IP>:8080/` —— 播放器（PWA）
- `http://<宿主IP>:8080/admin/` —— 管理后台
- `http://<宿主IP>:8080/healthz` —— 健康检查（nginx 直接返回 200）

---

## 2. 目录结构

```
wmusic-suite/                    ← umbrella 仓库（只管编排，不放业务代码）
├── docker-compose.yml           ← 服务定义（name: wmusic）
├── docker-compose.dev.yml       ← 开发模式叠加（vite dev server 热重载）
├── Makefile                     ← 日常命令入口，优先用它
├── .env.example                 ← 编排参数模板 → 复制成 .env
├── .gitattributes               ← 全仓库行尾钉死为 LF（别删，原因见 §7.1）
├── .dockerignore
├── DEVDOC.md                    ← 详细设计文档（本文件是简版）
├── docker/
│   ├── backend/Dockerfile       ← Python 3.13 + uv + 静态 fpcalc
│   ├── backend/entrypoint.sh    ← 对齐权限 → 等库 → 迁移 → 降权启动
│   ├── web/Dockerfile           ← 多阶段：node 构建两个前端 → nginx
│   └── nginx/
│       ├── nginx.conf
│       ├── mime.types.audio     ← 官方 mime.types 缺的音频后缀（flac 等）
│       └── conf.d/music.conf    ← 站点配置（conf.d 下只允许存在这一个文件）
├── scripts/
│   ├── check.sh                 ← 构建前置自检，`make check` 调用
│   ├── backup.sh / restore.sh
│   └── init-umbrella.sh         ← 首次把三个仓库挂进来（submodule / subtree）
├── musicbase/                   ← submodule
├── musicplayer/                 ← submodule
└── musicman/                    ← submodule
```

---

## 3. 前置条件

| 项                | 要求                                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Docker           | Docker Engine 或 Docker Desktop，含 Compose 插件                                                                              |
| **Compose 版本**   | **≥ 2.30**（`env_file` 用了 `format: raw`，2.30 才支持）。`docker compose version` 自查                                                  |
| Git              | 需要支持 submodule                                                                                                           |
| 磁盘               | 镜像 ~1.5GB；音乐库与媒体目录另算                                                                                                      |
| 宿主机音乐库           | 一个放音频文件的目录（`.mp3` / `.flac`），以及一个**与它同一物理卷**的媒体目录，关于音乐库目录，有目录结构要求，详见wmusicbase仓库的说明。                                                                          |
| 后端密钥             | `SECRET_KEY`、`ACOUSTID_API_KEY`（音频指纹用），写进 `musicbase/.env`                                                                |

---

## 4. 快速开始

### 4.1 拉代码（带子模块）

```bash
git clone --recurse-submodules git@github.com:hozorro/wmusic-suite.git
cd wmusic-suite
```

如果已经克隆过，但子模块目录是空的：

```bash
git submodule update --init --recursive
```

> ⚠️ 子模块跟的是各自的 **`main`** 分支（`.gitmodules` 里 `branch = main`），而日常开发在 **`dev`**。
> 所以 `git submodule update --remote` 拉到的可能不是你以为的最新代码 —— 见 §7.5。

### 4.2 准备宿主机目录

```bash
# 1) 看音乐库目录的属主，稍后填进 .env 的 PUID / PGID
stat -c '%u:%g' /path/to/music

# 2) 建媒体目录：artwork / uploads/temp / uploads/staging 都在它下面
mkdir -p /path/to/media

# 3) 关键：两者必须在【同一个物理卷】
stat -c '%d %n' /path/to/music /path/to/media
#                ↑ 两行设备号必须相同

# 4) 备份目录（可选，默认 ./backups）
mkdir -p /path/to/backups
```

Windows（Docker Desktop）用正斜杠的绝对路径：`MUSIC_DIR=D:/Music`、`MEDIA_DIR=D:/Docker/musicbase/media`。

### 4.3 写两份配置

```bash
# ① 编排参数（宿主机路径 / 端口 / 数据库凭据 / 构建开关）—— 不注入任何容器
cp .env.example .env
vim .env      # 至少改 POSTGRES_PASSWORD / MUSIC_DIR / MEDIA_DIR / PUID / PGID

# ② 后端应用配置（密钥 / 第三方 API）—— 经 env_file 注入 api 与 watcher
cp musicbase/.env.example musicbase/.env
vim musicbase/.env      # 至少改 SECRET_KEY / ACOUSTID_API_KEY
```

两者职责不重叠，别把密钥写进顶层 `.env`（它只被 compose 的 `${}` 引用，不进容器）。

### 4.4 自检 → 构建 → 启动

```bash
make check          # 构建前置自检；make build / make up 也会自动先跑它
make build          # 首次约 3~10 分钟（含下载 fpcalc 静态二进制）
make up             # 起 db / api / watcher / web 四个容器
make ps
```

`make check` 失败时**不要硬上**：它抓的都是"构建能过、上线必坏"的问题（行尾、依赖锁文件、nginx 站点劫持、反代前缀、媒体路径……）。

### 4.5 验收

```bash
docker compose ps                                   # db / api / web 应为 healthy，watcher 为 Up（它关掉了健康检查）
curl -sI localhost:8080/healthz | head -1           # HTTP/1.1 200 OK
curl -sI localhost:8080/ | head -1                  # 200（不是 403）
curl -s  localhost:8080/api/v1/openapi.json | head -c 60    # JSON
docker exec musicbase-web ls /etc/nginx/conf.d/     # 只应有 music.conf
docker compose exec api fpcalc -version             # 指纹工具在
```

然后浏览器打开 `http://<宿主IP>:8080/`，从**另一台机器**也访问一次（局域网访问是最容易暴露 nginx 站点配置问题的方式）。

---

## 5. 日常运维

### 5.1 Makefile 命令

| 命令                    | 作用                                     |
| --------------------- | -------------------------------------- |
| `make check`          | 构建前置自检（约 30~40 秒）                      |
| `make build`          | 构建镜像（会先跑 check）                        |
| `make up` / `make down` | 启动 / 停止（`down` 保留数据卷）                  |
| `make restart`        | 重启 api + watcher + web                 |
| `make ps`             | 看状态                                    |
| `make logs`           | 跟踪全部容器日志（docker logs 层面）               |
| `make logs-watcher`   | 跟踪监控进程的**应用日志文件**                      |
| `make backup`         | 备份数据库 + 媒体目录 + 配置                       |
| `make shell-api` / `shell-watcher` / `shell-db` | 进容器 / 进 psql |
| `make pull` / `make prune` | 拉镜像 / 清无用镜像                        |
| `make dev` / `dev-down` | 开发模式（vite 热重载，见 §5.4）                  |

### 5.2 进数据库看数据

```bash
make shell-db          # = docker compose exec db psql -U musicbase -d musicbase
```

容器内走 unix socket，`pg_hba.conf` 里 `local` 段是 `trust`，**不需要输密码**。进去先开：

```sql
\x auto      -- 音乐元数据字段多，竖排才看得清
\dt+         -- 看所有表
SELECT count(*) FROM tracks WHERE NOT is_deleted;
SELECT id, title, path, created_at FROM tracks ORDER BY id DESC LIMIT 10;
```

主要表：`tracks / albums / artists / genres / folders / playlists / playlist_tracks`、统计表 `track_hits / artist_hits / track_favorites / artist_favorites`、鉴权 `users / user_tokens`。

怕手滑就先执行 `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;`，本会话的写操作会直接被拒。

宿主机 GUI 客户端（DBeaver 等）默认**连不上** —— `db` 没有映射端口。要用就写一个 override 文件临时开口，**只绑 127.0.0.1**，用完删掉：

```bash
cat > docker-compose.override.yml <<'EOF'
services:
  db:
    ports:
      - "127.0.0.1:5433:5432"
EOF
docker compose up -d db
```

### 5.3 看日志

```bash
docker compose logs -f api                 # 容器 stdout（迁移、启动信息）
docker compose exec api     tail -f /var/lib/musicbase/logs/app.log
docker compose exec watcher tail -f /var/lib/musicbase/logs/watcher/app.log
```

> 生产（`DEBUG=false`）下后端业务日志**只写文件**，不会出现在 `docker logs` 里 —— 这是设计如此，不是没启动。
> 两个进程的日志必须分开（轮转不是多进程安全的），所以 `watcher` 有独立子目录。

### 5.4 开发模式

```bash
make dev        # 叠加 docker-compose.dev.yml：vite dev server 热重载 + DEBUG + ffmpeg
make dev-down
```

### 5.5 路径对照表

| 容器内路径                            | 宿主对应                       | 用途                            |
| -------------------------------- | -------------------------- | ----------------------------- |
| `/music`                          | `${MUSIC_DIR}`（可读写）        | 音乐库；标签编辑、归档入库都直接写它            |
| `/var/lib/musicbase/media`        | `${MEDIA_DIR}`（容器内可写）      | 媒体根：`artwork/`、`uploads/temp/`、`uploads/staging/`、`netease_cookies.json` |
| `/var/lib/musicbase/media/artwork` | `${MEDIA_DIR}/artwork`      | 封面缓存（丢了要重扫全库）                 |
| `/var/lib/musicbase/logs`         | 卷 `wmusic_app_data`          | 后端日志                          |
| `/var/lib/postgresql/data/pgdata` | 卷 `wmusic_pgdata`            | 数据库数据                         |

`web` 以**只读**方式挂了 `/music` 与 `/var/lib/musicbase/media`，只做分发，任何写操作都走 API。

### 5.6 子项目更新后重新上线

```bash
git submodule update --remote --merge     # 拉子模块最新（注意 §7.5 的分支问题）
git add musicbase musicplayer musicman && git commit -m "chore: bump submodules"

make build && make up                     # api 与 watcher 共用一个镜像，构建一次即可
```

### 5.7 备份 / 恢复

```bash
make backup                                   # 输出到 ${BACKUP_DIR}/<时间戳>/
./scripts/restore.sh ./backups/20261009-120000
```

- 备份内容：PostgreSQL dump（`pg_dump -Fc` + 纯 SQL 各一份）、`MEDIA_DIR` 打包、两份 `.env`、日志卷。
- **备份不含音乐库本身** —— 那是宿主机资产，请用 rsync / 快照 / RAID 单独保障。
- ⚠️ `restore.sh` 会 **drop 并重建** 目标数据库，脚本内有二次确认。

---

## 6. 关键环境变量

顶层 `.env`（编排参数）：

| 变量                  | 默认                    | 说明                                     |
| ------------------- | --------------------- | -------------------------------------- |
| `HTTP_PORT`         | 8080                  | 唯一对外端口                                 |
| `POSTGRES_DB` / `_USER` / `_PASSWORD` | musicbase / musicbase / **必填** | 同时供 db 服务与 api 的 `DB_*` 使用，不必填两遍         |
| `MUSIC_DIR`         | **必填**                | 音乐库宿主目录，挂到 `/music`                     |
| `MEDIA_DIR`         | **必填**                | 媒体根宿主目录，挂到 `/var/lib/musicbase/media`     |
| `PUID` / `PGID`     | 1000 / 1000           | 必须等于音乐库目录属主，否则标签编辑报 Permission denied  |
| `UMASK`             | 022                   | 022→644/755；按组共享音乐库时用 002→664/775        |
| `TZ`                | Asia/Shanghai         |                                        |
| `INSTALL_FFMPEG`    | false                 | 需要转码/抽视频封面时改 true（镜像 +80MB）             |
| `FPCALC_VERSION`    | 1.6.1                 | 构建期从官方 release 下载静态二进制                 |
| `FPCALC_MIRROR`     | 空                     | 直连 GitHub 失败时填加速前缀，如 `https://ghfast.top/https://github.com` |
| `WATCH_MODE`        | polling               | 见 §7.6，目前配了也不生效                        |
| `RUN_MIGRATIONS`    | true                  | 只有 api 该为 true                        |
| `UVICORN_WORKERS`   | 1                     | 涉及文件整理/归档，保持 1                         |
| `CHOWN_LIBRARY`     | false                 | 置 true 让容器**一次性**递归修正音乐库属主（大库很慢）        |
| `MUSICBASE_SUBNET` / `DB_IPV4` / `API_IPV4` | 172.28.0.0/16 等 | 与宿主机其它 Docker 网络冲突时才改                  |

`musicbase/.env`（后端应用配置）至少要有：`SECRET_KEY`、`ACOUSTID_API_KEY`。它经 `env_file: format: raw` 注入，**不做 `${}` 插值**，所以密码里有 `$` 也不用转义。

---

## 7. 注意事项（踩坑高发区）

### 7.1 行尾必须是 LF —— CRLF 会让容器起不来，而 git 看不见

本仓库用 `.gitattributes` 把行尾钉成 LF。**别删它。**

原因：`docker/backend/entrypoint.sh` 会被原样 `COPY` 进镜像并作为 ENTRYPOINT 执行。如果它是 CRLF，内核读 shebang 拿到的是 `#!/usr/bin/env bash\r`，于是去找一个名叫 `bash\r` 的解释器，容器启动直接失败：

```
exec /usr/local/bin/entrypoint.sh: no such file or directory
```

更坑的是**你从 git 里看不出任何异常**：Windows 上 Git 常默认 `core.autocrlf=true`，`git diff` / `git status` 会自动归一化行尾，工作区明明是 CRLF 也显示"没改动"（只有按字节比对才发现）。

自检已经覆盖：`make check` 的「行尾符」组会逐个文件数 CR 字节。若它报错，按 `git rm --cached -r . && git reset --hard` 重写工作区。另外请把编辑器也设成 LF（这个坑本站就是编辑器存成 CRLF 引入的）。

### 7.2 `db` 不映射端口，是刻意的

PostgreSQL 只该被同网络的容器访问。需要本机 GUI 客户端时，用 §5.2 的 `127.0.0.1:5433` 临时 override —— **千万不要写成 `"5433:5432"`**，那等于把数据库暴露给整个局域网。临时文件用完记得删（它会被 compose 自动合并，而且 `docker-compose.override.yml` 不在 `.gitignore` 里）。

### 7.3 卷名前缀 = compose 项目名；改项目名会"丢数据"

`docker-compose.yml` 顶部是 `name: wmusic`，而卷只声明了 `pgdata` / `app_data`，**没有显式 `name:`** —— 所以实际卷名是 `wmusic_pgdata` / `wmusic_app_data`。

一旦把 `name:` 改成别的（或换目录名、换 `-p` 参数），compose 会去找**新名字的空卷**，于是数据库"看起来丢了"（旧的 `wmusic_pgdata` 还在，只是没被挂载）。改名前先迁移：

```bash
docker compose down                                   # 先停
docker volume create <新前缀>_pgdata
docker run --rm -v wmusic_pgdata:/from -v <新前缀>_pgdata:/to alpine sh -c 'cp -av /from/. /to/.'
docker compose up -d
```

想彻底免疫改名，就给卷写死名字：

```yaml
volumes:
  pgdata:
    name: wmusic_pgdata
  app_data:
    name: wmusic_app_data
```

### 7.4 `MUSIC_DIR` 与 `MEDIA_DIR` 必须在同一物理卷

上传 → 落临时区 → 写标签 → **归档入库**（`shutil.move`）。跨设备时 `move` 会静默降级成"复制后删除"：大文件慢，中途失败还会在音乐库里留下半个文件，而数据库里可能已有记录。

```bash
stat -c '%d %n' "$MUSIC_DIR" "$MEDIA_DIR"     # 两行设备号必须相同
```

`make check` 在 Linux 上会自动查这一条。

### 7.5 子模块跟 `main`，开发在 `dev`

`.gitmodules` 里三个子模块都是 `branch = main`，而 `wmusicbase` / `wmusicman` 的活跃分支是 `dev`。后果：

- `git submodule update --remote` 拉到的是 `main`，可能**落后于你正在开发的 `dev`**。
- 你刚 push 到 `dev` 的改动，不合并到 `main` 就永远进不了这个栈的构建。

两条路：要么每轮把 `dev` 合并/快进到 `main` 再 bump 子模块指针；要么把 `.gitmodules` 的 `branch` 改成 `dev`（那样这条栈就跟着开发分支跑，注意它是无人值守部署时，稳定性会下降）。

```bash
git submodule status                    # 看每个子模块当前 pin 在哪个 commit
git -C musicbase log --oneline -1        # 看它实际是哪一版
```

### 7.6 `WATCH_MODE` 目前配了也不生效

`watcher.py` 里写死了 `observer = Observer()`（inotify），没有读 `WATCH_MODE`。而 Docker Desktop（Windows / macOS）的 bind mount 与 NFS/SMB 上**收不到 inotify 事件** —— 表现是容器正常启动、日志照打 `Watcher started`，但往音乐库里丢歌永远不入库（静默失效，最难查的一类）。

`make check` 会就此给出警告。要真正生效，得给后端打一个把 `Observer` 换成 `PollingObserver` 的小补丁（见 `DEVDOC.md` §4.5）。在那之前，新歌入库靠管理端手动触发全量扫描兜底。

### 7.7 生产环境不要开 `DEBUG=true`

`DEBUG=true` 会让后端绕过 nginx 的 `X-Accel-Redirect` 改用 Python 直读文件（音频分发退化，拖动进度条会变差），并改变日志行为。只有 `make dev` 才需要它。

### 7.8 别把 Windows 的 `fpcalc.exe` COPY 进镜像

后端仓库根目录下有 `fpcalc.exe` / `libchromaprint.dll` —— 那是 PE 格式，容器里跑了会报 `exec format error`。容器内的 `fpcalc` 由 `docker/backend/Dockerfile` 在构建期下载官方 **linux 静态二进制**（带 sha256 校验），版本由 `FPCALC_VERSION` 控制。`.dockerignore` 已经把它们排除。

### 7.9 nginx 的 `conf.d` 下只允许存在我们的配置

基础镜像自带 `/etc/nginx/conf.d/default.conf`，按文件名字典序排在 `music.conf` 之前，会成为 80 端口的**默认 server**，把用 IP 访问的请求全部劫走 —— 症状是 `http://<IP>:8080/` 报 **403** 且 `/healthz` 报 **404**（两个一起出现就是它的签名）。Dockerfile 里已经 `rm -f` 它并做了构建期校验，自己加站点配置时注意别引入第二个 `default_server`。

### 7.10 `/api/` 反代必须补上后端前缀

后端真实前缀是 `/api/v1`，前端请求 `/api/...`。`music.conf` 里必须是：

```nginx
location ^~ /api/ {
    proxy_pass http://musicbase_api/api/v1/;
}
```

漏了 `v1` 的表现是"页面能开、一登录就 404"。`make check` 的「API 反代前缀」组会核对。

### 7.11 媒体目录不要只挂一半

`web` 需要只读挂载 `${MEDIA_DIR}`，否则 nginx 的 `/media/` 落空 → **封面全裂图**。而音频走 `/music/`（internal + X-Accel），前缀与 `MUSIC_STATIC_PREFIX=/music/` 必须一致，对不上时播放器会拿到 `200 + HTML`（静默解码错误，比 404 难查得多）。`make check` 的「静态分发路径」组逐条核对这几个落点。

### 7.12 其它

- **`restore.sh` 会 drop 数据库**，跑之前确认目标是对的。
- **首次构建慢**：`fpcalc` 从 GitHub release 下载，被墙就设 `FPCALC_MIRROR`。
- **管理端有个进程内 watcher 端点**（`/api/v1/admin/startwatcher`）：独立 `watcher` 容器在跑时**不要**调它，否则同一个文件被两个 watcher 各入库一次。
- **PUID/PGID 不一致**：标签编辑报 Permission denied。先 `stat -c '%u:%g'` 再改 `.env` 重建容器；实在乱了可以临时 `CHOWN_LIBRARY=true` 跑一次。
- **数据库排序**：镜像用 `LANG=C.UTF-8`。要按拼音排序需自定义 `POSTGRES_INITDB_ARGS`（注意 ICU 版本与体积）。

---

## 8. 排错速查

| 现象                                              | 先查什么                                                                                                        |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `docker compose build` 报 `npm error code EEXIST /usr/local/bin/yarn` | 基础镜像自带 yarn，别自己 `npm i -g yarn`（Dockerfile 已有探测逻辑）                                                            |
| 构建最后一步报 `nginx: [emerg] host not found in upstream "api"` | 构建期不该跑会解析 upstream 的 `nginx -t`。本栈已改成只校验 mime 表的最小配置 + nginx 启动时校验，别把裸 `nginx -t` 加回去                            |
| 日志刷 `[warn] duplicate extension "m4a"/"m3u8"`   | `mime.types.audio` 里重复定义了官方表已有的扩展名（官方表把 `m3u8` 藏在 `application/` 段，最容易看漏）                                     |
| 从别的机器访问 `:8080` 报 **403**，`/healthz` 报 **404**（同时出现） | `conf.d/default.conf` 抢走了 80 端口 → 见 §7.9。自检：`docker exec musicbase-web ls /etc/nginx/conf.d/`                       |
| 页面能开，一点登录/任何操作就 404                              | `/api/` 没补 `v1` 前缀 → 见 §7.10                                                                                |
| 能登录能浏览，一按播放就"解码错误"/无声                          | `MUSIC_STATIC_PREFIX` 与 nginx internal location 对不上，返回了 `200 + HTML` → 见 §7.11                                |
| 封面全是裂图但控制台**没有 404**                            | `/media/` 被 SPA 兜底成 200 + index.html → 见 §7.11                                                                |
| 音频拖动条不能跳进度                                      | 走了 Python `FileResponse` 而不是 X-Accel（多半是 `DEBUG=true`）                                                        |
| `api` 一直 unhealthy                              | 看 `docker compose logs api`；健康检查先探 `/healthz`、失败回退 `/openapi.json`，两个都不行说明进程没起来                                   |
| watcher 在跑但新歌不入库                                 | 见 §7.6（inotify 静默失效），先看 `make logs-watcher`                                                                 |
| `Invalid cross-device link` 或归档"变慢且留半个文件"        | `MUSIC_DIR` 与 `MEDIA_DIR` 不在同一物理卷 → §7.4                                                                      |
| 标签编辑报 Permission denied                          | PUID/PGID 与音乐库属主不一致                                                                                          |
| 容器起不来，报 `exec ... : no such file or directory`  | 行尾是 CRLF → §7.1                                                                                              |
| 数据库"空了"                                        | 项目名/卷名前缀变了 → §7.3                                                                                            |

更长的原因分析与处理见 `DEVDOC.md` §8。

---

## 9. 文档分工

| 文件          | 面向          | 内容                                |
| ----------- | ----------- | --------------------------------- |
| `README.md` | 部署者 / 使用者   | 本文件：怎么装、怎么用、别踩什么坑                 |
| `DEVDOC.md` | 维护者 / 排查疑难  | 每个设计决定的原因、逐条验证记录、完整排错表            |

改代码/改编排之后，请顺手同步对应文档 —— 特别是 `DEVDOC.md` 里那些"为什么不能这么写"的记录，它们是防止同类坑回来的唯一手段。
