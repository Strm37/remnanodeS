#!/usr/bin/env bash
#
# remnanode.sh — установка и управление нодой Remnawave
# Поддержка: Ubuntu 20.04+ / Debian 11+
#
# Использование:  sudo bash remnanode.sh
#

set -o pipefail

# ─── Цвета ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Пути ────────────────────────────────────────────────────────────
NODE_DIR="/opt/remnanode"
COMPOSE_FILE="${NODE_DIR}/docker-compose.yml"
ENV_FILE="${NODE_DIR}/.env"
LOG_DIR="/var/log/remnanode"

# ─── Вспомогательные функции ─────────────────────────────────────────
msg()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

press_enter() {
    echo
    echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в меню...${NC}"
    read -r
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Запустите скрипт от root:  sudo bash $0"
        exit 1
    fi
}

# ─── Проверка ОС ─────────────────────────────────────────────────────
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "Не удалось определить ОС. Скрипт рассчитан на Ubuntu/Debian."
        exit 1
    fi
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) ok "ОС: $PRETTY_NAME" ;;
        *) warn "ОС '$ID' не тестировалась. Продолжаем на свой риск." ;;
    esac
}

# ─── Установка Docker ────────────────────────────────────────────────
install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        ok "Docker и Docker Compose уже установлены."
        return 0
    fi

    msg "Устанавливаю Docker..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release >/dev/null

    # Официальный установочный скрипт Docker
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1
    rm -f /tmp/get-docker.sh

    systemctl enable docker >/dev/null 2>&1
    systemctl start docker

    if command -v docker &>/dev/null; then
        ok "Docker установлен: $(docker --version)"
    else
        err "Не удалось установить Docker."
        exit 1
    fi
}

# ─── Установка ноды ──────────────────────────────────────────────────
install_node() {
    clear
    echo -e "${BOLD}=== Установка ноды Remnawave ===${NC}\n"

    if [[ -f "$COMPOSE_FILE" ]]; then
        warn "Нода уже установлена в ${NODE_DIR}."
        read -rp "Переустановить заново? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Отменено."; press_enter; return; }
    fi

    check_os
    install_docker

    echo
    echo -e "${BOLD}Данные с панели Remnawave${NC}"
    echo "Откройте панель → Nodes → Management → '+' → создайте ноду."
    echo "Скопируйте SSL_CERT (его содержимое выдаётся при создании ноды)."
    echo

    # NODE_PORT — внутренний порт для связи с панелью
    read -rp "Введите NODE_PORT [по умолчанию 2222]: " node_port
    node_port="${node_port:-2222}"

    # SSL_CERT — выдаётся панелью при создании ноды
    echo
    echo "Вставьте значение SSL_CERT с панели (одной строкой) и нажмите Enter:"
    read -r ssl_cert

    if [[ -z "$ssl_cert" ]]; then
        err "SSL_CERT не введён. Установка прервана."
        press_enter
        return
    fi

    msg "Создаю каталоги и конфигурацию..."
    mkdir -p "$NODE_DIR" "$LOG_DIR"

    # .env
    cat > "$ENV_FILE" <<EOF
### Конфигурация ноды Remnawave
APP_PORT=${node_port}
${ssl_cert}
EOF
    chmod 600 "$ENV_FILE"

    # docker-compose.yml
    cat > "$COMPOSE_FILE" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    restart: always
    network_mode: host
    env_file:
      - .env
    volumes:
      - ${LOG_DIR}:/var/log/remnanode
EOF

    msg "Скачиваю образ и запускаю ноду..."
    cd "$NODE_DIR" || { err "Не удалось перейти в $NODE_DIR"; press_enter; return; }
    docker compose pull && docker compose up -d

    if [[ $? -eq 0 ]]; then
        echo
        ok "Нода установлена и запущена!"
        echo
        echo -e "  Каталог:    ${CYAN}${NODE_DIR}${NC}"
        echo -e "  NODE_PORT:  ${CYAN}${node_port}${NC}"
        echo
        warn "В фаерволе откройте порт ${node_port} ТОЛЬКО для IP вашей панели."
        echo -e "  Пример (ufw): ${CYAN}ufw allow from <IP_ПАНЕЛИ> to any port ${node_port}${NC}"
    else
        err "Запуск завершился с ошибкой. Проверьте логи (пункт меню 4)."
    fi
    press_enter
}

# ─── Обновление ноды ─────────────────────────────────────────────────
update_node() {
    clear
    echo -e "${BOLD}=== Обновление ноды ===${NC}\n"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    cd "$NODE_DIR" || return
    msg "Загружаю свежий образ..."
    docker compose pull
    msg "Перезапускаю контейнер..."
    docker compose down && docker compose up -d
    ok "Обновление завершено."
    press_enter
}

# ─── Статус ──────────────────────────────────────────────────────────
status_node() {
    clear
    echo -e "${BOLD}=== Статус ноды ===${NC}\n"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    cd "$NODE_DIR" || return
    docker compose ps
    echo
    docker stats --no-stream remnanode 2>/dev/null
    press_enter
}

# ─── Логи ────────────────────────────────────────────────────────────
logs_node() {
    clear
    echo -e "${BOLD}=== Логи ноды ===${NC}\n"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    echo -e "${YELLOW}Показ логов в реальном времени. Выход — Ctrl+C${NC}\n"
    sleep 1
    cd "$NODE_DIR" || return
    docker compose logs -f --tail 100
    press_enter
}

# ─── Рестарт / Стоп / Старт ──────────────────────────────────────────
restart_node() {
    clear
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."; press_enter; return
    fi
    cd "$NODE_DIR" || return
    msg "Перезапускаю ноду..."
    docker compose restart && ok "Нода перезапущена."
    press_enter
}

stop_node() {
    clear
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."; press_enter; return
    fi
    cd "$NODE_DIR" || return
    msg "Останавливаю ноду..."
    docker compose down && ok "Нода остановлена."
    press_enter
}

start_node() {
    clear
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."; press_enter; return
    fi
    cd "$NODE_DIR" || return
    msg "Запускаю ноду..."
    docker compose up -d && ok "Нода запущена."
    press_enter
}

# ─── Удаление ────────────────────────────────────────────────────────
remove_node() {
    clear
    echo -e "${BOLD}=== Удаление ноды ===${NC}\n"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    warn "Будут удалены контейнер и каталог ${NODE_DIR}."
    read -rp "Удалить также логи в ${LOG_DIR}? (y/N): " rmlogs
    read -rp "Точно удалить ноду? Введите 'yes' для подтверждения: " confirm

    if [[ "$confirm" != "yes" ]]; then
        warn "Удаление отменено."
        press_enter; return
    fi

    cd "$NODE_DIR" 2>/dev/null && docker compose down
    docker rm -f remnanode 2>/dev/null
    rm -rf "$NODE_DIR"
    [[ "$rmlogs" =~ ^[Yy]$ ]] && rm -rf "$LOG_DIR"

    ok "Нода удалена."
    press_enter
}

# ─── Меню ────────────────────────────────────────────────────────────
show_menu() {
    clear
    local state="не установлена"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
        state="${GREEN}работает${NC}"
    elif [[ -f "$COMPOSE_FILE" ]]; then
        state="${YELLOW}остановлена${NC}"
    else
        state="${RED}не установлена${NC}"
    fi

    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║        REMNAWAVE NODE — УПРАВЛЕНИЕ         ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Состояние ноды: ${state}"
    echo
    echo -e "  ${BOLD}1)${NC} Установить / переустановить ноду"
    echo -e "  ${BOLD}2)${NC} Обновить ноду"
    echo -e "  ${BOLD}3)${NC} Статус ноды"
    echo -e "  ${BOLD}4)${NC} Логи ноды"
    echo -e "  ${BOLD}5)${NC} Перезапустить ноду"
    echo -e "  ${BOLD}6)${NC} Остановить ноду"
    echo -e "  ${BOLD}7)${NC} Запустить ноду"
    echo -e "  ${BOLD}8)${NC} Удалить ноду"
    echo -e "  ${BOLD}0)${NC} Выход"
    echo
}

# ─── Точка входа ─────────────────────────────────────────────────────
main() {
    require_root
    while true; do
        show_menu
        read -rp "Выберите пункт: " choice
        case "$choice" in
            1) install_node ;;
            2) update_node  ;;
            3) status_node  ;;
            4) logs_node    ;;
            5) restart_node ;;
            6) stop_node    ;;
            7) start_node   ;;
            8) remove_node  ;;
            0) echo; ok "Выход."; exit 0 ;;
            *) warn "Неверный пункт."; sleep 1 ;;
        esac
    done
}

main
