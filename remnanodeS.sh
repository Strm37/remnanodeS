#!/usr/bin/env bash
#
# remnanodeS.sh — установка и управление нодой Remnawave
# Поддержка: Ubuntu 20.04+ / Debian 11+
# Репозиторий: https://github.com/Strm37/remnanodeS
#
# Использование:  sudo bash remnanodeS.sh
#

set -o pipefail

# ─── Гарантируем интерактивный ввод ──────────────────────────────────
# При запуске через  bash <(curl ...)  поток stdin занят телом скрипта,
# из-за чего read срабатывает вхолостую и меню печатается дважды.
# Переключаем ввод на реальный терминал.
if [[ ! -t 0 && -e /dev/tty ]]; then
    exec < /dev/tty
fi

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
    clear
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
    step "Классы трафика (class)"
    tc class show dev "$iface" 2>/dev/null || msg "Классы не заданы."
    echo
    if [[ -f "$TC_STATE" ]]; then
        step "Сохранённая конфигурация скрипта"
        sed 's/^/  /' "$TC_STATE"
    else
        msg "Ограничения скриптом не задавались."
    fi
    press_enter
}

# Спрашивает единицу измерения и возвращает множитель к Мбит
# Глобальная переменная SPEED_UNIT_NAME — для отображения
ask_unit() {
    echo "  В каких единицах задавать скорость?"
    echo -e "   ${BOLD}1${NC}) Мбит/с — как в тарифах провайдера"
    echo -e "   ${BOLD}2${NC}) Мбайт/с — как скорость скачивания файла"
    echo
    read -rp "  Единица [1/2, по умолчанию 1]: " u
    case "$u" in
        2) SPEED_MULT=8;  SPEED_UNIT_NAME="Мбайт/с" ;;   # 1 Мбайт = 8 Мбит
        *) SPEED_MULT=1;  SPEED_UNIT_NAME="Мбит/с"  ;;
    esac
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
    echo
    ask_unit
    echo
    read -rp "  Лимит скорости (${SPEED_UNIT_NAME}): " val

    if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -le 0 ]]; then
        err "Нужно положительное число."
        press_enter; return
    fi

    local mbit=$(( val * SPEED_MULT ))   # переводим в мегабиты для tc

    step "Применение лимита"
    tc qdisc del dev "$iface" root 2>/dev/null
    # HTB-шейпер с общим потолком + fq_codel внутри для честной очереди
    if tc qdisc add dev "$iface" root handle 1: htb default 10 \
        && tc class add dev "$iface" parent 1: classid 1:10 htb \
             rate "${mbit}mbit" ceil "${mbit}mbit" \
        && tc qdisc add dev "$iface" parent 1:10 handle 10: fq_codel; then
        {
            echo "MODE=limit"
            echo "IFACE=${iface}"
            echo "LIMIT_MBIT=${mbit}"
            echo "SHOW=общий лимит ${val} ${SPEED_UNIT_NAME}"
        } > "$TC_STATE"
        echo
        ok "Установлен лимит ${val} ${SPEED_UNIT_NAME} на интерфейс ${iface}."
        msg "Внутри лимита включена честная очередь (fq_codel)."
    else
        err "Не удалось применить настройки tc."
        tc qdisc del dev "$iface" root 2>/dev/null
    fi
    press_enter
}

# Динамическое распределение: коридор скорости «от и до» на поток.
# Когда канал свободен — потоки идут по максимуму, когда забит —
# HTB автоматически ужимает каждый поток к минимуму.
speed_dynamic() {
    clear
    draw_header "Динамическое распределение скорости"
    ensure_tc || { err "Не удалось установить tc."; press_enter; return; }

    local iface; iface="$(detect_iface)"
    if [[ -z "$iface" ]]; then
        err "Не удалось определить сетевой интерфейс."
        press_enter; return
    fi
    echo -e "  Интерфейс: ${CYAN}${iface}${NC}"
    echo
    echo "  Задаётся КОРИДОР скорости на каждый поток трафика:"
    echo "   • минимум — гарантированная скорость, ниже не опустится;"
    echo "   • максимум — потолок, когда канал свободен."
    echo
    echo "  Когда подключений мало — потоки разгоняются до максимума."
    echo "  Когда подключений много и канал забит — ядро автоматически"
    echo "  ужимает каждый поток вниз, к минимуму, чтобы хватило всем."
    echo
    ask_unit
    echo
    read -rp "  Минимум на поток (${SPEED_UNIT_NAME}): " vmin
    read -rp "  Максимум на поток (${SPEED_UNIT_NAME}): " vmax

    if ! [[ "$vmin" =~ ^[0-9]+$ ]] || ! [[ "$vmax" =~ ^[0-9]+$ ]] \
       || [[ "$vmin" -le 0 ]] || [[ "$vmax" -le 0 ]]; then
        err "Минимум и максимум должны быть положительными числами."
        press_enter; return
    fi
    if [[ "$vmin" -gt "$vmax" ]]; then
        err "Минимум не может быть больше максимума."
        press_enter; return
    fi

    echo
    echo "  Общий потолок сервера (необязательно) — суммарный максимум"
    echo "  для всего трафика. Оставьте пустым, если ограничивать не нужно."
    read -rp "  Общий потолок (${SPEED_UNIT_NAME}, Enter — пропустить): " vtotal

    local min_mbit=$(( vmin * SPEED_MULT ))
    local max_mbit=$(( vmax * SPEED_MULT ))
    local total_mbit
    if [[ -n "$vtotal" ]]; then
        if ! [[ "$vtotal" =~ ^[0-9]+$ ]] || [[ "$vtotal" -le 0 ]]; then
            err "Общий потолок должен быть положительным числом."
            press_enter; return
        fi
        total_mbit=$(( vtotal * SPEED_MULT ))
    else
        # Без явного потолка берём с большим запасом — 10 Гбит
        total_mbit=10000
    fi

    step "Применение динамического распределения"
    tc qdisc del dev "$iface" root 2>/dev/null

    # Корневой класс — общий потолок сервера.
    # Дочерний класс: rate = минимум на поток (гарантия),
    #                 ceil = максимум на поток (когда свободно).
    # fq_codel поверх — честно делит полосу между потоками,
    # за счёт чего при росте числа потоков каждый ужимается к минимуму.
    if tc qdisc add dev "$iface" root handle 1: htb default 10 \
        && tc class add dev "$iface" parent 1:  classid 1:1  htb \
             rate "${total_mbit}mbit" ceil "${total_mbit}mbit" \
        && tc class add dev "$iface" parent 1:1 classid 1:10 htb \
             rate "${min_mbit}mbit" ceil "${max_mbit}mbit" \
        && tc qdisc add dev "$iface" parent 1:10 handle 10: fq_codel; then
        {
            echo "MODE=dynamic"
            echo "IFACE=${iface}"
            echo "MIN_MBIT=${min_mbit}"
            echo "MAX_MBIT=${max_mbit}"
            echo "TOTAL_MBIT=${total_mbit}"
            echo "SHOW=коридор ${vmin}-${vmax} ${SPEED_UNIT_NAME} на поток"
        } > "$TC_STATE"
        echo
        ok "Динамическое распределение включено."
        msg "Коридор на поток: ${vmin}-${vmax} ${SPEED_UNIT_NAME}."
        [[ -n "$vtotal" ]] && msg "Общий потолок сервера: ${vtotal} ${SPEED_UNIT_NAME}."
        echo
        msg "При нехватке канала скорость на поток ужимается автоматически."
    else
        err "Не удалось применить настройки tc."
        tc qdisc del dev "$iface" root 2>/dev/null
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
    msg "После ребута при необходимости задайте их заново."
    press_enter
}

# Подменю управления скоростью
speed_menu() {
    while true; do
        clear
        local iface; iface="$(detect_iface)"
        local cur="без ограничений"
        if [[ -f "$TC_STATE" ]]; then
            ( . "$TC_STATE" 2>/dev/null )
            local show_line
            show_line="$(grep '^SHOW=' "$TC_STATE" 2>/dev/null | cut -d= -f2-)"
            [[ -n "$show_line" ]] && cur="${GREEN}${show_line}${NC}"
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
        echo -e "   ${BOLD}${GREEN}1${NC})  Динамическое распределение (коридор от-до)"
        echo -e "   ${BOLD}${GREEN}2${NC})  Установить общий лимит скорости"
        echo -e "   ${BOLD}${GREEN}3${NC})  Показать текущие настройки"
        echo -e "   ${BOLD}${YELLOW}4${NC})  Сбросить все ограничения"
        echo -e "   ${BOLD}${RED}0${NC})  Назад в главное меню"
        echo
        echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
        read -rp "   Выберите пункт: " sc
        case "$sc" in
            1) speed_dynamic ;;
            2) speed_limit   ;;
            3) speed_show    ;;
            4) speed_reset   ;;
            0) clear; return ;;
            *) warn "Неверный пункт."; sleep 1 ;;
        esac
    done
}

# ─── Подменю: установка и управление нодой ───────────────────────────
node_menu() {
    while true; do
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
        echo -e "   ${BOLD}${YELLOW}8${NC})  Удалить ноду"
        echo -e "   ${BOLD}${YELLOW}9${NC})  Удалить этот скрипт"
        echo -e "   ${BOLD}${RED}0${NC})  Назад в главное меню"
        echo
        echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
        read -rp "   Выберите пункт: " choice
        case "$choice" in
            1) install_node  ;;
            2) update_node   ;;
            3) status_node   ;;
            4) logs_node     ;;
            5) restart_node  ;;
            6) stop_node     ;;
            7) start_node    ;;
            8) remove_node   ;;
            9) remove_script ;;
            0) clear; return ;;
            *) warn "Неверный пункт."; sleep 1 ;;
        esac
    done
}

# ─── Стартовое меню (выбор раздела) ──────────────────────────────────
start_menu() {
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
    echo "  ║         REMNAWAVE NODE  ·  ГЛАВНОЕ МЕНЮ      ║"
    echo "  ║                                              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "   Состояние ноды:  ${state}"
    echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
    echo
    echo -e "   ${BOLD}${GREEN}1${NC})  Установка и управление нодой"
    echo -e "   ${BOLD}${MAGENTA}2${NC})  Настройки сети (скорость)"
    echo -e "   ${BOLD}${RED}0${NC})  Выход"
    echo
    echo -e "   ${GRAY}──────────────────────────────────────────────${NC}"
}

# ─── Точка входа ─────────────────────────────────────────────────────
main() {
    require_root
    clear
    while true; do
        start_menu
        if ! read -rp "   Выберите раздел: " section; then
            echo; err "Нет доступа к терминалу для ввода."
            err "Запустите скрипт так:  sudo bash remnanodeS.sh"
            exit 1
        fi
        case "$section" in
            1) node_menu  ;;
            2) speed_menu ;;
            0) clear; ok "Выход."; echo; exit 0 ;;
            *) warn "Неверный пункт."; sleep 1; clear ;;
        esac
    done
}

main
