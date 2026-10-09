.PHONY: help check init build up down restart ps logs logs-watcher backup shell-api shell-watcher shell-db pull prune dev dev-down

COMPOSE := docker compose

help:
	@echo "check         构建前置自检（依赖清单 / 目录 / 两份 .env / 分层 / 指纹 / watcher）"
	@echo "init          初始化 umbrella 仓库（挂载三个子项目 + 生成两份 .env）"
	@echo "build         构建镜像（含下载 fpcalc 静态二进制）"
	@echo "up            启动全部服务（db / api / watcher / web）"
	@echo "down          停止栈（保留数据卷）"
	@echo "restart       重启 api + watcher + web"
	@echo "logs          跟踪全部容器日志"
	@echo "logs-watcher  只看音乐库监控进程，并自动 tail 它的日志文件"
	@echo "ps            查看状态"
	@echo "backup        备份数据库 + media"
	@echo "shell-api     进入后端容器"
	@echo "shell-watcher 进入监控容器"
	@echo "shell-db      进入 postgres"
	@echo "dev           启动开发模式（vite dev server 热重载）"
	@echo "dev-down      停止开发模式"

check:
	@bash ./scripts/check.sh

init:
	@test -f .env || cp .env.example .env
	@./scripts/init-umbrella.sh
	@test -f musicbase/.env || { \
	  cp musicbase/.env.example musicbase/.env 2>/dev/null \
	    && echo "已生成 musicbase/.env —— 请填写 SECRET_KEY / ACOUSTID_API_KEY" \
	    || echo "未找到 musicbase/.env.example（子项目还没挂载？）"; \
	}

build: check
	$(COMPOSE) build

up: check
	$(COMPOSE) up -d
	$(COMPOSE) ps

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart api watcher web

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=200

# watcher 的应用日志只写文件（见 DEVDOC.md §4.5），所以要进容器 tail，
# 不能只靠 docker logs。
logs-watcher:
	$(COMPOSE) exec watcher tail -f /var/lib/musicbase/logs/watcher/app.log

backup:
	./scripts/backup.sh

pull:
	$(COMPOSE) pull

shell-api:
	$(COMPOSE) exec api bash

shell-watcher:
	$(COMPOSE) exec watcher bash

shell-db:
	$(COMPOSE) exec db psql -U $${POSTGRES_USER:-musicbase} -d $${POSTGRES_DB:-musicbase}

prune:
	docker image prune -f

dev:
	$(COMPOSE) -f docker-compose.yml -f docker-compose.dev.yml up -d

dev-down:
	$(COMPOSE) -f docker-compose.yml -f docker-compose.dev.yml down

