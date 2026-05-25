#!/usr/bin/env bash
#
# remnanodeS.sh — установка и управление нодой Remnawave
# Поддержка: Ubuntu 20.04+ / Debian 11+
# Репозиторий: https://github.com/Strm37/remnanodeS
#
# Использование:  sudo bash remnanodeS.sh
#

set -o pipefail

# ─── Цвета ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
GRAY='\033[0;90m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Пути ────────────────────────────────────────────────────────────
NODE_DIR="/opt/remnanode"
COMPOSE_FILE="${NODE_DIR}/docker-compose.yml"
ENV_FILE="${NODE_DIR}/.env"
LOG_DIR="/var/log/remnanode"
SCRIPT_PATH="$(readlink -f "$0")"

# ─── Вспомогательные функции ─────────────────────────────────────────
msg()  { echo -e "  ${CYAN}▸${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }
step() { echo -e "\n${BOLD}${BLUE}» $1${NC}\n"; }

# Рисует рамку с заголовком
draw_header() {
    local title="$1"
    echo -e "${BOLD}${CYAN}"
    echo "  ┌────────────────────────────────────────────┐"
    printf "  │ %-44s │\n" "$title"
    echo "  └────────────────────────────────────────────┘"
    echo -e "${NC}"
}

# Анимация выполнения долгой команды с показом её вывода
run_logged() {
    local label="$1"; shift
    echo -e "  ${GRAY}┌─ ${label}${NC}"
    # выводим строки команды с отступом и серым цветом
    "$@" 2>&1 | sed "s/^/  ${GRAY}│${NC} /"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -eq 0 ]]; then
        echo -e "  ${GRAY}└─${NC} ${GREEN}готово${NC}"
    else
        echo -e "  ${GRAY}└─${NC} ${RED}ошибка (код $rc)${NC}"
    fi
    return $rc
}

press_enter() {
    echo
    echo -e "  ${YELLOW}Нажмите Enter, чтобы вернуться в меню...${NC}"
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
        ok "Docker и Docker Compose уже установлены ($(docker --version | cut -d' ' -f3 | tr -d ','))"
        return 0
    fi

    step "Установка Docker"

    run_logged "Обновление списка пакетов" \
        apt-get update

    run_logged "Установка зависимостей" \
        apt-get install -y ca-certificates curl gnupg lsb-release

    msg "Скачиваю официальный установщик Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh

    run_logged "Запуск установщика Docker" \
        sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    run_logged "Включение службы Docker" \
        systemctl enable --now docker

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
    draw_header "Установка ноды Remnawave"

    if [[ -f "$COMPOSE_FILE" ]]; then
        warn "Нода уже установлена в ${NODE_DIR}."
        read -rp "  Переустановить заново? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Отменено."; press_enter; return; }
    fi

    step "Проверка системы"
    check_os
    install_docker

    step "Данные с панели Remnawave"
    echo "  Откройте панель → Nodes → Management → '+' → создайте ноду."
    echo "  Нажмите 'Copy docker-compose.yml' (или 'Important information')."
    echo "  Оттуда нужны два значения: NODE_PORT и SECRET_KEY."
    echo

    read -rp "  Введите NODE_PORT [по умолчанию 2222]: " node_port
    node_port="${node_port:-2222}"

    echo
    echo "  Вставьте строку SECRET_KEY с панели и нажмите Enter."
    echo "  Можно вставить как с именем переменной (SECRET_KEY=...), так и без."
    read -rp "  > " secret_raw

    # Убираем возможное имя переменной и кавычки — оставляем чистое значение
    secret_key="$secret_raw"
    secret_key="${secret_key#SECRET_KEY=}"
    secret_key="${secret_key#SSL_CERT=}"
    secret_key="${secret_key#\"}"; secret_key="${secret_key%\"}"
    secret_key="${secret_key#\'}"; secret_key="${secret_key%\'}"

    if [[ -z "$secret_key" ]]; then
        err "SECRET_KEY не введён. Установка прервана."
        press_enter
        return
    fi

    step "Создание конфигурации"
    msg "Создаю каталоги ${NODE_DIR} и ${LOG_DIR}..."
    mkdir -p "$NODE_DIR" "$LOG_DIR"

    cat > "$ENV_FILE" <<EOF
### Конфигурация ноды Remnawave
NODE_PORT=${node_port}
SECRET_KEY=${secret_key}
EOF
    chmod 600 "$ENV_FILE"
    ok "Файл .env создан (NODE_PORT + SECRET_KEY)"

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
    ok "Файл docker-compose.yml создан"

    step "Загрузка образа и запуск"
    cd "$NODE_DIR" || { err "Не удалось перейти в $NODE_DIR"; press_enter; return; }

    run_logged "Загрузка образа remnawave/node" \
        docker compose pull

    run_logged "Запуск контейнера" \
        docker compose up -d
    local rc=$?

    echo
    if [[ $rc -eq 0 ]]; then
        draw_header "Нода успешно установлена!"
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
    draw_header "Обновление ноды"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    cd "$NODE_DIR" || return

    step "Обновление"
    run_logged "Загрузка свежего образа" \
        docker compose pull
    run_logged "Остановка контейнера" \
        docker compose down
    run_logged "Запуск обновлённого контейнера" \
        docker compose up -d

    echo
    ok "Обновление завершено."
    press_enter
}

# ─── Статус ──────────────────────────────────────────────────────────
status_node() {
    clear
    draw_header "Статус ноды"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    cd "$NODE_DIR" || return
    step "Контейнеры"
    docker compose ps
    echo
    step "Потребление ресурсов"
    docker stats --no-stream remnanode 2>/dev/null
    press_enter
}

# ─── Логи ────────────────────────────────────────────────────────────
logs_node() {
    clear
    draw_header "Логи ноды"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    echo -e "  ${YELLOW}Показ логов в реальном времени. Выход — Ctrl+C${NC}\n"
    sleep 1
    cd "$NODE_DIR" || return
    docker compose logs -f --tail 100
    press_enter
}

# ─── Рестарт / Стоп / Старт ──────────────────────────────────────────
restart_node() {
    clear
    draw_header "Перезапуск ноды"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."; press_enter; return
    fi
    cd "$NODE_DIR" || return
    run_logged "Перезапуск контейнера" docker compose restart
    echo
    ok "Нода перезапущена."
    press_enter
}

stop_node() {
    clear
    draw_header "Остановка ноды"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."; press_enter; return
    fi
    cd "$NODE_DIR" || return
    run_logged "Остановка контейнера" docker compose down
    echo
    ok "Нода остановлена."
    press_enter
}

start_node() {
    clear
    draw_header "Запуск ноды"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."; press_enter; return
    fi
    cd "$NODE_DIR" || return
    run_logged "Запуск контейнера" docker compose up -d
    echo
    ok "Нода запущена."
    press_enter
}

# ─── Удаление ноды ───────────────────────────────────────────────────
remove_node() {
    clear
    draw_header "Удаление ноды"
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        err "Нода не установлена."
        press_enter; return
    fi
    warn "Будут удалены контейнер и каталог ${NODE_DIR}."
    read -rp "  Удалить также логи в ${LOG_DIR}? (y/N): " rmlogs
    read -rp "  Точно удалить ноду? Введите 'yes' для подтверждения: " confirm

    if [[ "$confirm" != "yes" ]]; then
        warn "Удаление отменено."
        press_enter; return
    fi

    step "Удаление"
    cd "$NODE_DIR" 2>/dev/null && run_logged "Остановка контейнера" docker compose down
    docker rm -f remnanode 2>/dev/null
    rm -rf "$NODE_DIR"
    ok "Каталог ноды удалён"
    if [[ "$rmlogs" =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        ok "Логи удалены"
    fi

    echo
    ok "Нода полностью удалена."
    press_enter
}

# ─── Удаление самого скрипта ─────────────────────────────────────────
remove_script() {
    clear
    draw_header "Удаление скрипта"
    warn "Будет удалён сам файл скрипта:"
    echo -e "  ${CYAN}${SCRIPT_PATH}${NC}"
    echo
    echo "  Это НЕ удаляет установленную ноду — только этот скрипт."
    echo "  Чтобы удалить ноду, используйте пункт 8."
    echo
    read -rp "  Удалить скрипт? Введите 'yes' для подтверждения: " confirm

    if [[ "$confirm" != "yes" ]]; then
        warn "Удаление отменено."
        press_enter; return
    fi

    if rm -f "$SCRIPT_PATH"; then
        echo
        ok "Скрипт удалён. До свидания!"
        exit 0
    else
        err "Не удалось удалить скрипт по пути ${SCRIPT_PATH}"
        press_enter
    fi
}

# ─── Управление скоростью (tc / traffic control) ─────────────────────
# Файл, где запоминаем выбранный интерфейс и настройки
TC_STATE="/opt/remnanode/.tc_state"

# Определяет основной сетевой интерфейс (через который идёт интернет)
detect_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# Проверяет, установлен ли пакет с tc
ensure_tc() {
    if ! command -v tc &>/dev/null; then
        warn "Утилита tc не найдена, устанавливаю iproute2..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq iproute2 >/dev/null 2>&1
    fi
    command -v tc &>/dev/null
}

# Показать текущие настройки tc
speed_show() {
    clear
    draw_header "Текущие настройки скорости"
    local iface; iface="$(detect_iface)"
    if [[ -z "$iface" ]]; then
        err "Не удалось определить сетевой интерфейс."
        press_enter; return
    fi
    echo -e "  Сетевой интерфейс:  ${CYAN}${iface}${NC}"
    echo
    step "Дисциплины очередей (qdisc)"
    tc qdisc show dev "$iface"
    echo
    if [[ -f "$TC_STATE" ]]; then
        step "Сохранённая конфигурация скрипта"
        cat "$TC_STATE" | sed 's/^/  /'
    else
        msg "Ограничения скриптом не задавались."
    fi
    press_enter
}

# Установить общий лимит скорости сервера (исходящий трафик)
speed_limit() {
    clear
    draw_header "Общий лимит скорости сервера"
    ensure_tc || { err "Не удалось установить tc."; press_enter; return; }

    local iface; iface="$(detect_iface)"
    if [[ -z "$iface" ]]; then
        err "Не удалось определить сетевой интерфейс."
        press_enter; return
    fi
    echo -e "  Интерфейс: ${CYAN}${iface}${NC}"
    echo
    echo "  Лимит ограничивает ИСХОДЯЩУЮ скорость сервера (отдачу клиентам)."
    echo "  Укажите значение в Мбит/с (например 100, 500, 1000)."
    echo
    read -rp "  Лимит скорости, Мбит/с: " mbit

    if ! [[ "$mbit" =~ ^[0-9]+$ ]] || [[ "$mbit" -le 0 ]]; then
        err "Нужно положительное число."
        press_enter; return
    fi

    step "Применение лимита"
    # Снимаем прежние настройки
    tc qdisc del dev "$iface" root 2>/dev/null
    # HTB-шейпер с общим потолком + fq_codel внутри для честной очереди
    if tc qdisc add dev "$iface" root handle 1: htb default 10 \
        && tc class add dev "$iface" parent 1: classid 1:10 htb \
             rate "${mbit}mbit" ceil "${mbit}mbit" \
        && tc qdisc add dev "$iface" parent 1:10 handle 10: fq_codel; then
        echo "LIMIT_MBIT=${mbit}" >  "$TC_STATE"
        echo "IFACE=${iface}"     >> "$TC_STATE"
        echo "FAIRQUEUE=on"       >> "$TC_STATE"
        echo
        ok "Установлен лимит ${mbit} Мбит/с на интерфейс ${iface}."
        msg "Внутри лимита включена честная очередь (fq_codel)."
    else
        err "Не удалось применить настройки tc."
        tc qdisc del dev "$iface" root 2>/dev/null
    fi
    press_enter
}

# Включить честную очередь (fair queuing) без жёсткого лимита
speed_fairqueue() {
    clear
    draw_header "Честное распределение канала"
    ensure_tc || { err "Не удалось установить tc."; press_enter; return; }

    local iface; iface="$(detect_iface)"
    if [[ -z "$iface" ]]; then
        err "Не удалось определить сетевой интерфейс."
        press_enter; return
    fi
    echo -e "  Интерфейс: ${CYAN}${iface}${NC}"
    echo
    echo "  Режим fq_codel равномерно делит канал между активными"
    echo "  соединениями: один пользователь не сможет занять всю полосу."
    echo "  Жёсткого потолка скорости при этом НЕ ставится."
    echo
    read -rp "  Включить честную очередь? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { warn "Отменено."; press_enter; return; }

    step "Применение"
    tc qdisc del dev "$iface" root 2>/dev/null
    if tc qdisc add dev "$iface" root fq_codel; then
        echo "LIMIT_MBIT=none" >  "$TC_STATE"
        echo "IFACE=${iface}"  >> "$TC_STATE"
        echo "FAIRQUEUE=on"    >> "$TC_STATE"
        echo
        ok "Честная очередь (fq_codel) включена на ${iface}."
    else
        err "Не удалось применить настройки tc."
    fi
    press_enter
}

# Сбросить все ограничения скорости
speed_reset() {
    clear
    draw_header "Сброс ограничений скорости"
    local iface; iface="$(detect_iface)"
    if [[ -z "$iface" ]]; then
        err "Не удалось определить сетевой интерфейс."
        press_enter; return
    fi
    step "Сброс"
    if tc qdisc del dev "$iface" root 2>/dev/null; then
        ok "Все ограничения tc на ${iface} сняты."
    else
        msg "Активных ограничений не было."
    fi
    rm -f "$TC_STATE"
    echo
    warn "Настройки tc не сохраняются после перезагрузки сервера."
    msg "После ребута при необходимости задайте лимит заново."
    press_enter
}

# Подменю управления скоростью
speed_menu() {
    while true; do
        clear
        local iface; iface="$(detect_iface)"
        local cur="без ограничений"
        if [[ -f "$TC_STATE" ]]; then
            . "$TC_STATE" 2>/dev/null
            if [[ "$LIMIT_MBIT" == "none" ]]; then
                cur="${GREEN}честная очередь${NC}"
            elif [[ -n "$LIMIT_MBIT" ]]; then
                cur="${GREEN}лимит ${LIMIT_MBIT} Мбит/с${NC}"
            fi
        fi

        echo -e "${BOLD}${MAGENTA}"
        echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║                                              ║"
        echo "  ║         УПРАВЛЕНИЕ СКОРОСТЬЮ СЕРВЕРА         ║"
        echo "  ║                                              ║"
        echo "  ╚══════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "   Интерфейс:        ${CYAN}${iface:-не определён}${NC}"
        echo -e "   Текущий режим:    ${cur}"
        echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
        echo
        echo -e "   ${BOLD}${GREEN}1${NC})  Установить общий лимит скорости"
        echo -e "   ${BOLD}${GREEN}2${NC})  Включить честное распределение канала"
        echo -e "   ${BOLD}${GREEN}3${NC})  Показать текущие настройки"
        echo -e "   ${BOLD}${YELLOW}4${NC})  Сбросить все ограничения"
        echo -e "   ${BOLD}${RED}0${NC})  Назад в главное меню"
        echo
        echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
        read -rp "   Выберите пункт: " sc
        case "$sc" in
            1) speed_limit     ;;
            2) speed_fairqueue ;;
            3) speed_show      ;;
            4) speed_reset     ;;
            0) return          ;;
            *) warn "Неверный пункт."; sleep 1 ;;
        esac
    done
}

# ─── Меню ────────────────────────────────────────────────────────────
show_menu() {
    clear
    local state
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnanode$'; then
        state="${GREEN}● работает${NC}"
    elif [[ -f "$COMPOSE_FILE" ]]; then
        state="${YELLOW}● остановлена${NC}"
    else
        state="${RED}● не установлена${NC}"
    fi

    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║                                              ║"
    echo "  ║          REMNAWAVE NODE  ·  МЕНЕДЖЕР         ║"
    echo "  ║                                              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "   Состояние ноды:  ${state}"
    echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
    echo
    echo -e "   ${BOLD}${GREEN}1${NC})  Установить / переустановить ноду"
    echo -e "   ${BOLD}${GREEN}2${NC})  Обновить ноду"
    echo -e "   ${BOLD}${GREEN}3${NC})  Статус ноды"
    echo -e "   ${BOLD}${GREEN}4${NC})  Логи ноды"
    echo -e "   ${BOLD}${GREEN}5${NC})  Перезапустить ноду"
    echo -e "   ${BOLD}${GREEN}6${NC})  Остановить ноду"
    echo -e "   ${BOLD}${GREEN}7${NC})  Запустить ноду"
    echo -e "   ${BOLD}${MAGENTA}8${NC})  Управление скоростью сервера"
    echo -e "   ${BOLD}${YELLOW}9${NC})  Удалить ноду"
    echo -e "   ${BOLD}${YELLOW}10${NC}) Удалить этот скрипт"
    echo -e "   ${BOLD}${RED}0${NC})  Выход"
    echo
    echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
}

# ─── Точка входа ─────────────────────────────────────────────────────
main() {
    require_root

    # При первом запуске, если нода ещё не установлена — сразу предлагаем установку
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        clear
        draw_header "Добро пожаловать!"
        echo "  Нода Remnawave на этом сервере ещё не установлена."
        echo
        read -rp "  Установить ноду сейчас? (Y/n): " first
        if [[ ! "$first" =~ ^[Nn]$ ]]; then
            install_node
        fi
    fi

    while true; do
        show_menu
        read -rp "   Выберите пункт: " choice
        case "$choice" in
            1)  install_node  ;;
            2)  update_node   ;;
            3)  status_node   ;;
            4)  logs_node     ;;
            5)  restart_node  ;;
            6)  stop_node     ;;
            7)  start_node    ;;
            8)  speed_menu    ;;
            9)  remove_node   ;;
            10) remove_script ;;
            0)  echo; ok "Выход."; echo; exit 0 ;;
            *)  warn "Неверный пункт."; sleep 1 ;;
        esac
    done
}

main
