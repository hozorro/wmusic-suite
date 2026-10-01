.PHONY: help check init build up down restart ps logs backup shell-api shell-db pull prune dev dev-down

COMPOSE := docker compose

help:
	@echo "check     构建前置自检（依赖清单 / 目录 / 两份 .env / 分层归属）"
	@echo "init      初始化 umbrella 仓库（挂载三个子项目 + 生成两份 .env）"
	@echo "build     构建镜像"
	@echo "up        启动全部服务"
	@echo "down      停止栈（保留数据卷）"
	@echo "restart   重启 api + web"
	@echo "logs      跟踪日志"
	@echo "ps        查看状态"
	@echo "backup    备份数据库 + artwork"
	@echo "shell-api 进入后端容器"
	@echo "shell-db  进入 postgres"
	@echo "dev       启动开发模式（vite dev server 热重载）"
	@echo "dev-down  停止开发模式"

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
	$(COMPOSE) restart api web

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=200

backup:
	./scripts/backup.sh

pull:
	$(COMPOSE) pull

shell-api:
	$(COMPOSE) exec api bash

shell-db:
	$(COMPOSE) exec db psql -U $${POSTGRES_USER:-musicbase} -d $${POSTGRES_DB:-musicbase}

prune:
	docker image prune -f

dev:
	$(COMPOSE) -f docker-compose.yml -f docker-compose.dev.yml up -d

dev-down:
	$(COMPOSE) -f docker-compose.yml -f docker-compose.dev.yml down

