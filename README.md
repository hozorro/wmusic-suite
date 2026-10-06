# musicbase 一体化部署方案 & 运维手册

三个子项目在**保留各自 git 仓库**的前提下，用一个 umbrella（伞形）仓库编排成一套 `docker compose` 服务栈，  
一条命令完成构建、迁移、上线。

---

## 0. 结论先行：推荐的架构

```
                      浏览器 / PWA
                           │  http://<host>:8080
                           ▼
              ┌────────────────────────────┐
              │  musicbase-web  (nginx)    │
              │  /        → musicplayer    │  静态SPA
              │  /admin/  → musicman       │  静态SPA
              │  /api/    → proxy → api    │  反向代理
              │  /media/  → X-Accel only   │  音频分发（Range 支持）
              │  /artwork/→ X-Accel only   │  封面分发
              └────────────┬───────────────┘
                           │ musicbase-net
      ┌────────────────────┼────────────────────┐
      ▼                    ▼                    ▼
┌────────────────┐  ┌───────────────┐  ┌──────────────────┐
│ musicbase-api  │  │    watcher    │  │ musicbase-db (PG)│
│ uvicorn        │  │  watchdog     │  │ postgres:17      │
│ 内置 fpcalc    │  │ 独立监控进程  │  └──────────────────┘
└───────┬────────┘  └───────┬───────┘
        │ 同一个镜像 / 同一份配置 / 同一批挂载（仅 3 项不同，见 §4.5）
        └───────────┬───────┘
                    │ rw
   ┌────────────────┼──────────────────────┬──────────────────┐
   ▼                ▼                      ▼                  ▼
 /music    /var/lib/musicbase/media    /music (ro)        logs 卷
 (音乐库)   ├ artwork/                 ↑ web 只读挂载    ├ api/
            ├ uploads/temp/                              └ watcher/
            └ uploads/staging/
```

> 注意 `uploads/staging`（归档暂存区）是 `MEDIA_ROOT` 的**派生子目录**，不是独立挂载点 ——  
> 后端 `config.py` 里 `STAGING_DIR` 是只读 property，用环境变量设它是无效的。见 §4.1。

**为什么不用「一个巨镜像里塞 supervisor + postgres + nginx」**

| 方案                   | 优点                                         | 缺点                                              |
| -------------------- | ------------------------------------------ | ----------------------------------------------- |
| **多容器 Compose（本方案）** | 组件各自官方镜像、升级互不干扰；postgres 独立数据卷；缓存层干净；可单独扩缩 | 需要理解 compose                                    |
| 单镜像 s6/supervisor    | 一个 image 拷哪里都能跑                            | Python+Node+PG 混在一个层里，构建慢、镜像臃肿；PG 升级困难；无法单独重启组件 |

**一体化 ≠ 单容器**。对外是单一入口（一个端口、一次 `up -d`），对内按职责拆，是这类项目的最佳解。

---

## 1. 目录结构

```
musicbase-suite/                  ← umbrella 仓库（新建，git 管理部署编排）
├── docker-compose.yml
├── .env / .env.example
├── .dockerignore
├── README.md                     ← 本文件
├── Makefile
├── docker/
│   ├── backend/
│   │   ├── Dockerfile            ← FastAPI / Python 3.13
│   │   └── entrypoint.sh         ← 权限对齐 + 等库 + 迁移 + 降权启动
│   ├── web/
│   │   └── Dockerfile            ← 多阶段：node 构建 player & man → nginx
│   └── nginx/
│       ├── nginx.conf              ← include 官方 mime.types + 音频补充表
│       ├── mime.types.audio        ← 补 flac/wav/opus/... 官方没有的类型（关键！）
│       └── conf.d/music.conf
├── scripts/
│   ├── init-umbrella.sh          ← submodule / subtree 整合
│   ├── backup.sh
│   └── restore.sh
├── musicbase/                    ← 后端仓库（submodule 或 subtree）
├── musicplayer/                  ← PWA 前端仓库
└── musicman/                     ← 管理端仓库
```

三个子项目的源码**一个字都不用改目录结构**，只是被挂到 umbrella 根目录下。

---

## 2. 仓库整合：submodule vs subtree

| 维度          | `git submodule`（**推荐**）            | `git subtree`                           |
| ----------- | ---------------------------------- | --------------------------------------- |
| 子项目是否保留独立仓库 | ✅ 完全保留，各自 push/打 tag/CI 不变         | ⚠️ 上游仓库仍在，但日常在主仓库里改，需 `subtree push` 回推 |
| clone 体验    | 需 `git clone --recurse-submodules` | ✅ 一次 clone 全量到手                         |
| 版本锁定        | ✅ 精确锁 commit（`git` link）           | ❌ 代码混在一起                                |
| 新人误操作风险     | 中（容易忘记 `--recursive`）              | 低                                       |
| 适合          | **团队协作、子项目要独立发版**                  | 单人/小团队、追求简单                             |

**选择建议**：你明确说过三个仓库各自 git 版本控制 → 用 **submodule**（保持现状，零迁移成本）；  
若觉得 `--recurse-submodules` 太烦，换 subtree，`scripts/init-umbrella.sh subtree` 已内置。

> submodule 场景下 CI/CD 各自独立：子仓库跑自己的测试/发 tag，umbrella 只负责在 CI 里  
> `git submodule update --remote` 后构建镜像。

---

## 3. 具体操作步骤

### 3.1 准备 umbrella 仓库

```bash
git clone <你的远端空仓库地址> musicbase-suite
cd musicbase-suite
# 把本目录下的 docker-compose.yml / docker/ / scripts/ / .env.example / .dockerignore 拷进来并提交
git add . && git commit -m "chore: init deployment stack"

chmod +x scripts/*.sh docker/backend/entrypoint.sh

# 挂载三个子项目（二选一）
./scripts/init-umbrella.sh submodule <musicbase-url> <musicplayer-url> <musicman-url>
# 或
./scripts/init-umbrella.sh subtree   <musicbase-url> <musicplayer-url> <musicman-url>
git commit -m "chore: attach three sub projects"
```

### 3.2 宿主机准备

```bash
# 1) 确认音乐库目录属主 uid/gid（Linux）
stat -c '%u:%g %n' /path/to/music
# 把结果填到 .env 的 PUID / PGID

# 2) 建媒体目录 —— 必须与音乐库【同一物理卷】（原因见 §4.1）
mkdir -p /path/to/media            # 挂到容器 MEDIA_ROOT，artwork/uploads/staging 都在里面
stat -c '%d %n' /path/to/music /path/to/media
#                                  ↑ 两行设备号必须相同，否则归档会退化成跨设备复制

# 3) artwork 缓存目录（想让它独立于 media 目录时才需要；否则用 media/artwork 即可）
mkdir -p /path/to/artwork-cache

# 4) 两份配置，各管一摊
cp .env.example .env                        # 编排参数（宿主机目录 / 端口 / 数据库凭据）
vim .env            # 至少改：POSTGRES_PASSWORD / MUSIC_DIR / MEDIA_DIR / ARTWORK_DIR / PUID / PGID

cp musicbase/.env.example musicbase/.env    # 后端应用配置（密钥 / 第三方 API）
vim musicbase/.env  # 至少改：SECRET_KEY / ACOUSTID_API_KEY
```

> 不需要再手动建 `staging` 目录：暂存区由后端按 `MEDIA_ROOT/uploads/staging` 自行创建，  
> 位置**不可配置**（`config.py` 里是 property），`entrypoint.sh` 会在降权前建好并对齐属主。

Windows（Docker Desktop）示例：

```ini
MUSIC_DIR=D:/Music
MEDIA_DIR=D:/Docker/musicbase/media
ARTWORK_DIR=D:/Docker/musicbase/artwork
PUID=1000
PGID=1000
```

> Docker Desktop 需要在 *Settings → Resources → File sharing* 里放行 `D:\Music`。  
> Windows 下这两处跨盘符不会触发 §4.1 的设备问题（bind mount 走统一虚拟文件系统），  
> 但同盘仍能明显加快归档速度。

### 3.3 构建与启动

```bash
make check                          # 强烈建议：构建前置自检（依赖清单 / 目录 / .env / 指纹工具 / watcher）
docker compose build                # 首次约 3~10 分钟（含下载 fpcalc 静态二进制 ~2MB）
docker compose up -d
docker compose ps                   # 四个容器：db / api / watcher / web
docker compose logs -f api          # 迁移日志
docker compose logs -f watcher      # 监控进程启动日志

# api 健康检查：后端目前没有 /healthz，先用 openapi.json 探活
curl -fsS http://localhost:8080/api/v1/...  # 走 nginx 的接口
docker compose exec api curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/openapi.json

# 指纹工具确认
docker compose exec api fpcalc -version
```

访问：

- `http://<host>:8080/` —— musicplayer（PWA，可"添加到主屏幕"）
- `http://<host>:8080/admin/` —— musicman 后台

> `watcher` 容器没有对外端口，`docker compose ps` 里也不会显示 healthy（健康检查已关，  
> 原因见 §4.5）；只要 `STATUS` 是 `Up` 就说明它在跑。

### 3.4 子项目更新后重新上线

```bash
# submodule：
git submodule update --remote --merge
git add musicbase musicplayer musicman && git commit -m "chore: bump sub modules"

docker compose build api watcher web   # api 与 watcher 用同一个 Dockerfile，构建一次即可
docker compose up -d
```

### 3.5 备份 / 恢复

```bash
./scripts/backup.sh                        # 输出到 $BACKUP_DIR/<时间戳>
./scripts/restore.sh ./backups/20260928-101900
```

> ⚠️ `restore.sh` 会 **drop 并重建** 目标数据库。脚本内有二次确认。  
> 备份只覆盖数据库 + artwork 缓存 + app_data。音乐库本身是宿主机资产，  
> 建议用 rsync / snapshot / RAID 单独保障。

---

## 4. 针对"音乐管理"场景的关键设计（这部分最容易踩坑）

### 4.1 同文件系统原则 —— 最重要的一条

场景：上传 → 临时落盘（`TEMP_DIR`）→ 写 meta 标签 → **归档入库**（`shutil.move`）。

后端的这几个目录**全部由 `MEDIA_ROOT` 派生，而且是只读 property，环境变量改不动**  
（见 `musicbase/app/core/config.py`）：

| 用途      | 实际路径                              |
| ------- | --------------------------------- |
| 上传落盘    | `MEDIA_ROOT` + `/uploads/temp`    |
| 待归档暂存区  | `MEDIA_ROOT` + `/uploads/staging` |
| artwork | `MEDIA_ROOT` + `/artwork`         |
| 歌单临时文件  | `MEDIA_ROOT` + `/playlists/tmp`   |

所以「把暂存区塞进音乐库内部」这件事**没法靠配置实现**。早前版本里那句  
`MUSIC_STAGING_DIR=/music/.staging` 是**错的**——`MUSIC_STAGING_DIR` 这个字段在  
`config.py` 里根本不存在，设了也不生效，真正生效的只有 `MEDIA_ROOT`。

要满足的约束因此变成这一条：

> **`MEDIA_DIR`（挂载到容器 `MEDIA_ROOT` 的宿主目录）必须与 `MUSIC_DIR` 在同一物理卷。**

因为 `shutil.move` 跨设备时**不会报错**，它会静默降级成「复制后删除」：

- 无损单曲 30~50MB，复制比 rename 慢一个数量级，归档一批专辑的耗时会明显上升；
- 复制中途失败（磁盘满 / 进程被 kill）→ 音乐库里留下半个文件，而数据库里可能已有记录。

`make check` 会用 `stat -c '%d'` 比对两个目录的设备号，不一致就直接报错并给出修正示例。  
（Windows/macOS 的 Docker Desktop 走统一虚拟文件系统，不适用，脚本会跳过这项。）

**那为什么不干脆把 `MEDIA_ROOT` 放进音乐库内**（那样天然同设备）？  
因为后端扫描器是这么写的：

```python
def iter_files(self):
    for file_path in self.root_path.rglob("*"):          # 没有跳过隐藏目录
        if file_path.suffix.lower() in settings.MUSIC_FILE_EXTENSIONS:
            yield file_path
```

`rglob("*")` 会把 `<音乐库>/.musicbase/uploads/staging/` 里还没归档的歌一起扫出来入库，  
结果是**同一首歌在暂存区和正式目录各留一条记录**。所以结论是  
「同卷、但不同目录」。

> 想彻底简化可以改后端两处之一：给 `iter_files` 加一条目录排除，或把 `STAGING_DIR`  
> 从 property 改成可配置字段。在那之前按上面的约束配，并靠 `make check` 兜住。

### 4.2 音频分发：X-Accel-Redirect 而不是 FileResponse

不要把几十 MB 的音频塞进 Python 进程吐出去（占 worker、占内存、Range 处理复杂）。  
让 FastAPI 只做鉴权，然后甩给 nginx：

```python
# musicbase/api/tracks.py
import urllib.parse
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response

router = APIRouter()

@router.get("/tracks/{track_id}/stream")
def stream(track_id: int, user=Depends(current_user)):
    track = get_track_or_404(track_id)
    if not os.path.exists(track.path):
        raise HTTPException(404, "文件不存在，可能需要重新扫描")
    # 相对于 location ^~ /media/ 的 alias 路径，必须 URL 编码
    inner = "/media/" + urllib.parse.quote(track.path.removeprefix(MUSIC_LIBRARY_DIR).lstrip("/"))
    # 关键点：这里故意【不设】Content-Type。
    # Starlette 对无 body 的 Response 不会自动补 content-type，
    # 于是 nginx 会按落盘文件的扩展名自己去查 types 表（见下一节）。
    return Response(
        status_code=200,
        headers={
            "X-Accel-Redirect": inner,
            "Content-Disposition": f"inline; filename*=UTF-8''{urllib.parse.quote(track.filename)}",
            # 想要"下载"而不是"边下边播"时改用 attachment
        },
    )
```

nginx 侧 `/media/` 标了 `internal`，外部直连一律 404；配合一次性签名 token 就能做有效期控制。  
**Range（拖动进度条 / PWA 离线缓存分片）由 nginx 天然支持**，比在 Python 里手写 206 稳得多。

不要鉴权、内网可信的场景，把 `internal;` 删掉即可直接静态分发。

### 4.2.1 Content-Type 到底由谁决定（mp3 / flac 要不要区分）

**结论：要区分，但不要为此给 track 模型加 mime 字段；让 nginx 按扩展名判，把缺失的音频类型补进 nginx 的 types 表。**

先说清楚 X-Accel-Redirect 的行为（nginx 核心开发者 Maxim Dounin 在官方邮件列表的原话：  
*"If not explicitly set by script together with X-Accel-Redirect, Content-Type will be set by  
nginx according to extension of the redirect destination and types/default_type defined"*）：

| 后端有没有返回 `Content-Type` | nginx 的行为                                                  |
| ---------------------- | ---------------------------------------------------------- |
| **没返回**（推荐）            | 按重定向目标的**扩展名**查 `types` 表；查不到就用该 location 的 `default_type` |
| **返回了**                | 原样照发后端的值——**写错了也照发**，包括写成 `text/html` 这种灾难值                |

所以两条路都通，但**不要混着走**：一旦决定由 nginx 判，后端就必须彻底不设这个头。

**为什么必须是 nginx 判，而不是后端计？** 因为这里藏着一个真 bug：

nginx 官方 `conf/mime.types` 的音频部分只有 5 条：

```
audio/midi mid midi kar;  audio/mpeg mp3;  audio/ogg ogg;  audio/x-m4a m4a;  audio/x-realaudio ra;
```

**没有 flac。** 也没有 wav / opus / aac / ape / dsf。  
于是 `.flac` 查表失败 → 落到 `default_type application/octet-stream`；再叠加本配置里的  
`X-Content-Type-Options: nosniff`（浏览器失去了嗅探兜底）→ `<audio>` 直接  
*"Failed to load because no supported source was found"*。mp3 没事、flac 全挂，非常难查。


**修复方案**（本仓库已内置）：`docker/nginx/mime.types.audio` 补齐全部音频后缀，在 `nginx.conf`  
的 http 层 include——nginx 的 `types` 块允许多次出现且**有累加语义**（同名扩展后者覆盖前者），  
所以官方表在前、补充表在后即可：

```nginx
include       /etc/nginx/mime.types;
include       /etc/nginx/mime.types.audio;   # audio/flac flac; audio/wav wav; audio/opus opus; ...
default_type  application/octet-stream;      # 兜底给 cue / log / 封面原图等杂项
```

另外三条硬性约束：

1. `/media/` 里**绝不能写 `types { }`**——空块会清空该 location 的整张类型表，连 mp3 都退化成 octet-stream。
2. `/artwork/` 不要设 `default_type image/jpeg`——缓存文件名必须带真实扩展名（`.webp`/`.jpg`/`.png`），同一目录混 webp 和 jpg 时会被误判成同一类型。
3. `limit_rate_after` 建议 ≥16MB：无损单曲常见 30~50MB，前段限速会让起播明显卡顿。

#### track 模型要不要加 mime 字段

**不要。** 三个理由：

| 维度    | 结论                                                                  |
| ----- | ------------------------------------------------------------------- |
| 真相来源  | Content-Type 的事实来源是**磁盘上的扩展名**，DB 字段只是它的副本；用户改了文件名就漂移，而漂移版本往往是错的那一份 |
| 维护成本  | 加了就要维护映射表、迁移脚本、回填逻辑，而 nginx 侧一张 types 表就够                           |
| 一致性风险 | 后端写 `audio/mpeg`、nginx 实际按扩展名发 `audio/flac`，两边打架时排查成本极高             |

后端代码里完全不需要知道它是 mp3 还是 flac——它连文件都没读。

#### 边界情况：无扩展名 / 扩展名撒谎的文件

如果音乐库里存在 `track_001`（无后缀）或把 FLAC 存成 `.bin` 的文件，纯靠后缀确实失效。  
**这种脏数据应该在入库时就被拦住，而不是在分发时补救**：扫描时对不存在于白名单后缀、  
或扩展名与实际容器帧头不符的文件打个 `needs_attention` 标记，在前台提示用户重命名。

真要给这类文件兜底，可以让后端显式设 Content-Type（此时 nginx 会照发），只在检测到  
"扩展名不可信"时启用，正常文件仍然走 nginx 判定：

```python
# musicbase/util/audio.py
_EXT_MIME = {
    ".mp3": "audio/mpeg",
    ".flac": "audio/flac",     # IANA 标准名，不要用旧的 audio/x-flac
    ".wav": "audio/wav", ".m4a": "audio/x-m4a", ".ogg": "audio/ogg",
    ".opus": "audio/opus", ".aac": "audio/aac", ".ape": "audio/x-ape",
    ".dsf": "audio/x-dsf", ".wv": "audio/x-wavpack", ".wma": "audio/x-ms-wma",
}

def content_type_for(path: str) -> str | None:
    """只在需要【显式覆盖】时调用；正常路径请让它返回 None 并交給 nginx。"""
    return _EXT_MIME.get(os.path.splitext(path)[1].lower())
```

#### 顺带提醒（播放侧）

iOS Safari 原生不支持 FLAC。PWA 里要么由服务端用 ffmpeg 转 AAC/Opus（`INSTALL_FFMPEG=true`），  
要么在前端对 `audio/flac` 源给出明确提示，别让用户对着静音的播放器发呆。

### 4.2.2 容器间寻址：`upstream` 里的 `api` 到底是什么

```nginx
upstream musicbase_api { server api:8000; }
```

**`api` 就是 `docker-compose.yml` 里 `services:` 下面那个服务名**，没有别的地方定义它。  
Compose 会把 service 名注册成该容器在 `musicbase-net` 网络上的 **network alias**，  
容器内的嵌入式 DNS（`cat /etc/resolv.conf` 会看到 `nameserver 127.0.0.11`）负责回答这类查询。

#### 为什么不能写 0.0.0.0

因为这两个位置上的 `0.0.0.0` 是**相反方向**的同一符号：

| 位置                                              | 语义                          | 例子                |
| ----------------------------------------------- | --------------------------- | ----------------- |
| **`--host 0.0.0.0`**（uvicorn / nginx listen）    | **监听**本机所有网卡 —— 接受来自任何地方的连接 | 后端必须这样，否则容器外连不进来  |
| **`upstream server 0.0.0.0`**（nginx 的 `server`） | **连接**到目标主机                 | 我们要用这个去连别人，不是等别人连 |

`connect("0.0.0.0:8000")` 在 Linux 上等价于连本机回环。**nginx 容器里没有进程监听 8000**，  
所以结果是 `502 Bad Gateway`——而且报错信息完全不会提示是这个原因。

#### 四种写法的对比

| 写法                                          | 结果                                                                                 |
| ------------------------------------------- | ---------------------------------------------------------------------------------- |
| `server api:8000`                           | ✅ 推荐。靠 DNS 服务名，与 IP 解耦                                                             |
| `server 0.0.0.0:8000`                       | ❌ 连到 nginx 自己，502                                                                  |
| `server 127.0.0.1:8000`                     | ❌ 同上，只是写得更直白                                                                       |
| `server 宿主机IP:8000`                         | ⚠️ 需要先把 api 的 8000 端口 `ports` 映射出来才行；绕过了容器网络、还得额外暴露端口，没必要                          |
| `server musicbase-api:8000`（container_name） | ⚠️ 能解析（container_name 也会注册进 DNS），但**不要依赖**：它会阻止将来 scale，而且和 service 名不一致，后来接手的人会困惑 |

> 顺带说清楚 `container_name`（`musicbase-api`/`musicbase-db`/`musicbase-web`）的作用：  
> 它只是为了方便你敲 `docker logs musicbase-api`，**与容器间寻址没有任何关系**。

#### 隐藏的坑：nginx 只解析一次主机名

上面说的 DNS 只在**容器运行期间**有效，但 **nginx 对 `upstream` 里的主机名只在自己启动时解析一次**，  
之后就一直用缓存的 IP。而 Docker 容器每次重建都会拿到新 IP —— 于是：

```
docker compose restart api   →  api 换成新 IP
                             →  nginx 还在连旧 IP
                             →  全部 /api/ 请求 502，只能重启 nginx 容器恢复
```

这个坑很隐蔽：现象是"重启后端之后前端挂了"，但后端日志一切正常。

**本仓库采用的解法：给容器钉静态 IP**（`docker-compose.yml` 末尾的 `ipam` 配置，  
默认把 api 固定在 `172.28.0.10`、db 固定在 `172.28.0.11`）。IP 不变，  
DNS 缓存就不可能过期，upstream 的 keepalive 与健康检查也一并保留。

备选方案（适合将来要 scale 的场景）：让 nginx 走运行时解析 —— 代价是要放弃 upstream 块  
（也就失去了 keepalive 和健康检查），单机单副本场景不划算：

```nginx
http {
    resolver 127.0.0.11 valid=30s ipv6=off;   # Docker 内嵌 DNS
}
# location 内：
location ^~ /api/ {
    rewrite ^/api/?(.*)$ /$1 break;      # 剥掉 /api 前缀
    set $upstream_api "api:8000";        # 变量形式才会触发运行时解析
    proxy_pass http://$upstream_api;     # 注意：用了变量后 URI 不再自动拼接，故上面先 rewrite
    ...
}
```

#### 启动顺序

`upstream` 里的主机名如果**在 nginx 启动时解析不到**，nginx 会直接  
`[emerg] host not found in upstream "api"` 退出。  
compose 里已经有 `depends_on: api: condition: service_started` 保证 api 先起来  
（容器一 started 就注册进网络并可解析，不需要等到 healthy）。

> ⚠️ 网络（`ipam` / `subnet`）的改动**不会热生效**。改完必须：  
> `docker compose down && docker compose up -d`

### 4.3 artwork 缓存

- 目录：容器内 `/var/lib/musicbase/media/artwork`，即 `MEDIA_ROOT/artwork`（由 `config.py` 派生）。  
  对应宿主目录是 `ARTWORK_DIR`；**必须持久化**，丢了要重扫全库。
- 早前版本写成 `/var/lib/musicbase/artwork` 是**错的**——那是 `MEDIA_ROOT` 本身，  
  照那样挂载会让 artwork 跑到 `<MEDIA_ROOT>/artwork/artwork` 去。
- 子目录结构由代码决定：`tracks/ albums/ artists/ playlists/ tmps/`，  
  `entrypoint.sh` 启动时会一并建好并对齐属主（因为它们在持久卷上，属主可能是 root）。
- nginx 只读挂载同一个目录 → 命中就 nginx 直出，不经过 Python。
- 建议用 `sha256(source_key + size)` 做文件名，两级前缀分目录（`ab/abcdef....jpg`），避免单目录几万文件。
- 大封面/HEIC：Pillow 不解 HEIC，需要 pillow-heif；`INSTALL_FFMPEG=true` 可处理视频音轨封面。

### 4.4 中文文件名

Debian slim 镜像默认 `LANG` 为空会导致 Python 用 ASCII 编解码文件名 → `UnicodeEncodeError`。  
已在镜像里固定：

```dockerfile
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONUTF8=1
```

配合：所有 `open()` / `os.listdir()` 不要手工 `.encode()`；DB 侧用 `utf8mb4`→PG 本身就是 UTF-8，注意 `pg_dump` 恢复时客户端也要 UTF-8。

### 4.5 音乐库监控：独立的 `watcher` 服务

后端有两套 watcher 实现，**互斥，只能开一套**：

| 实现                                  | 形态                                | 用途                                  |
| ----------------------------------- | --------------------------------- | ----------------------------------- |
| `app/background/watcher.py`         | 独立进程                              | **容器里用这个** → compose 的 `watcher` 服务 |
| `app/background/watcher_manager.py` | 进程内，由管理端 `/admin/startwatcher` 触发 | 本地开发用（没装 supervisor 时）              |

`watcher.py` 的文件头注释就写明了这条约定：

> *If use watcher in separated process, ... disable trigger in the frontend.*

**⚠️ 千万不要两边同时开。** 两个 watcher 会各自收到同一个文件的创建事件，  
各走一遍"解析标签 → 入库 → 生成封面" —— 结果是重复 Track、甚至并发写库。  
容器方案启用后，管理端**不要再点"启动监控"**（`POST /api/v1/admin/startwatcher`），  
`make check` 会检测后端是否还留着这个端点并提醒。

#### 为什么是独立容器，而不是在 api 容器里塞 supervisor

Docker 本身就是进程管理器。拆开之后：

- `restart: unless-stopped` 独立生效 —— watcher 崩了自动拉起，**不影响 API**
- `docker compose logs -f watcher` 独立看日志
- 可以单独 `docker compose restart watcher` 重载监控，不动 API

后端自带的 `deploy/supervisor.conf.template`（api + watcher 两个 program）适用于  
**非容器**部署。容器里再套一层 supervisor，等于往一个容器里塞两个进程，  
反而丢掉上面这些能力，PID 1 的信号语义也会变复杂。

#### 它与 api 的唯一差别

compose 用 YAML 锚点让 watcher 直接复用 api 的 `build` / `env_file` / `environment` /  
`volumes`（`<<: *api-env`），只覆盖三项 —— 这样两边**不可能**跑到不同的音乐库上：

| 项                          | 为什么必须不同                                     |
| -------------------------- | ------------------------------------------- |
| `RUN_MIGRATIONS=false`     | 迁移只能跑一次。两个容器同时 `alembic upgrade head` 会互相撞锁 |
| `LOG_DIR=.../logs/watcher` | 见下                                          |
| `healthcheck.disable=true` | 镜像自带的 `/healthz` 探测对它必然失败，会永远显示 unhealthy   |

**日志为什么必须分开**：后端 `app/core/logger.py` 用的是  
`RotatingFileHandler(filename=LOG_DIR/'app.log', maxBytes=2MB, backupCount=5)`，  
而这个 handler 的轮转**不是多进程安全的** —— 两个进程写同一个文件会在轮转时  
互相截断、丢日志。所以给 watcher 单独一个子目录（两者仍在同一个 `logs` 卷里）：

```bash
docker compose exec api     tail -f /var/lib/musicbase/logs/app.log
docker compose exec watcher tail -f /var/lib/musicbase/logs/watcher/app.log
```

> 顺带说明一个容易误判的现象：`logger.py` 只在 `DEBUG=true` 时才给 `app` logger  
> 挂 console handler，生产（`DEBUG=false`）应用日志**只写文件** —— 所以  
> `docker logs api` 里看不到业务日志是**设计如此**，不是没启动。  
> 但 `DEBUG=true` 会让 `stream.py` 改走 Python 直读文件的分支（绕过 nginx 的  
> X-Accel-Redirect），生产环境**不要**开。想看实时日志请 tail 文件。

#### 监控模式：inotify 还是 polling（不处理会静默失效）

| 运行环境                               | 该用        | 原因                                                     |
| ---------------------------------- | --------- | ------------------------------------------------------ |
| Linux 直挂 ext4/btrfs/xfs            | `inotify` | 事件驱动，毫秒级、几乎不耗 CPU                                      |
| **Windows / macOS Docker Desktop** | `polling` | bind mount 走 9p / gRPC-FUSE，**宿主侧的改动经常收不到 inotify 事件** |
| NFS / SMB 网络挂载                     | `polling` | inotify 对网络文件系统本来就无效                                   |

**本栈默认给 `polling`**：它慢一点（有轮询间隔），但换任何环境都能工作；  
inotify 在上面后两种场景里**不报错、只是永远不触发** —— 容器正常启动、日志照打  
`Watcher started.`，你往音乐库里丢歌却永远不入库。这是最难查的一类故障。

> Linux 上还有个内核上限要注意：容器里的 inotify 配额来自宿主机，大库（几万目录）  
> 可能撞上 `fs.inotify.max_user_watches`，表现为**部分**目录不触发。  
> 查看/调整：`sysctl fs.inotify.max_user_watches`（默认 8192～65536），  
> 在宿主机改 `/etc/sysctl.conf` 后 `sysctl -p`。

⚠️ **但 `WATCH_MODE` 目前仍是"配了不生效"**：`watcher.py` 里写死了

```python
from watchdog.observers import Observer     # ← inotify，且完全没读 WATCH_MODE
...
observer = Observer()
```

要让它真正生效，给后端打一个 4 行的小补丁（`app/background/watcher.py`）：

```python
# ① 顶部 import 区
import os
from watchdog.observers.polling import PollingObserver

# ② MusicLibraryWatcher.run() 里，把 `observer = Observer()` 换成：
if os.getenv('WATCH_MODE', 'polling').strip().lower() == 'polling':
    interval = float(os.getenv('WATCH_POLL_INTERVAL_MS', '3000')) / 1000.0
    observer = PollingObserver(timeout=interval)      # timeout 单位是秒
    logger.info(f'Watcher 使用 polling 模式（间隔 {interval}s）')
else:
    observer = Observer()
```

（也可以把 `WATCH_MODE` / `WATCH_POLL_INTERVAL_MS` 加成 `Settings` 字段再读  
`settings.WATCH_MODE`，与项目其他配置风格一致，非必须。）

打完补丁后 `make check` 里那条 ⚠️ 会**自动变成 ✓**（它就是这么判定的）。  
**在这之前，请用管理端的"手动触发全量扫描"来入库。**

### 4.6 PWA 与 IndexedDB

- `sw.js` / `manifest.webmanifest` 已在 nginx 里强制 `no-store`，否则更新永远不生效。
- 音频离线缓存请**按 Range 分片**写入 IndexedDB，别整文件 `new Blob()` → 大文件会把 IndexedDB 撑爆配额。
- Service Worker 的 `navigateFallback` 白名单要排除 `/api/` 和 `/admin/`，否则后台的水合会被 SW 劫持：

```js
// vite.config.ts (musicplayer)
VitePWA({
  workbox: {
    navigateFallback: '/index.html',
    navigateFallbackDenylist: [/^\/api\//, /^\/admin\//, /^\/media\//, /^\/artwork\//],
    globPatterns: ['**/*.{js,css,html,woff2,svg,png}'],   // 别把 mp3/flac 打进 precache
    maximumFileSizeToCacheInBytes: 5 * 1024 * 1024,
  },
})
```

### 4.7 权限

- 容器进程以 `PUID:PGID` 运行（entrypoint 里 `useradd` + `gosu` 降权）。PUID/PGID **必须等于宿主机音乐库目录属主**，否则标签编辑会 Permission denied。
- nginx 只**读**音乐库（`rw` 给了 api），`:ro` 挂载把"Web 层碰不到音频文件"变成硬约束。
- 不要轻易 `chown -R` 你的音乐库（百万级小文件会把 NAS 打满 IO）；真需要时设 `CHOWN_LIBRARY=true` 由容器做一次，之后关掉。

### 4.8 上传

nginx `client_max_body_size 0`（不限），实际限额交给 FastAPI。落盘位置全部由 `MEDIA_ROOT`  
派生 —— 后端 `config.py` 里这些都是**只读 property，不是独立挂载点**：

```
MEDIA_ROOT/uploads/temp/<uuid>/     ← 上传缓冲区（TEMP_DIR）
MEDIA_ROOT/uploads/staging/         ← 待归档暂存区（STAGING_DIR）
```

推荐两步式：

```
POST /api/v1/uploads         → 收流落盘到 TEMP_DIR
POST /api/v1/uploads/commit  → 校验标签 → 移入 STAGING_DIR → shutil.move 入库
```

**为什么不用容器内的 `/tmp`**：`/tmp` 通常很小（或挂 tmpfs 吃内存），大文件上传会直接  
ENOSPC；而 `MEDIA_ROOT` 落在宿主目录 `MEDIA_DIR` 上，空间由你控制，归档中断后也能直接  
进宿主目录手工清理残留。前提仍是 §4.1 那条：`MEDIA_DIR` 与 `MUSIC_DIR` 必须同卷。

---

### 4.9 音频指纹 fpcalc：装法有个反直觉的坑

上传/整理时会生成 AcoustID 指纹，调用链是：

```
app/utils/aidmatch.py  →  pyacoustid (acoustid.py)  →  执行 fpcalc 可执行文件
                                                        ↑ acoustid.py:
                                                          fpcalc = os.environ.get('FPCALC', 'fpcalc')
```


所以镜像里必须有 `fpcalc`。**本栈已内置**（`docker/backend/Dockerfile` 的 fpcalc stage），  
后端代码一个字都不用改。

#### 为什么不用 `apt install libchromaprint-tools`

这是本篇最反直觉的一条。Debian 确实打包了 fpcalc，但它会连带装上  
`libchromaprint.so.1`，而 pyacoustid 的判断是：

```python
if have_audioread and have_chromaprint and not force_fpcalc:
    return _fingerprint_file_audioread(path, maxlength)   # ← lib 一存在就走这里
else:
    return _fingerprint_file_fpcalc(path, maxlength)      # ← 只有它才用 fpcalc
```

`libchromaprint.so.1` 一存在，`have_chromaprint` 就是 `True`，指纹**改走 audioread 分支**  
（在 Python 侧解码音频），而 audioread 还需要 GStreamer 或 `ffmpeg` 可执行文件才能解码。  
结果：你明明装了 fpcalc，指纹却报 `Fingerprint generation failed`。

**结论：只装 fpcalc，不要装 libchromaprint。**（反过来说，这也是为什么本栈  
`INSTALL_FFMPEG=false` 时指纹照样能用 —— fpcalc 自带解码能力。）

#### 用的是 chromaprint 官方静态二进制

来自 <https://github.com/acoustid/chromaprint/releases>，版本由 `FPCALC_VERSION` 控制（当前 `1.6.1`）。  
它恰好满足两个条件：

1. **完全静态**：chromaprint 的 `package/build.sh` 用了 `-DBUILD_SHARED_LIBS=OFF`，  
   linux-x86_64 还显式加了 `-static -static-libgcc -static-libstdc++`，FFmpeg 也换成  
   acoustid 自己构建的 **audio-only 静态包（8.0）**。  
   → 自带 mp3/flac 解码，不依赖系统任何 `.so`，换发行版也不会挂，体积仅 ~2MB。
2. **多架构**：构建时按 `TARGETARCH` 选 `linux-x86_64` 或 `linux-arm64`。  
   NAS 多为 arm64，装错架构要到第一次上传时才炸，所以构建期会跑一次 `fpcalc -version`  
   自检 —— 架构不匹配、缺动态库都会在 `docker compose build` 阶段就暴露。

另：下载的 tar.gz 会做 **sha256 校验**（校验值取自 release 页面）。

#### 下载不下来怎么办

官方包在 GitHub Releases 上，国内直连常常失败（`curl: (35) ...` / 连接被重置）。  
用加速前缀即可，`.env` 里加一行：

```ini
FPCALC_MIRROR=https://ghfast.top/https://github.com
```

临时救急也可以手动 `docker cp`（重建容器即失效，不推荐长期用）：

```bash
docker cp ./fpcalc musicbase-api:/usr/local/bin/fpcalc && docker compose restart api
```

#### 验证

```bash
docker compose exec api fpcalc -version
# 预期输出形如：fpcalc version 1.6.1 (FFmpeg ...)
```

---

## 5. 配置管理：两份 `.env`，各管一摊

### 5.1 结论先行：把两种身份拆开

顶层 `.env` 一度同时承担两件事：

| 身份           | 谁消费                          | 举例                                          |
| ------------ | ---------------------------- | ------------------------------------------- |
| compose 插值参数 | `docker-compose.yml` 的 `${}` | `MUSIC_DIR`、`HTTP_PORT`、`IMAGE_TAG`         |
| 后端应用配置       | 后端 `Settings`（经 `env_file`）  | `SECRET_KEY`、`ACOUSTID_API_KEY`、`NETEASE_*` |

**这两种身份会重合，而且是真问题。** 按当时的写法统计，顶层 `.env` 25 个变量里  
**10 个既被 compose 插值、又被整份文件原样灌进容器** —— 包括  
`MUSIC_DIR`（宿主机路径 `/volume1/music`）、`BACKUP_DIR`、`HTTP_PORT`、`IMAGE_TAG`。

容器里多出 `MUSIC_DIR=/volume1/music` 本身不报错（后端 `extra='ignore'` 会忽略），  
但它是一颗定时炸弹：**哪天后端给 `Settings` 加一个叫 `MUSIC_DIR` 的字段**  
（按语义非常可能），它会静默读到那个宿主机路径 —— 而那个路径在容器里根本不存在。  
到时候你会看到"文件找不到"，而不是"配置错了"。

所以现在拆成两份，职责正交：

| 文件               | 定位         | 内容                                                    | 进容器？                  |
| ---------------- | ---------- | ----------------------------------------------------- | --------------------- |
| `.env`（仓库根）      | **编排参数**   | 宿主机目录、端口、Postgres 凭据、构建开关、网络                          | ❌ 只被 compose `${}` 引用 |
| `musicbase/.env` | **后端应用配置** | `SECRET_KEY`、`ACOUSTID_API_KEY`、`NETEASE_*`、`DEBUG` … | ✅ 经 `env_file` 注入 api |

判定标准只有一条：**这个值换台主机要不要改？**

- 要改，且只有 compose 关心 → 顶层 `.env`
- 要改，且只有后端关心 → `musicbase/.env`
- 不改，且是"容器内部视角" → 直接写死进 compose 的 `environment`

配套的两条硬约束（`make check` 会自动查）：

- `env_file` 必须指向 `musicbase/.env`，指回顶层 `.env` 会报错；
- 顶层 `.env` 里出现 `SECRET_KEY` / `ACOUSTID_API_KEY` 之类会告警。

> 常见误解：**顶层 `.env` 不会自动进容器**。Compose 规范里负责把变量送进容器的是  
> `env_file`（"adds environment variables to the container based on the file content"），  
> 顶层 `.env` 只参与 compose 文件自身的 `${}` 插值。你在它里面写 `SECRET_KEY`，  
> 不声明 `env_file` / `environment` 的话容器里根本看不到。

`env_file` 用了 `format: raw`（需 Compose ≥ 2.30），让 Compose **不做** `${}` 插值：

```yaml
env_file:
  - path: musicbase/.env
    format: raw
```

这样它和本地 `python-dotenv` 的读取行为**严格一致** —— 否则同一个含 `$` 的  
`SECRET_KEY`，本地跑和容器跑会解析成两个不同的值，而这类问题极难发现。  
用 `raw` 的代价是失去 `${VAR}` 引用能力，对本项目没有影响。

### 5.2 为什么放在 `musicbase/.env` 而不是别处

1. **和后端源码同处一室** —— 后端开发者本地起服务时读的就是它，  
   不必知道 umbrella 仓库的存在，也不需要维护第二份副本。
2. **`cp musicbase/.env.example musicbase/.env` 直接可用** —— 字段清单天然与后端同步，  
   不会出现"umbrella 这边漏写了一个新字段"。
3. **一份配置服务两种运行方式**。这不矛盾，因为环境相关的值由 compose 覆盖  
   （Compose 规范："values set by `environment` have precedence"）：
   | 变量                   | 本地起服务                 | 容器内                        | 靠谁覆盖                  |
   | -------------------- | --------------------- | -------------------------- | --------------------- |
   | `DB_HOST`            | `127.0.0.1`           | `db`                       | compose `environment` |
   | `MUSIC_LIBRARY_PATH` | `D:\tmp\testmusiclib` | `/music`                   | compose `environment` |
   | `MEDIA_ROOT`         | `.\media`             | `/var/lib/musicbase/media` | compose `environment` |
   | `SECRET_KEY`         | 同一个值                  | 同一个值                       | 无需覆盖                  |

所以 `make check` 不会因为 `musicbase/.env` 里写着 `DB_HOST=127.0.0.1` 而报错——  
它只会提示"其中 N 个是环境相关键，容器内会被 compose 覆盖"。**这是设计，不是冗余。**

> pydantic-settings 侧的优先级（官方原文）：  
> "**environment variables will always take priority over values loaded from a dotenv file**"。  
> 顺序为：显式传参 > 环境变量 > `.env` 文件 > 字段默认值。  
> 容器里 `/app` 下没有 `.env`（`.dockerignore` 已用 `**/.env` 排除），  
> 所以后端在容器内只会走"环境变量"这一层。
>
> ⚠️ `.dockerignore` 里那条 `**/.env` 是**必须的安全措施**——否则你本地那份装着真实  
> `SECRET_KEY` 和数据库密码的 `musicbase/.env` 会被 `COPY musicbase/ /app/` 打进镜像。  
> 这点在拆文件之后反而更关键：现在密钥文件就在构建上下文里面。

### 5.3 变量名必须对齐**代码**，不是对齐 `.env.example`

这条我栽过两次，值得写清楚。

第一轮按通用经验起名；第二轮改用你的 `.env.example` 当依据——但 `.env.example`  
里的注释是给人看的，**字段到底存不存在、是不是可配置，只有 `app/core/config.py` 说了算**。  
第三轮读了代码，又揪出六个：

| 我之前写的（❌）                                     | 代码里的真相（✅）                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------------- |
| `MUSIC_LIBRARY_DIR`                          | `MUSIC_LIBRARY_PATH`                                                      |
| `MEDIA_ROOT=/var/lib/musicbase/artwork`      | `MEDIA_ROOT` 是**媒体根目录**，artwork 只是它下面的子目录                                 |
| `ARTWORK_CACHE_DIR` / `ARTWORK_URL_PREFIX`   | 两个都不存在，artwork 由 `MEDIA_ROOT` 派生且是只读 property                             |
| `MUSIC_STAGING_DIR` / `TMP_DIR` / `DATA_DIR` | 都不存在。`STAGING_DIR` / `TEMP_DIR` 是 property，由 `MEDIA_ROOT` 派生，**环境变量设不进去** |
| `DATABASE_URL`（单串，psycopg 风格）                | 不能设。代码里 scheme 写死 `postgresql+asyncpg`，给 psycopg 的 URL 会连不上               |
| `MEDIA_URL_PREFIX`                           | 不存在。对应字段叫 `MUSIC_STATIC_PREFIX`，且值必须是 `/media/`                           |

后四条都是**真 bug**，不是命名风格问题：

1. **`MEDIA_ROOT` 配错** → artwork 会落到 `<MEDIA_ROOT>/artwork/artwork`，nginx 找不到文件；
2. **`MUSIC_STAGING_DIR` 设了不生效** → 你以为什么都配好了，实际暂存区仍在  
   `MEDIA_ROOT/uploads/staging`，可能和音乐库不同设备（归档降级成复制，见 §4.1）；
3. **`DATABASE_URL` 用 psycopg** → 后端拿到一个指向没装驱动的 URL，连接直接失败；
4. **`MUSIC_STATIC_PREFIX` 留着默认 `/music`** → X-Accel-Redirect 指向 nginx 里  
   不存在的 location，**播放 404**（nginx 侧是 `/media/`，见 §4.2）。

教训：**死变量检测的判据必须是"代码里有没有这个字段"**。拿 `.env.example` 当清单会漏判  
——它只是文档，`config.py` 才是契约。所以现在 `make check` 直接读  
`musicbase/app/core/config.py`，提取字段名和 property 名作为权威清单。

> 同理，`entrypoint.sh` 自己"消费"一个变量不算数：第一轮我在那里用了  
> `MUSIC_STAGING_DIR`，检测就没报——脚本自己设、自己读，等于空转。  
> 现在的判据是"后端代码是否真读"，脚本内的变量单独白名单列出。

### 5.4 几个值上的坑

| 项                                  | 说明                                                                                                                            |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `PORT`                             | 必须和 `Dockerfile` 里 `uvicorn --port 8000` 一致。改端口请改**端口映射** `HTTP_PORT`，别动 `PORT`                                               |
| `DEBUG`                            | 生产务必 `false`。它不只影响日志：`DEBUG=true` 会让 `stream.py` 改走 Python 直读文件的分支（绕过 nginx X-Accel-Redirect），也会让 FastAPI 自己挂 `/media/*` 静态目录 |
| `MUSIC_FILE_EXTENSIONS`            | 值是 JSON 字符串 `[".mp3",".flac"]`，它同时决定 **watcher 监听哪些后缀**                                                                       |
| `NETEASE_COOKIES_FILE`             | 必须落在持久化卷：`/var/lib/musicbase/media/netease_cookies.json`（在 `MEDIA_ROOT` 下），否则容器重建后登录态丢失                                       |
| `FPCALC_VERSION` / `FPCALC_MIRROR` | 构建期参数，见 §4.9。换版本时记得同步更新 Dockerfile 里的 sha256                                                                                  |
| `WATCH_MODE`                       | 只对 `watcher` 服务有意义，且**需先给 `watcher.py` 打补丁**才生效（§4.5）                                                                         |
| 值里的 `$`                            | compose 会对 `env_file` 的未加引号/双引号值做插值，密码里的 `$` 必须写成 `$$`；Compose ≥ 2.30 可改用 `env_file: [{path: .env, format: raw}]` 彻底跳过插值      |

### 5.5 可选增强（不改也完全能跑）

如果将来想把密钥换成 docker secret / 挂载文件，把一行改成可覆盖即可：

```python
env_file=os.getenv("MUSICBASE_ENV_FILE", ".env"),   # 默认行为完全不变
```

### 5.6 防漏配：`make check` 会核对 key 集合

`scripts/check.sh` 拿 `musicbase/.env.example` 当清单，逐个核对每个变量**都有来源**  
（在 `.env` 里，或在 compose 的 `environment` 里），并额外检查：

- `SECRET_KEY` 必须在 `.env` 里（它靠 env_file 注入，compose 没兜底值）
- 硬编码在 compose 里的键（`DB_HOST`、`MEDIA_ROOT` 等）若在 `.env` 又写一遍 → 提示"改了不生效"
- `.env` 里出现裸 `$` → 提示转义

实测效果（用你真实的 `.env.example` 跑过）：一上来就报出  
`NETEASE_PLAYLIST_API` / `NETEASE_SONG_API` 两个变量没有来源，已补进 `.env.example`。

### 5.7 环境变量分层归属：一个变量只在一个地方定义

前面几节解决了"值怎么进容器"，这一节解决"该写在哪儿"。

判据不是"变不变"，而是 **谁有权改它**。本项目有四个地方能写环境变量：

| 层            | 写在哪                       | 判据                   | 进容器？          | 内容                                                  |
| ------------ | ------------------------- | -------------------- | ------------- | --------------------------------------------------- |
| **L1 镜像层**   | `Dockerfile` 的 `ENV`      | 换任何部署环境都一样           | 是（镜像自带）       | `PYTHONUNBUFFERED`、`LANG`/`LC_ALL`、`PATH`           |
| **L2 编排层**   | `compose` 的 `environment` | 编排作者定下的契约            | 是（显式声明）       | 容器路径、`DB_HOST=db`、监听地址、需 `${}` 插值的                  |
| **L3a 编排参数** | 顶层 `.env`                 | 换主机要改，但只有 compose 关心 | **否**         | 宿主机目录、`HTTP_PORT`、`POSTGRES_*`、构建开关                 |
| **L3b 应用配置** | `musicbase/.env`          | 换主机要改，但只有后端关心        | 是（`env_file`） | `SECRET_KEY`、`ACOUSTID_API_KEY`、`NETEASE_*`、`DEBUG` |

覆盖方向：**L3b > L2 > L1**（`environment` 覆盖 `env_file`，`env_file` 覆盖 Dockerfile `ENV`）。  
L3a 不参与覆盖链 —— 它压根不进容器。

之所以把 L3 拆成两半，原因见 §5.1：合成一份时，编排参数会被连带灌进容器（10/25 个变量  
身兼两职），既污染容器环境，又会和后端字段名撞车。

#### 为什么容器路径写 L2 而不是 L1

`MUSIC_LIBRARY_PATH=/music` 这个值本身确实永不变，**但该写 compose，不该写 Dockerfile**。  
原因不是"它会不会变"，而是**它和 `volumes` 是同一份契约的两半**：

```yaml
environment:
  MUSIC_LIBRARY_PATH: /music      # ← 这一半
volumes:
  - "${MUSIC_DIR}:/music"         # ← 和这一半必须同时改
```

把上半截写进 Dockerfile，就等于把一份契约撕成两个文件：改了 `volumes` 忘了改 `ENV`，  
容器里就静默指向一个不存在的目录，而且报错会是"文件找不到"而不是"配置错了"。  
放在 compose 里，改一处时能立刻看到另一处。

同理，`Dockerfile` 里**绝不写密钥**——`ENV` 会固化进镜像层，`docker history` 可见。

#### 目前 `api` 的 `environment` 只剩 20 个键（原来 30 个）

按上面的判据筛过一遍，删掉了三类：

- **与 Dockerfile 重复的**（`PYTHONUNBUFFERED`/`LANG`/`LC_ALL` 等）→ L1 已有
- **换主机要改、且不需要插值的**（`APP_NAME`/`DEBUG`…）→ 定义在 `.env`，经 `env_file` 进容器
- **根本没人读的死变量** → 见下

留下的 20 个都不是冗余，各有明确理由：容器路径（与 `volumes` 成对 4 个）、  
服务发现与监听（4 个）、需 `${}` 插值的凭据（3 个）、与 nginx 耦合的前缀（1 个）、  
权限与启动开关（6 个）、TZ（1 个）、`LOG_DIR`（1 个）。

> 一个刻意的例外：`FPCALC=/usr/local/bin/fpcalc` 写在 **L1（Dockerfile ENV）**。  
> 它是个路径，但指向的是**镜像内自带的工具**（Stage 2 的产物），与 `volumes` 无关、  
> 换任何环境都相同 —— 不属于"编排契约"，所以归 L1 是对的。判据仍是"谁有权改它"。

`watcher` 服务在此基础上多一个 `WATCH_MODE`、并覆盖 `RUN_MIGRATIONS`/`LOG_DIR`  
两项（见 §4.5），其余键全部由锚点继承。

#### 死变量：看起来配了，其实完全不生效

之前 compose 里写过 `WATCH_POLL_INTERVAL_MS` / `SCAN_FOLLOW_SYMLINKS` /  
`UVICORN_LIMIT_CONCURRENCY` / `SQL_ECHO` / `ENVIRONMENT` / `LOG_LEVEL`，但它们  
**在后端 `config.py` 里根本没有对应字段**，也没有任何一行代码读它们。

由于后端 `Settings` 配了 `extra='ignore'`，这类变量**不会报错**，只会静静躺在环境里。  
这比"没配置"更危险：你以为关掉了某个行为，其实它照旧。

处理方式：

- 确实需要的 → 先让后端代码真的读它，再由 `.env` 注入
- 不需要的 → 删掉
- `UVICORN_WORKERS` 例外：它有价值，已让 `entrypoint.sh` 真正消费（追加 `--workers`，  
  且**只对 uvicorn 生效** —— `watcher` 也复用这个 entrypoint，给它追加 `--workers` 毫无意义）
- **`WATCH_MODE` 是"复活"的一个**：它不再是"没人读"，而是由 `watcher` 服务声明、  
  等后端打上 `PollingObserver` 补丁后生效（§4.5）。判据从"有没有人读"变成了  
  "有没有真的生效"，所以 `make check` 会单独检查 `watcher.py` 是否支持 polling。

`make check` 现在会自动抓这类变量（见 §5.8）。

### 5.8 自动检查：把上述每条教训都变成断言

`make check`（`scripts/check.sh`）现在覆盖四组检查。

**A. 环境变量分层归属**

| 检查                               | 抓的问题                                                       |
| -------------------------------- | ---------------------------------------------------------- |
| Dockerfile 是否越界写容器路径             | 契约被撕成两半（**先折叠多行 `ENV` 的 `\` 续行再判**，否则路径落在续行里会漏检）           |
| Dockerfile 是否固化密钥                | 密钥进镜像层，`docker history` 可见                                 |
| compose 是否重复 Dockerfile 的镜像层变量   | 同一件事两处定义                                                   |
| compose 用到的路径是否在 `volumes` 里有挂载点 | 路径指向不存在的目录                                                 |
| 死变量检测                            | compose 里配了，但后端 `config.py`、`entrypoint`、`Dockerfile` 都没消费 |


判据的演进过程值得记下：最初用「entrypoint 有没有提到」→ 漏判（脚本自己设、自己读等于空转）；  
再改成「`.env.example` 里有没有」→ 也漏判（它是文档，不是契约）。  
**现在的判据是"后端 `app/core/config.py` 里有没有这个字段或 property"**，  
扫描范围含 `docker-compose.dev.yml`。

**B. 配置来源分离**

| 检查                               | 抓的问题                          |
| -------------------------------- | ----------------------------- |
| `env_file` 是否指向 `musicbase/.env` | 指向顶层 `.env` 会把宿主机概念灌进容器       |
| 顶层 `.env` 是否混入后端应用配置             | `SECRET_KEY` 之类的密钥出现在只做插值的文件里 |
| `format: raw` 与 Compose 版本是否匹配   | < 2.30 会报未知字段                 |

**C. 音频指纹（fpcalc）** —— 本轮新增

| 检查                            | 抓的问题                              |
| ----------------------------- | --------------------------------- |
| Dockerfile 是否把 fpcalc 装进 PATH | 后端上传时指纹步骤会 `NoBackendError`       |
| 是否显式声明 `FPCALC`               | 取值依赖 PATH 查找，不够确定                 |
| 是否有 `fpcalc -version` 构建期自检   | 架构不匹配 / 缺动态库会拖到第一次上传才暴露           |
| 是否按 `TARGETARCH` 选二进制         | arm64 NAS 装上 x86_64 二进制           |
| **是否用 apt 装了 libchromaprint** | 会劫持 pyacoustid 分支、绕过 fpcalc（§4.9） |

**D. 音乐库监控（watcher）** —— 本轮新增

| 检查                                       | 抓的问题                                  |
| ---------------------------------------- | ------------------------------------- |
| compose 里是否有 `watcher` 服务                | 音乐库变动不会自动入库                           |
| 其 `command` 是否为 `app.background.watcher` | 误指成别的入口                               |
| 是否用 `<<: *api-env` 复用 api 的环境            | 两个进程配置各自演化，看到不同的库                     |
| `RUN_MIGRATIONS` 是否为 false               | 与 api 同时 `alembic upgrade head` 撞锁    |
| `LOG_DIR` 是否与 api 分离                     | `RotatingFileHandler` 多进程轮转同一个文件会丢日志  |
| 健康检查是否 `disable`                         | 没有 HTTP 端口却继承 `/healthz`，永远 unhealthy |
| `watcher.py` 是否支持 `PollingObserver`      | Windows/Mac/NFS 上 inotify **静默不触发**   |
| 后端是否还留着 `/admin/startwatcher`            | 两个 watcher 会把同一文件入库两次                 |

**反向验证记录**（把每一项故意改坏，确认都能抓到）：移除 fpcalc COPY、apt 装  
libchromaprint、去掉多架构处理、去掉构建期自检、删掉 watcher 服务、改错 command、  
去掉环境锚点复用、把迁移/日志/健康检查同时改坏、给 watcher.py 打上 PollingObserver  
补丁 —— 九项全部按预期命中或转绿。

顺带一提，这些检查也照出了我自己犯的错：`UMASK` 原本配了却没人读。处理方式是让  
`entrypoint.sh` 真正消费它（`umask` 决定归档入库、标签改写产生的文件权限），  
而不是一删了之 —— 前提是它确实有该起的作用。

## 6. 后端需要配合的改动清单（checklist）

> 这些是 manifests 解决不了的、必须在代码里对齐的点。

- [ ] 读取所有配置走环境变量（`os.getenv` / pydantic-settings），**路径默认值不要写死绝对路径**
- [ ] 健康检查路由 `/healthz`（或 `/health`），是否带依赖检查可选，返回 200 即可（容器 HEALTHCHECK 用）
  - 现状：**后端还没有这个路由**。镜像的 HEALTHCHECK 已写成「先探 `/healthz`，失败退回  
    FastAPI 自带的 `/openapi.json`」，所以今天容器是健康的；等你加上 `/healthz`，  
    探测会自动切过去，不用改 Dockerfile。
- [ ] **入口包名**：`app.main:app`（已按实际代码写进 Dockerfile CMD，与后端自带的  
  `deploy/supervisor.conf.template` 一致；API 路由统一挂在 `/api/v1`）
- [ ] **监控进程**：容器里跑的是 `python -m app.background.watcher`（独立进程）。
  - [ ] 生产环境**不要**调用 `POST /api/v1/admin/startwatcher`（那是进程内 watcher，  
    同时开会把同一个文件入库两次，见 §4.5）
  - [ ] 建议给 `watcher.py` 打上 `PollingObserver` 补丁，否则 Windows/Mac/NFS 上  
    inotify 静默不触发（补丁见 §4.5，`make check` 会检测）
- [ ] **音频指纹**：无需改动。镜像已内置官方静态 `fpcalc`（§4.9），  
  `os.environ.get('FPCALC', 'fpcalc')` 两种取法都能命中；**不要**再装 `libchromaprint`
- [ ] **配置不需要为 docker 改动**：`Settings` 里的 `env_file='.env'` 保持原样（见 §5.1，环境变量优先级更高，容器里没有 .env 时静默忽略）
- [ ] 新增配置字段时，同步更新 `musicbase/.env.example` —— `make check` 会拿它当清单核对是否漏配
- [ ] 数据库迁移：仓库里有 `alembic.ini` 且在 `/app` 下 → entrypoint 自动 `alembic upgrade head`
- [ ] 所有 SSE/WS 响应加 `X-Accel-Buffering: no`（nginx 已兜一层 `proxy_buffering off`，双保险）
- [ ] `uvicorn` 启动加 `--proxy-headers --forwarded-allow-ips=*`（已在 CMD），FastAPI 设 `root_path="/api"` 或路由不带前缀二选一，与 nginx `proxy_pass` 尾斜杠对齐
- [ ] 扫描/导出/归档这类长任务：走后台任务队列 + 任务表 + SSE 推送进度；`UVICORN_WORKERS` 保持 1（避免多 worker 抢写同一个文件）
- [ ] **事务边界**：DB 记录与文件 rename 无法原子 → 采用"先落库（status=pending）→ 操作文件 → 更新 status=ready"，扫描器以磁盘为准做最终对账
- [ ] 提交 `uv.lock`（推荐）或 `requirements.txt`；切换 uv：

```bash
cd musicbase
uv init --no-readme   # 或已有的话跳过
uv add fastapi uvicorn[standard] psycopg[binary] mutagen pillow python-multipart alembic sqlalchemy
uv lock
```

若坚持 pip，Dockerfile 里 `elif [ -f requirements.txt ]` 分支已支持。

---

## 7. 前端需要配合的改动清单

| 项目          | 改动                                                                                                                       |
| ----------- | ------------------------------------------------------------------------------------------------------------------------ |
| musicplayer | `vite build --base=/`（构建参数 `PLAYER_BASE`，已注入）；所有 `fetch` 走 `import.meta.env.VITE_API_BASE`；音频地址用后端返回的 X-Accel URL 而非直拼路径 |
| musicman    | `vite build --base=/admin/`（构建参数 `MAN_BASE`，已注入）；router 用 `createWebHistory('/admin/')`                                  |
| 两者          | 提供 `package-lock.json`（或改 Dockerfile 里的锁文件分支）                                                                            |

想更彻底地"一处配置"，可以在 `vite.config.ts` 里写：

```ts
export default defineConfig(({ mode }) => ({
  base: process.env.VITE_BASE ?? '/',
  server: { proxy: { '/api': { target: 'http://localhost:8000', changeOrigin: true } } },
}))
```

---

## 8. 日常运维

```bash
make up          # docker compose up -d
make build       # 重新构建镜像
make logs        # 跟日志
make ps
make down        # 停止（保留数据卷）
make backup
make shell-api   # 进后端容器

# 版本升级（PG 大版本除外，直接换 image tag 即可）
docker compose pull db && docker compose up -d db

# 完全清理（⚠️ 会删除数据库数据卷）
docker compose down -v
```

### 排错速查

| 现象                                           | 原因 / 处理                                                                                                                                                                                                                                         |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **watcher 容器在跑，但新歌不入库**                      | ① 后端还没打 `PollingObserver` 补丁，而你在 Windows/Mac 上跑（inotify 静默失效，见 §4.5）；② `WATCH_MODE` 与宿主环境不匹配；③ 文件后缀不在 `MUSIC_FILE_EXTENSIONS` 里（只监听 `.mp3`/`.flac`）。先看 watcher 日志：`docker compose exec watcher tail -f /var/lib/musicbase/logs/watcher/app.log` |
| 同一首歌出现两条记录                                   | 两个 watcher 同时在跑 —— 管理端点过"启动监控"(`/api/v1/admin/startwatcher`)。停掉它，只保留独立进程                                                                                                                                                                        |
| 扫描不到新放进宿主机的歌（手工兜底）                           | 在管理端手动触发一次全量扫描                                                                                                                                                                                                                                  |
| 上传后指纹为空 / `Fingerprint generation failed`    | 见 §4.9：多半是装了 `libchromaprint` 导致 pyacoustid 改走 audioread 分支。先 `docker compose exec api fpcalc -version` 确认工具在                                                                                                                                   |
| `fpcalc not found` / `exec format error`     | 二进制没装进去，或架构装错（arm64 机器装了 x86_64）。检查构建日志里有没有 `[fpcalc] ... linux-arm64` 那行                                                                                                                                                                       |
| `docker compose build` 卡在下载 fpcalc           | GitHub 直连被墙 → `.env` 里设 `FPCALC_MIRROR=https://ghfast.top/https://github.com` 后重跑                                                                                                                                                               |
| `api` 一直显示 unhealthy                         | 后端还没有 `/healthz`，而 HEALTHCHECK 也在探 `/openapi.json`；两者都失败说明进程没起来，看 `docker compose logs api`。若后端把 `/docs`、`/openapi.json` 都关掉了，请补 `/healthz`（见 §6）                                                                                               |
| 标签编辑报 Permission denied                      | PUID/PGID 与音乐库属主不一致 → `stat -c '%u:%g' /path/to/music` 后改 `.env` 重建容器                                                                                                                                                                           |
| `Invalid cross-device link`（或归档"变慢"且偶发残file） | `MEDIA_DIR` 与 `MUSIC_DIR` 不在同一物理卷 → `shutil.move` 跨设备会静默降级成"复制+删除"。用 `stat -c '%d'` 比对设备号，`make check` 也会查                                                                                                                                      |
| 中文歌名乱码 / `UnicodeEncodeError`                | 镜像 `LANG=C.UTF-8` 被覆盖？检查 compose 的 environment                                                                                                                                                                                                  |
| 音频拖动条不能跳进度                                   | 走了 Python `FileResponse` 而不是 X-Accel/nginx；或 nginx 没读到 `Range` 头（检查是否有中间代理剥了 Headers）                                                                                                                                                           |
| **flac 播不了、mp3 正常**                          | nginx 官方 mime.types 没有 flac → `curl -I` 看 `Content-Type` 是否为 `application/octet-stream`。确认 http 层 include 了 `mime.types.audio` 且 `/media/` 里没有 `types { }`；或后端误设了 Content-Type 覆盖了 nginx 判定                                                     |
| 所有音频都 `text/html`                            | 后端连同 X-Accel-Redirect 返回了错误的 Content-Type；把它删掉即可                                                                                                                                                                                                |
| PWA 更新后还是旧页面                                 | `sw.js` 被 CDN/缓存拦住 → nginx 已 `no-store`，检查是否又套了一层反代                                                                                                                                                                                             |
| 456 bailout / 413                            | nginx `client_max_body_size 0` 已放开，问题在后端框架自身限制                                                                                                                                                                                                  |
| 前端 `/admin` 刷新 404                           | 确认 `MAN_BASE=/admin/` 且 `try_files ... /admin/index.html` 存在                                                                                                                                                                                    |

---

## 9. 可选扩展

- **HTTPS**：前面再套一层 Caddy / Traefik（`reverse_proxy localhost:8080`，自动签发证书），本栈保持 HTTP，职责清晰。HTTPS 是 PWA install 与 iOS 音频后台播放的前提。
- **分离情景**：如果希望 player / man 用不同域名，把 `music.conf` 拆成两个 `server` 块、`server_name player.example.com / admin.example.com` 即可，其余不动。
- **CI**：子仓库各自跑测试；umbrella 里 GitHub Actions 做 `docker compose build` + 推送 `musicbase/api`、`musicbase/web` 到私有 registry，服务器 `docker compose pull && up -d`。

