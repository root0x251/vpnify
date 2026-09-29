#!/usr/bin/env bash
# =============================================================================
#  VPS SETUP SCRIPT
#  Ubuntu 24.04 LTS · Docker · NPM · 3x-ui · Hysteria2 · Telemt
# =============================================================================

set -euo pipefail

# ─ Цвета ─
RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''

# ─ Пути 
STATE_FILE="/root/.vps-setup-state"
VARS_FILE="/root/.vps-setup-vars"
LOG_FILE="/var/log/vps-setup.log"
SUMMARY_FILE="/root/vps-setup-summary.txt"

# ─ Режим установки ─
INSTALL_MODE="full"           # full | selective
declare -a STAGES_TO_RUN=()
CURRENT_STAGE=-1              # используется error_handler'ом

# ─ Переменные конфигурации ─
NEW_USER="" USER_PASS="" LE_EMAIL="" ROOT_DOMAIN=""
NPM_DOMAIN="" XUI_DOMAIN="" H2_DOMAIN=""
SERVER_IP="" SSH_PORT="3270" XUI_PORT="2053"
H2_PASS="" TELEMT_SECRET="" TLS_DOMAIN="www.apple.com"
P_VLESS_REALITY="8443" P_VLESS_XHTTP="8448"
P_TROJAN="8449" P_SS="8445" P_H2="8444" P_TELEMT="8446"

# =============================================================================
#  ЛОГИРОВАНИЕ — весь вывод дублируется в LOG_FILE
# =============================================================================
mkdir -p "$(dirname "$LOG_FILE")"
# tee дублирует stdout в лог; stderr туда же
exec > >(tee -a "$LOG_FILE") 2>&1
echo "" >> "$LOG_FILE"
echo "=== VPS Setup v3.0 started: $(date) ===" >> "$LOG_FILE"

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    {
  echo -e "\n${BOLD}${BLUE}*** $* ***${NC}"
}
log_section() { echo -e "\n${BOLD}${CYAN}*** $* ***${NC}\n"; }

die() {
  log_error "$*"
  echo "$(date): FATAL: $*" >> "$LOG_FILE"
  exit 1
}

# =============================================================================
#  ПЕРЕМЕННЫЕ
# =============================================================================
save_state() { echo "$1" > "$STATE_FILE"; }
get_state()  { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "-1"; }

# Сохраняем все за исключением USER_PASS
save_vars() {
  {
    printf 'NEW_USER=%q\n'         "${NEW_USER}"
    printf 'LE_EMAIL=%q\n'         "${LE_EMAIL}"
    printf 'ROOT_DOMAIN=%q\n'      "${ROOT_DOMAIN}"
    printf 'NPM_DOMAIN=%q\n'       "${NPM_DOMAIN}"
    printf 'XUI_DOMAIN=%q\n'       "${XUI_DOMAIN}"
    printf 'H2_DOMAIN=%q\n'        "${H2_DOMAIN}"
    printf 'SERVER_IP=%q\n'        "${SERVER_IP}"
    printf 'H2_PASS=%q\n'          "${H2_PASS}"
    printf 'TELEMT_SECRET=%q\n'    "${TELEMT_SECRET}"
    printf 'TLS_DOMAIN=%q\n'       "${TLS_DOMAIN}"
    printf 'SSH_PORT=%q\n'         "${SSH_PORT}"
    printf 'XUI_PORT=%q\n'         "${XUI_PORT}"
    printf 'P_VLESS_REALITY=%q\n'  "${P_VLESS_REALITY}"
    printf 'P_VLESS_XHTTP=%q\n'    "${P_VLESS_XHTTP}"
    printf 'P_TROJAN=%q\n'         "${P_TROJAN}"
    printf 'P_SS=%q\n'             "${P_SS}"
    printf 'P_H2=%q\n'             "${P_H2}"
    printf 'P_TELEMT=%q\n'         "${P_TELEMT}"
  } > "$VARS_FILE"
  chmod 600 "$VARS_FILE"
}

load_vars() {
  [[ -f "$VARS_FILE" ]] && source "$VARS_FILE" || true
}

ensure_docker_network() {
  local net_name="${1:-proxy-net}"
  local subnet="${2:-172.18.0.0/16}"

  if docker network inspect "$net_name" >/dev/null 2>&1; then
    local current_subnet
    current_subnet=$(docker network inspect "$net_name" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
    if [[ -n "$current_subnet" && "$current_subnet" != "$subnet" ]]; then
      log_error "Сеть ${net_name} уже существует с subnet ${current_subnet}, но требуется ${subnet}"
      log_error "Сначала исправь сеть вручную или удалите ее: docker network rm ${net_name}"
      die "Несовместимая docker-сеть ${net_name}"
    fi
    log_ok "Сеть ${net_name} уже готова (${current_subnet:-${subnet}})"
  else
    docker network create --driver bridge --subnet="$subnet" "$net_name" >/dev/null
    log_ok "Создана сеть ${net_name} (${subnet})"
  fi
}

require_container_running() {
  local container_name="$1"
  local compose_dir="$2"

  if ! docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
    log_error "Контейнер ${container_name} не запустился из ${compose_dir}"
    docker logs "$container_name" 2>&1 || true
    die "Контейнер ${container_name} не запустился"
  fi

  log_ok "Контейнер ${container_name} запущен"
}

wait_for_container_ready() {
  local container_name="$1"
  local timeout_seconds="${2:-30}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  log_error "Контейнер ${container_name} не доступен за ${timeout_seconds}s"
  docker logs "$container_name" 2>&1 || true
  return 1
}

# Информация по паролю пользователя
ask_user_password() {
  local user="${1:-${NEW_USER:-user}}"
  echo -e "${YELLOW}Запомни или запиши пароль!!${NC}"
  while true; do
    read -rsp "$(echo -e "${BOLD}Пароль для ${user}:${NC} ")" USER_PASS; echo
    [[ -z "$USER_PASS" ]] && { log_warn "Пароль не может быть пустым"; continue; }
    read -rsp "$(echo -e "${BOLD}Повтори пароль:${NC} ")" _pass2; echo
    [[ "$USER_PASS" == "$_pass2" ]] && break
    log_warn "Пароли не совпадают"
  done
}

# Валидация переменных при возобновлении с произвольного этапа
validate_vars() {
  local missing=()
  [[ -z "${NEW_USER:-}"    ]] && missing+=("NEW_USER")
  [[ -z "${SERVER_IP:-}"   ]] && missing+=("SERVER_IP")
  [[ -z "${ROOT_DOMAIN:-}" ]] && missing+=("ROOT_DOMAIN")
  [[ -z "${NPM_DOMAIN:-}"  ]] && missing+=("NPM_DOMAIN")
  [[ -z "${XUI_DOMAIN:-}"  ]] && missing+=("XUI_DOMAIN")
  [[ -z "${H2_DOMAIN:-}"   ]] && missing+=("H2_DOMAIN")
  [[ -z "${SSH_PORT:-}"    ]] && missing+=("SSH_PORT")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Отсутствуют переменные: ${missing[*]}"
    log_error "Варианты:"
    log_error "  1) Запусти скрипт заново и выбери 'Начать сначала'"
    log_error "  2) Запусти этап 0 отдельно (он собирает все данные)"
    die "Переменные не инициализированы"
  fi
}

# =============================================================================
#  DNS
# =============================================================================
check_dns() {
  local domain="$1" expected_ip="$2"
  local resolved
  resolved=$(dig +short "$domain" 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  if [[ "$resolved" == "$expected_ip" ]]; then
    log_ok "DNS: ${domain} → ${resolved}"; return 0
  elif [[ -z "$resolved" ]]; then
    log_warn "DNS: ${domain} → не резолвится (нет записи или не распространился)"; return 1
  else
    log_warn "DNS: ${domain} → ${resolved} (ожидаем ${expected_ip})"; return 1
  fi
}

wait_dns() {
  local domain="$1" expected_ip="$2"
  log_info "Проверяем DNS для ${domain}..."

  while true; do
    check_dns "$domain" "$expected_ip" && return 0

    echo ""
    echo -e "${YELLOW}DNS еще не распространился. Варианты:${NC}"
    echo "  1) Подождать 30 сек и проверить снова"
    echo "  2) Продолжить без проверки (Let's Encrypt может и упадет из-за отсутствия DNS!!!)"
    echo "  3) Выйти (настрой DNS\подожди резолв и перезапусти скрипт)"
    read -rp "Выбор [1/2/3]: " dns_choice || dns_choice="3"

    case "$dns_choice" in
      1) log_info "Ждем 30 секунд..."; sleep 30 ;;
      2) log_warn "Продолжаем без подтверждения DNS"; return 0 ;;
      *) die "Выйди, настрой DNS и перезапусти скрипт" ;;
    esac
  done
}

check_tls_domain() {
  local domain="${1:-${TLS_DOMAIN:-www.apple.com}}"
  if curl -fsS --connect-timeout 5 --max-time 10 "https://${domain}" >/dev/null 2>&1; then
    log_ok "TLS domain доступен: https://${domain}"
    return 0
  fi
  log_warn "TLS domain не отвечает: https://${domain} (это не блокирует установку, но проверь DNS/сайт)"
  return 1
}

show_port_checks() {
  log_info "Проверка пробросов портов в UFW и Docker"
  ufw status numbered 2>/dev/null || true
  echo "*** Docker port mappings ***"
  docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null || true
  echo "*** TCP/UDP listeners ***"
  ss -tulpn 2>/dev/null | grep -E ':(22|80|81|443|8443|8444|8445|8446|8448|8449|2053|3270)\b' || true
}

# =============================================================================
#  СПИСОК ЭТАПОВ
# =============================================================================
declare -A STAGE_NAMES=(
  [0]="Сбор данных + обновление системы"
  [1]="Пользователь, SSH, Swap, UFW, Fail2Ban"
  [2]="Docker, папки, сеть proxy-net"
  [3]="Nginx Proxy Manager"
  [4]="Nginx сайт-заглушка"
  [5]="3x-ui (VPN панель)"
  [6]="Hysteria 2"
  [7]="Telemt MTProxy"
)

print_stage_list() {
  echo ""
  for i in 0 1 2 3 4 5; do
    echo "  $i — ${STAGE_NAMES[$i]} [обязательно]"
  done
  for i in 6 7; do
    echo "  $i — ${STAGE_NAMES[$i]} [опционально]"
  done
  echo ""
}

ensure_required_stages() {
  local required=(0 1 2 3 4 5)
  local optional=()
  local stage
  local final=()

  for stage in "${STAGES_TO_RUN[@]}"; do
    if [[ "$stage" =~ ^[6-7]$ ]]; then
      optional+=("$stage")
    fi
  done

  for stage in "${required[@]}"; do
    final+=("$stage")
  done

  for stage in "${optional[@]}"; do
    if ! printf '%s\n' "${final[@]}" | grep -qx "$stage"; then
      final+=("$stage")
    fi
  done

  STAGES_TO_RUN=("${final[@]}")
}

# =============================================================================
#  ОТКАТ
# =============================================================================
rollback_stage() {
  local stage="$1"
  log_warn "Откат этапа ${stage}: ${STAGE_NAMES[$stage]:-?}..."
  case "$stage" in
    0) _rollback_0 ;;
    1) _rollback_1 ;;
    2) _rollback_2 ;;
    3) _rollback_3 ;;
    4) _rollback_4 ;;
    5) _rollback_5 ;;
    6) _rollback_6 ;;
    7) _rollback_7 ;;
    *) log_warn "Откат для этапа ${stage} не определен" ;;
  esac
}

_rollback_0() {
  log_info "Откат 0: удаляем файлы состояния"
  rm -f "$STATE_FILE" "$VARS_FILE"
  log_warn "Обновление пакетов откатить нельзя — это нормально"
  log_ok "Файлы состояния удалены"
}

_rollback_1() {
  log_info "Откат 1: пользователь / SSH / swap / UFW / Fail2Ban"

  if [[ -f /etc/ssh/sshd_config.bak ]]; then
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || true
    log_ok "SSH конфиг восстановлен из backup"
  fi

  if [[ -n "${NEW_USER:-}" ]] && id "$NEW_USER" &>/dev/null 2>&1; then
    userdel -r "$NEW_USER" 2>/dev/null || true
    rm -f "/etc/sudoers.d/${NEW_USER}"
    log_ok "Пользователь ${NEW_USER} удален"
  fi

  # ICMP
  sed -i '/icmp_echo_ignore_all/d' /etc/sysctl.conf 2>/dev/null || true
  sysctl -p > /dev/null 2>&1 || true

  # Swap
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
  sed -i '/vm.swappiness/d' /etc/sysctl.conf 2>/dev/null || true

  # UFW
  ufw --force reset > /dev/null 2>&1 || true
  ufw disable 2>/dev/null || true

  # Fail2Ban
  systemctl stop fail2ban 2>/dev/null || true
  rm -f /etc/fail2ban/jail.local

  log_ok "Этап 1 откатан"
}

_rollback_2() {
  log_info "Откат 2: Docker-контейнеры / сеть / папки"

  for svc in nginx-proxy-manager nginx-site 3x-ui hysteria2 telemt; do
    [[ -d "/opt/docker/$svc" ]] && \
      (cd "/opt/docker/$svc" && docker compose down 2>/dev/null || true)
  done

  docker network rm proxy-net 2>/dev/null || true

  log_warn "Docker-движок не удаляется автоматически (безопасно)."
  log_warn "Для полного удаления:"
  log_warn "  apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  log_warn "  rm -rf /opt/docker"
  log_ok "Контейнеры и сеть proxy-net удалены"
}

_rollback_3() {
  [[ -d /opt/docker/nginx-proxy-manager ]] && \
    (cd /opt/docker/nginx-proxy-manager && docker compose down 2>/dev/null || true)
  log_ok "NPM остановлен"
}

_rollback_4() {
  [[ -d /opt/docker/nginx-site ]] && \
    (cd /opt/docker/nginx-site && docker compose down 2>/dev/null || true)
  log_ok "nginx-site остановлен"
}

_rollback_5() {
  [[ -d /opt/docker/3x-ui ]] && \
    (cd /opt/docker/3x-ui && docker compose down 2>/dev/null || true)
  log_ok "3x-ui остановлен (данные в /opt/docker/3x-ui/db/ сохранены)"
}

_rollback_6() {
  [[ -d /opt/docker/hysteria2 ]] && \
    (cd /opt/docker/hysteria2 && docker compose down 2>/dev/null || true)
  log_ok "Hysteria2 остановлен"
}

_rollback_7() {
  [[ -d /opt/docker/telemt ]] && \
    (cd /opt/docker/telemt && docker compose down 2>/dev/null || true)
  log_ok "Telemt остановлен"
}

rollback_all() {
  echo ""
  echo -e "${RED}${BOLD}*** ПОЛНЫЙ ОТКАТ ВСЕХ ЭТАПОВ ***${NC}"
  echo -e "${RED}${BOLD}Будет удалено:${NC}"
  echo -e "${RED}${BOLD}  • Все Docker-контейнеры и данные${NC}"
  echo -e "${RED}${BOLD}  • /opt/docker (ВСЕ данные контейнеров!)${NC}"
  echo -e "${RED}${BOLD}  • Пользователь ${NEW_USER:-<user>}${NC}"
  echo -e "${RED}${BOLD}  • SSH-конфиг (восстановится из backup)${NC}"
  echo -e "${RED}${BOLD}  • Swap-файл, правила UFW${NC}"
  echo ""
  read -rp "$(echo -e "${RED}${BOLD}Продолжить? Введи 'yes' для подтверждения:${NC} ")" confirm || confirm=""
  if [[ "$confirm" != "yes" ]]; then
    log_info "Полный откат отменен"
    return 0
  fi

  for stage in 7 6 5 4 3 2 1 0; do
    rollback_stage "$stage"
  done

  rm -rf /opt/docker
  rm -f "$STATE_FILE" "$VARS_FILE" "$SUMMARY_FILE"
  log_ok "Полный откат завершен. Система почти в исходном состоянии."
  log_warn "Установленные пакеты (curl, docker и др.) нужно удалить вручную при необходимости."
  exit 0
}

# =============================================================================
#  ERROR TRAP — автооткат при неожиданной ошибке
# =============================================================================
_ERROR_IN_PROGRESS=0

error_handler() {
  # Защита от рекурсивного вызова
  [[ "$_ERROR_IN_PROGRESS" -eq 1 ]] && exit 1
  _ERROR_IN_PROGRESS=1
  trap - ERR  # отключаем trap на время обработки

  local line="${1:-?}" cmd="${BASH_COMMAND:-unknown}"
  echo ""
  log_error "Непредвиденная ошибка на строке ${line}"
  log_error "Команда: ${cmd}"
  echo "$(date): ERROR at line $line (stage $CURRENT_STAGE): $cmd" >> "$LOG_FILE"

  if [[ "$CURRENT_STAGE" -ge 0 ]]; then
    log_warn "Автооткат этапа ${CURRENT_STAGE}..."
    rollback_stage "$CURRENT_STAGE" || true

    if [[ "$CURRENT_STAGE" -gt 0 ]]; then
      save_state "$((CURRENT_STAGE - 1))"
      log_info "Состояние откатано до этапа $((CURRENT_STAGE - 1))"
    else
      rm -f "$STATE_FILE"
    fi

    echo ""
    log_info "Откат выполнен. Перезапусти скрипт:"
    log_info "  → выбери 'Продолжить с этапа ${CURRENT_STAGE}'"
    log_info "Полный лог: ${LOG_FILE}"
  fi
  exit 1
}

trap 'error_handler $LINENO' ERR

# =============================================================================
#  ПРОВЕРКА ROOT
# =============================================================================
[[ $EUID -eq 0 ]] || die "Запусти скрипт от root: sudo bash setup.sh"

# =============================================================================
#  СТАРТОВОЕ МЕНЮ
# =============================================================================
CURRENT_STATE=$(get_state)

echo -e "\n${BOLD}${BLUE}*** VPS SETUP SCRIPT v3.0 ***${NC}\n"

#  Вспомогательная функция: парсим строку "0,1,3,5" в массив STAGES_TO_RUN
parse_stage_input() {
  local input="$1"
  local valid=()
  IFS=',' read -ra _parts <<< "$input"
  for s in "${_parts[@]}"; do
    s="${s// /}"  # убираем пробелы
    if [[ "$s" =~ ^[0-7]$ ]]; then
      valid+=("$s")
    else
      log_warn "Неверный номер этапа: '${s}' (допустимы 0-7)"
    fi
  done
  STAGES_TO_RUN=("${valid[@]}")
  [[ ${#STAGES_TO_RUN[@]} -eq 0 ]] && die "Не выбрано ни одного корректного этапа"
  ensure_required_stages
  log_info "Будут выполнены этапы: ${STAGES_TO_RUN[*]}"
}

#  Проверяем наличие сохраненного состояния
if [[ "$CURRENT_STATE" != "-1" && -n "$CURRENT_STATE" ]]; then

  if [[ "$CURRENT_STATE" == "done" ]]; then
    # Установка уже была завершена ранее
    echo -e "${GREEN}Установка была успешно завершена ранее.${NC}"
    echo ""
    echo "Что делаем?"
    echo "  1) Перезапустить отдельные этапы"
    echo "  2) Показать сводку (если файл еще существует)"
    echo "  3) Выйти"
    read -rp "Выбор [1/2/3]: " _c || _c="3"
    case "$_c" in
      1)
        load_vars
        validate_vars
        echo ""
        echo "Выбери этапы через запятую (например: 3,5,7):"
        print_stage_list
        read -rp "Этапы: " _si
        INSTALL_MODE="selective"
        parse_stage_input "$_si"
        if printf '%s\n' "${STAGES_TO_RUN[@]}" | grep -q "^1$"; then
          ask_user_password "${NEW_USER}"
        fi
        ;;
      2)
        [[ -f "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" || log_warn "Файл сводки не найден"
        exit 0
        ;;
      *) exit 0 ;;
    esac

  else
    # Незавершенная установка
    _stage_name="${STAGE_NAMES[$CURRENT_STATE]:-?}"
    echo -e "${YELLOW}Найдено незавершенное состояние: этап ${CURRENT_STATE} (${_stage_name})${NC}"
    echo ""
    echo "Что делаем?"
    echo "  1) Продолжить с этапа $((CURRENT_STATE + 1))"
    echo "  2) Запустить конкретные этапы"
    echo "  3) Начать заново (полный откат установленного)"
    echo "  4) Показать список этапов и выйти"
    read -rp "Выбор [1/2/3/4]: " _c || _c="4"

    case "$_c" in
      1)
        load_vars
        validate_vars
        INSTALL_MODE="full"
        for _i in $(seq $((CURRENT_STATE + 1)) 7); do
          STAGES_TO_RUN+=("$_i")
        done
        [[ ${#STAGES_TO_RUN[@]} -eq 0 ]] && { log_ok "Все этапы уже выполнены"; exit 0; }
        
        if printf '%s\n' "${STAGES_TO_RUN[@]}" | grep -q "^1$"; then
          ask_user_password "${NEW_USER}"
        fi
        ;;
      2)
        load_vars
        validate_vars
        echo ""
        print_stage_list
        read -rp "Этапы через запятую: " _si
        INSTALL_MODE="selective"
        parse_stage_input "$_si"
        if printf '%s\n' "${STAGES_TO_RUN[@]}" | grep -q "^1$"; then
          ask_user_password "${NEW_USER}"
        fi
        ;;
      3)
        load_vars
        rollback_all  # внутри спросит подтверждение
        exit 0
        ;;
      4|*)
        print_stage_list
        log_info "Перезапусти скрипт и выбери нужный вариант"
        exit 0
        ;;
    esac
  fi

else
  #  Свежий запуск 
  echo "Выбери режим установки:"
  echo "  1) Полная установка с подтверждением каждого этапа"
  echo "  2) Выборочная установка (укажи нужные этапы, 0-5 обязательны, 6,7 опционально)"
  echo "  3) Показать список этапов и выйти"
  echo ""
  read -rp "Выбор [1/2/3]: " _mode || _mode="3"

  case "$_mode" in
    1)
      INSTALL_MODE="full"
      STAGES_TO_RUN=(0 1 2 3 4 5)
      echo ""
      read -rp "Запустить опциональные этапы 6 и 7? (y/N): " _opt || _opt="n"
      if [[ "$_opt" =~ ^[Yy]$ ]]; then
        STAGES_TO_RUN+=(6 7)
      fi
      ensure_required_stages
      log_info "Полный обязательный набор: ${STAGES_TO_RUN[*]}"
      ;;
    2)
      INSTALL_MODE="selective"
      echo ""
      print_stage_list
      echo "Этапы 0-5 обязательны; 6 и 7 опциональны."
      read -rp "Этапы через запятую: " _si
      parse_stage_input "$_si"
      ;;
    3|*)
      print_stage_list
      log_info "Перезапусти скрипт и выбери режим"
      exit 0
      ;;
  esac
fi

log_info "Режим: ${INSTALL_MODE} | Этапы: ${STAGES_TO_RUN[*]}"

# =============================================================================
#  HELPERS
# =============================================================================

# Проверяет — нужно ли запускать данный этап
should_run() {
  printf '%s\n' "${STAGES_TO_RUN[@]}" | grep -q "^${1}$"
}

# Подтверждение этапа (только в полном режиме)
confirm_stage() {
  local sn="$1"

  if [[ "$INSTALL_MODE" != "full" ]]; then
    save_state "$sn"
    log_ok "Этап ${sn} завершен"
    return 0
  fi

  echo ""
  echo -e "${BOLD}${GREEN}*** Этап ${sn}: ${STAGE_NAMES[$sn]} ***${NC}"
  echo ""
  read -rp "$(echo -e "${BOLD}Подтвердить и продолжить? (yes/no):${NC} ")" _ans || _ans="no"

  if [[ "$_ans" != "yes" ]]; then
    log_warn "Этап ${sn} не подтвержден пользователем"
    echo "$(date): Stage $sn NOT confirmed" >> "$LOG_FILE"
    log_info "Откатываем этап ${sn}..."
    rollback_stage "$sn" || true

    if [[ "$sn" -gt 0 ]]; then
      save_state "$((sn - 1))"
      log_info "Состояние: последний успешный этап = $((sn - 1))"
    else
      rm -f "$STATE_FILE"
    fi

    echo ""
    log_info "Скрипт остановлен. Перезапусти и выбери 'Продолжить с этапа ${sn}'"
    exit 1
  fi

  save_state "$sn"
  log_ok "Этап ${sn} подтвержден и сохранен"
}

# =============================================================================
#  ЭТАП 0 — СБОР ДАННЫХ + ОБНОВЛЕНИЕ СИСТЕМЫ
# =============================================================================
if should_run 0; then
CURRENT_STAGE=0
log_step "ЭТАП 0 — ${STAGE_NAMES[0]}"
echo -e "${YELLOW}Все данные вводятся сейчас. Пароль пользователя не сохраняется. ВНИМАТЕЛЬНО!${NC}\n"

#  Имя пользователя
while true; do
  read -rp "$(echo -e "${BOLD}Имя нового SSH-пользователя:${NC} ")" NEW_USER || die "Ввод отменен"
  [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{1,31}$ ]] && break
  log_warn "Только строчные буквы, цифры, _ и - (2-32 символа)"
done

#  Пароль (не сохраняется)
ask_user_password "$NEW_USER"

#  Email
while true; do
  read -rp "$(echo -e "${BOLD}Email для Let's Encrypt:${NC} ")" LE_EMAIL || die "Ввод отменен"
  [[ "$LE_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
  log_warn "Введи корректный email (example@domain.com)"
done

#  Основной домен
while true; do
  read -rp "$(echo -e "${BOLD}Основной домен (example.ru):${NC} ")" ROOT_DOMAIN || die "Ввод отменен"
  [[ "$ROOT_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
  log_warn "Введи домен без http:// и слешей"
done

#  Субдомены
echo ""
echo -e "${CYAN}Субдомены по умолчанию:${NC}"
echo -e "  npm.${ROOT_DOMAIN}   → NPM панель"
echo -e "  cdn.${ROOT_DOMAIN}   → 3x-ui панель"
echo -e "  hist.${ROOT_DOMAIN}  → Hysteria2"
echo ""
read -rp "$(echo -e "${BOLD}Использовать эти субдомены? (y/n):${NC} ")" _sc || _sc="n"
if [[ "$_sc" =~ ^[Yy]$ ]]; then
  NPM_DOMAIN="npm.${ROOT_DOMAIN}"
  XUI_DOMAIN="cdn.${ROOT_DOMAIN}"
  H2_DOMAIN="hist.${ROOT_DOMAIN}"
else
  read -rp "$(echo -e "${BOLD}Субдомен для NPM:${NC} ")"      NPM_DOMAIN || die "Ввод отменен"
  read -rp "$(echo -e "${BOLD}Субдомен для 3x-ui:${NC} ")"    XUI_DOMAIN || die "Ввод отменен"
  read -rp "$(echo -e "${BOLD}Субдомен для Hysteria2:${NC} ")" H2_DOMAIN  || die "Ввод отменен"
fi

#  IP сервера
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s --max-time 5 https://ifconfig.me  2>/dev/null || \
            hostname -I | awk '{print $1}')
log_info "Определен IP: ${GREEN}${SERVER_IP}${NC}"
read -rp "$(echo -e "${BOLD}Верно? Или введи IP вручную (Enter = ${SERVER_IP}):${NC} ")" _ip || _ip=""
[[ -n "$_ip" ]] && SERVER_IP="$_ip"

#  Порт SSH
read -rp "$(echo -e "${BOLD}Порт SSH (Enter = 3270):${NC} ")" SSH_PORT || SSH_PORT=""
SSH_PORT=${SSH_PORT:-3270}

#  Порт 3x-ui
read -rp "$(echo -e "${BOLD}Порт панели 3x-ui (Enter = 2053):${NC} ")" XUI_PORT || XUI_PORT=""
XUI_PORT=${XUI_PORT:-2053}

#  tls_domain для Telemt/FakeTLS и протоколов с советом выбора
read -rp "$(echo -e "${BOLD}tls_domain для Telemt/FakeTLS (Enter = www.apple.com):${NC} ")" _tls_input || _tls_input=""
TLS_DOMAIN="${_tls_input:-www.apple.com}"
check_tls_domain "$TLS_DOMAIN" || true

#  Автогенерация секретов
H2_PASS=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
TELEMT_SECRET=$(openssl rand -hex 16)
log_info "Пароль Hysteria2 и секрет Telemt сгенерированы автоматически"

#  Порты VPN
echo ""
log_section "Порты VPN (Enter = значение по умолчанию)"
read -rp "$(echo -e "${BOLD}VLESS-Reality  [8443]:${NC} ")" _p; P_VLESS_REALITY="${_p:-8443}"
read -rp "$(echo -e "${BOLD}VLESS-XHTTP    [8448]:${NC} ")" _p; P_VLESS_XHTTP="${_p:-8448}"
read -rp "$(echo -e "${BOLD}Trojan         [8449]:${NC} ")" _p; P_TROJAN="${_p:-8449}"
read -rp "$(echo -e "${BOLD}Shadowsocks    [8445]:${NC} ")" _p; P_SS="${_p:-8445}"
read -rp "$(echo -e "${BOLD}Hysteria2 UDP  [8444]:${NC} ")" _p; P_H2="${_p:-8444}"
read -rp "$(echo -e "${BOLD}Telemt MTProxy [8446]:${NC} ")" _p; P_TELEMT="${_p:-8446}"

#  Сводка
echo ""
echo -e "${BOLD}${BLUE}*** СВОДКА ВВЕДЕННЫХ ДАННЫХ ***${NC}"
echo -e "${BOLD}${BLUE}Пользователь : ${GREEN}${NEW_USER}${NC}"
echo -e "${BOLD}${BLUE}Email        : ${GREEN}${LE_EMAIL}${NC}"
echo -e "${BOLD}${BLUE}IP сервера   : ${GREEN}${SERVER_IP}${NC}"
echo -e "${BOLD}${BLUE}Корневой домен: ${GREEN}${ROOT_DOMAIN}${NC}"
echo -e "${BOLD}${BLUE}NPM панель   : ${GREEN}https://${NPM_DOMAIN}${NC}"
echo -e "${BOLD}${BLUE}3x-ui панель : ${GREEN}https://${XUI_DOMAIN}${NC}"
echo -e "${BOLD}${BLUE}Hysteria2    : ${GREEN}${H2_DOMAIN}${NC}"
echo -e "${BOLD}${BLUE}SSH порт     : ${GREEN}${SSH_PORT}/tcp${NC}"
echo -e "${BOLD}${BLUE}3x-ui порт   : ${GREEN}${XUI_PORT}/tcp (внутренний)${NC}"
echo -e "${BOLD}${BLUE}VLESS-Reality: ${GREEN}${P_VLESS_REALITY}/tcp${NC}"
echo -e "${BOLD}${BLUE}VLESS-XHTTP  : ${GREEN}${P_VLESS_XHTTP}/tcp${NC}"
echo -e "${BOLD}${BLUE}Trojan       : ${GREEN}${P_TROJAN}/tcp${NC}"
echo -e "${BOLD}${BLUE}Shadowsocks  : ${GREEN}${P_SS}/tcp+udp${NC}"
echo -e "${BOLD}${BLUE}Hysteria2     : ${GREEN}${P_H2}/udp${NC}"
echo -e "${BOLD}${BLUE}Telemt       : ${GREEN}${P_TELEMT}/tcp${NC}"
echo ""
read -rp "$(echo -e "${BOLD}${RED}Все верно? Продолжить? (yes/no):${NC} ")" _fc || _fc="no"
[[ "$_fc" == "yes" ]] || die "Установка отменена"

# Сохраняем все кроме пароля
save_vars

#  Обновление системы
log_section "Обновление и установка пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -o Dpkg::Options::="--force-confold" -qq
apt-get install -y -o Dpkg::Options::="--force-confold" -qq \
  curl wget git htop net-tools ufw fail2ban unzip \
  python3 openssl unattended-upgrades apt-listchanges dnsutils
apt-get autoremove -y -qq

echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" \
  | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
log_ok "Система обновлена, автообновления безопасности включены"

confirm_stage 0
fi  # END STAGE 0

# Обязательно загружаем переменные после stage 0 (или если пропускали)
load_vars

# Если выбранные этапы требуют пароля (этап 1), а пароль не задан — спросить
if should_run 1 && [[ -z "${USER_PASS:-}" ]]; then
  [[ -z "${NEW_USER:-}" ]] && die "NEW_USER не задан. Сначала запусти этап 0."
  log_info "Этап 1 требует пароль пользователя (не сохранялся)."
  ask_user_password "${NEW_USER}"
fi

# =============================================================================
#  ЭТАП 1 — ПОЛЬЗОВАТЕЛЬ, SSH, SWAP, UFW, FAIL2BAN
# =============================================================================
if should_run 1; then
CURRENT_STAGE=1
log_step "ЭТАП 1 — ${STAGE_NAMES[1]}"

#  1.1 Пользователь
log_section "1.1 — Создание пользователя ${NEW_USER}"

if id "$NEW_USER" &>/dev/null 2>&1; then
  log_warn "Пользователь ${NEW_USER} уже существует — обновляю пароль"
else
  useradd -m -s /bin/bash "$NEW_USER"
  log_ok "Пользователь ${NEW_USER} создан"
fi

echo "${NEW_USER}:${USER_PASS}" | chpasswd
usermod -aG sudo "$NEW_USER"
echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${NEW_USER}"
chmod 440 "/etc/sudoers.d/${NEW_USER}"

id "$NEW_USER" | grep -q sudo && log_ok "${NEW_USER} в группе sudo" || \
  log_warn "${NEW_USER} НЕ в группе sudo!"

#  1.2 SSH
log_section "1.2 — Настройка SSH (порт ${SSH_PORT})"

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

configure_ssh() {
  local param="$1" value="$2" file="/etc/ssh/sshd_config"
  if grep -qE "^[[:space:]]*#?[[:space:]]*${param}[[:space:]]" "$file"; then
    sed -i -E \
      "s|^[[:space:]]*#?[[:space:]]*${param}[[:space:]].*|${param} ${value}|g" \
      "$file"
  else
    echo "${param} ${value}" >> "$file"
  fi
}

configure_ssh "Port"                   "${SSH_PORT}"
configure_ssh "PermitRootLogin"        "no"
configure_ssh "PasswordAuthentication" "yes"
configure_ssh "PubkeyAuthentication"   "yes"
configure_ssh "UsePAM"                 "yes"  # нужен для парольной аутентификации Ubuntu 24
configure_ssh "MaxAuthTries"           "3"
configure_ssh "LoginGraceTime"         "30"
configure_ssh "AllowUsers"             "${NEW_USER}"
configure_ssh "ClientAliveInterval"    "300"
configure_ssh "ClientAliveCountMax"    "2"
configure_ssh "X11Forwarding"          "no"
configure_ssh "AllowTcpForwarding"     "no"

mkdir -p /run/sshd
sshd -t || {
  cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
  die "Ошибка в sshd_config — откат выполнен автоматически"
}

systemctl enable ssh
systemctl restart ssh
sleep 2

ss -tlnp | grep -q ":${SSH_PORT}" && log_ok "SSH слушает порт ${SSH_PORT}" || \
  log_warn "SSH не найден на порту ${SSH_PORT} — проверь: ss -tlnp"

echo ""
echo -e "${BOLD}${YELLOW}*** КРИТИЧНО: ПРОВЕРЬ SSH ДО ПРОДОЛЖЕНИЯ! ***${NC}"
echo -e "${BOLD}${YELLOW}Открой НОВЫЙ терминал и выполни:${NC}"
echo -e "${BOLD}${YELLOW}  ${CYAN}ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}${NC}"
echo -e "${BOLD}${YELLOW}Если вход НЕ удался — в ЭТОМ терминале:${NC}"
echo -e "${BOLD}${YELLOW}  ${RED}cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config${NC}"
echo -e "${BOLD}${YELLOW}  ${RED}systemctl restart ssh${NC}"
echo ""
read -rp "$(echo -e "${BOLD}Подтверди успешный вход в новом терминале, затем Enter:${NC} ")" _ || true

#  1.3 ICMP
log_section "1.3 — Отключение ICMP (ping)"
grep -q "icmp_echo_ignore_all" /etc/sysctl.conf || \
  printf '\n# Disable ICMP ping\nnet.ipv4.icmp_echo_ignore_all = 1\nnet.ipv6.icmp.echo_ignore_all = 1\n' \
    >> /etc/sysctl.conf
sysctl -p > /dev/null
log_ok "ICMP отключен"

#  1.4 Swap
log_section "1.4 — Swap-файл 1 ГБ"
if swapon --show | grep -q /swapfile; then
  log_warn "Swap уже активен — пропускаю"
else
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log_ok "Swap 1 ГБ создан"
fi
grep -q "vm.swappiness=10" /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
sysctl -p > /dev/null
free -h

#  1.5 Часовой пояс
timedatectl set-timezone Europe/Moscow
log_ok "Часовой пояс: Europe/Moscow"

#  1.6 UFW
log_section "1.6 — UFW брандмауэр"
ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing

# SSH: только порт SSH, без публичного доступа к другим сервисам
ufw allow "${SSH_PORT}/tcp"         comment 'SSH'
# NPM: нужен для HTTP/HTTPS и внутреннего админ-порта, но 81 закрыт снаружи после запуска NPM
ufw allow 80/tcp                    comment 'HTTP-NPM'
ufw allow 81/tcp                    comment 'NPM-Admin-temp'
ufw allow 443/tcp                   comment 'HTTPS-NPM'
# VPN: только заранее выбранные порты
ufw allow "${P_VLESS_REALITY}/tcp"  comment 'VLESS-Reality'
ufw allow "${P_VLESS_XHTTP}/tcp"    comment 'VLESS-XHTTP'
ufw allow "${P_TROJAN}/tcp"         comment 'Trojan'
ufw allow "${P_SS}/tcp"             comment 'Shadowsocks-TCP'
ufw allow "${P_SS}/udp"             comment 'Shadowsocks-UDP'
ufw allow "${P_H2}/udp"             comment 'Hysteria2-UDP'
ufw allow "${P_TELEMT}/tcp"         comment 'Telemt-MTProxy'

ufw --force enable > /dev/null
ufw status verbose

#  1.7 Fail2Ban
log_section "1.7 — Fail2Ban"
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 5h
findtime = 2m
maxretry = 2
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${SSH_PORT}
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban
sleep 2
fail2ban-client ping 2>/dev/null | grep -q "pong" && log_ok "Fail2Ban работает" || \
  log_warn "Fail2Ban не отвечает: journalctl -u fail2ban -n 30"

show_port_checks

confirm_stage 1
fi  # END STAGE 1

# =============================================================================
#  ЭТАП 2 — DOCKER
# =============================================================================
if should_run 2; then
CURRENT_STAGE=2
log_step "ЭТАП 2 — ${STAGE_NAMES[2]}"

log_section "2.1 — Установка Docker"
if command -v docker &>/dev/null; then
  log_warn "Docker уже установлен: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sh
  log_ok "Docker установлен"
fi

usermod -aG docker "$NEW_USER"
systemctl enable docker > /dev/null 2>&1
systemctl start docker
docker version --format 'Server: {{.Server.Version}}' 2>/dev/null && log_ok "Docker запущен" || \
  die "Docker не запустился — journalctl -u docker"

log_section "2.2 — Лимиты логов Docker"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker && sleep 2
log_ok "Лимиты логов: 20 МБ × 3 файла"

log_section "2.3 — Структура /opt/docker"
mkdir -p /opt/docker/{nginx-proxy-manager/{data,letsencrypt},\
nginx-site/html,3x-ui/{db,cert},telemt,hysteria2/cert}
chown -R "${NEW_USER}:${NEW_USER}" /opt/docker
log_ok "Папки созданы"

log_section "2.4 — Сеть proxy-net"
ensure_docker_network "proxy-net" "172.18.0.0/16"

confirm_stage 2
fi  # END STAGE 2

# =============================================================================
#  ЭТАП 3 — NGINX PROXY MANAGER
# =============================================================================
if should_run 3; then
CURRENT_STAGE=3
log_step "ЭТАП 3 — ${STAGE_NAMES[3]}"

log_info "Проверяем DNS-записи (нужны для SSL):"
wait_dns "${NPM_DOMAIN}"  "${SERVER_IP}"
wait_dns "${XUI_DOMAIN}"  "${SERVER_IP}"
wait_dns "${ROOT_DOMAIN}" "${SERVER_IP}"
wait_dns "${H2_DOMAIN}"   "${SERVER_IP}"

cat > /opt/docker/nginx-proxy-manager/docker-compose.yml << EOF
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - /opt/docker/nginx-proxy-manager/data:/data
      - /opt/docker/nginx-proxy-manager/letsencrypt:/etc/letsencrypt
    deploy:
      resources:
        limits:
          memory: 200M
          cpus: "0.5"
        reservations:
          memory: 64M
    networks:
      - proxy-net

networks:
  proxy-net:
    external: true
EOF

cd /opt/docker/nginx-proxy-manager
docker ps --format '{{.Names}}' | grep -q "^nginx-proxy-manager$" && docker compose down || true
docker compose up -d
log_info "Ждем инициализации NPM (25 сек)..."
sleep 25

docker ps --format '{{.Names}} {{.Status}}' | grep "nginx-proxy-manager" | grep -q "Up" && \
  log_ok "NPM запущен" || die "NPM не запустился: docker logs nginx-proxy-manager"

echo ""
echo -e "${BOLD}${YELLOW}*** ДЕЙСТВИЯ В БРАУЗЕРЕ — NPM ***${NC}"
echo -e "${BOLD}${YELLOW}1. Открой: ${CYAN}http://${SERVER_IP}:81${NC}"
echo -e "${BOLD}${YELLOW}2. Войди: admin@example.com / changeme${NC}"
echo -e "${BOLD}${YELLOW}3. Смени email → ${GREEN}${LE_EMAIL}${NC} и задай новый пароль"
echo -e "${BOLD}${YELLOW}4. Add Proxy Host:${NC}"
echo -e "${BOLD}${YELLOW}   Domain: ${CYAN}${NPM_DOMAIN}${NC}"
echo -e "${BOLD}${YELLOW}   Forward: ${GREEN}nginx-proxy-manager : 81${NC}"
echo -e "${BOLD}${YELLOW}   SSL: Let's Encrypt + Force SSL + HTTP/2${NC}"
echo -e "${BOLD}${YELLOW}DNS записи (тип A) должны быть настроены:${NC}"
echo -e "${BOLD}${YELLOW}  ${ROOT_DOMAIN}     → ${SERVER_IP}${NC}"
echo -e "${BOLD}${YELLOW}  www.${ROOT_DOMAIN} → ${SERVER_IP}${NC}"
echo -e "${BOLD}${YELLOW}  ${NPM_DOMAIN} → ${SERVER_IP}${NC}"
echo -e "${BOLD}${YELLOW}  ${XUI_DOMAIN} → ${SERVER_IP}${NC}"
echo -e "${BOLD}${YELLOW}  ${H2_DOMAIN}  → ${SERVER_IP}${NC}"
echo ""
read -rp "$(echo -e "${BOLD}Выполни все выше, убедись https://${NPM_DOMAIN} открывается → Enter:${NC} ")" _ || true

#  Закрываем прямой доступ к порту 81
log_section "Закрываем порт 81 снаружи"
ufw delete allow 81/tcp 2>/dev/null || true

if grep -q '"81:81"' /opt/docker/nginx-proxy-manager/docker-compose.yml; then
  sed -i 's|- "81:81"|- "127.0.0.1:81:81"|' \
    /opt/docker/nginx-proxy-manager/docker-compose.yml
  log_ok "Порт 81 привязан к localhost"
elif grep -q '127.0.0.1:81:81' /opt/docker/nginx-proxy-manager/docker-compose.yml; then
  log_warn "Порт 81 уже привязан к localhost — пропускаю"
else
  log_warn "Не удалось найти строку с портом 81 в docker-compose.yml — проверь вручную"
fi

cd /opt/docker/nginx-proxy-manager
docker compose down && docker compose up -d
log_info "Ждем перезапуска NPM (15 сек)..."
sleep 15

docker ps --format '{{.Names}} {{.Status}}' | grep "nginx-proxy-manager" | grep -q "Up" && \
  log_ok "NPM перезапущен" || log_warn "NPM: docker logs nginx-proxy-manager"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://${NPM_DOMAIN}" 2>/dev/null || echo "000")
[[ "$HTTP_CODE" =~ ^(200|301|302)$ ]] && \
  log_ok "https://${NPM_DOMAIN} → HTTP ${HTTP_CODE}" || \
  log_warn "https://${NPM_DOMAIN} → HTTP ${HTTP_CODE} (проверь настройки NPM)"

DIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
  "http://${SERVER_IP}:81" 2>/dev/null || echo "000")
[[ "$DIRECT_CODE" == "000" ]] && log_ok "Прямой доступ к :81 закрыт" || \
  log_warn "Порт 81 все еще доступен (HTTP ${DIRECT_CODE})"

confirm_stage 3
fi  # END STAGE 3

# =============================================================================
#  ЭТАП 4 — NGINX САЙТ-ЗАГЛУШКА
# =============================================================================
if should_run 4; then
CURRENT_STAGE=4
log_step "ЭТАП 4 — ${STAGE_NAMES[4]}"

cat > /opt/docker/nginx-site/html/index.html << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${ROOT_DOMAIN}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      min-height: 100vh; display: flex; align-items: center;
      justify-content: center; background: #0f0f0f;
      font-family: 'Courier New', monospace; color: #e0e0e0;
    }
    .container { text-align: center; padding: 2rem; }
    .title { font-size: 2.5rem; color: #00ff88; margin-bottom: 1rem; }
    .subtitle { font-size: 1rem; color: #888; margin-bottom: 2rem; }
    .status {
      display: inline-block; padding: .5rem 1.5rem;
      border: 1px solid #00ff88; color: #00ff88;
      font-size: .85rem; letter-spacing: 2px;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="title">${ROOT_DOMAIN}</div>
    <div class="subtitle">site under construction</div>
    <div class="status">[ COMING SOON ]</div>
  </div>
</body>
</html>
EOF

cat > /opt/docker/nginx-site/docker-compose.yml << 'EOF'
services:
  nginx-site:
    image: nginx:alpine
    container_name: nginx-site
    restart: unless-stopped
    volumes:
      - /opt/docker/nginx-site/html:/usr/share/nginx/html:ro
    expose:
      - "80"
    deploy:
      resources:
        limits:
          memory: 64M
          cpus: "0.25"
        reservations:
          memory: 16M
    networks:
      - proxy-net

networks:
  proxy-net:
    external: true
EOF

cd /opt/docker/nginx-site
docker ps --format '{{.Names}}' | grep -q "^nginx-site$" && docker compose down || true
docker compose up -d && sleep 5
docker ps --format '{{.Names}} {{.Status}}' | grep "nginx-site" | grep -q "Up" && \
  log_ok "nginx-site запущен" || log_warn "nginx-site: docker logs nginx-site"

echo ""
echo -e "${YELLOW}В NPM → Add Proxy Host:${NC}"
echo -e "  Domain Names:     ${CYAN}${ROOT_DOMAIN}${NC}  +  ${CYAN}www.${ROOT_DOMAIN}${NC}"
echo -e "  Forward Hostname: ${GREEN}nginx-site${NC}"
echo -e "  Forward Port:     ${GREEN}80${NC}"
echo -e "  ✔ Websockets Support  ✔ Block Common Exploits"
echo -e "  SSL: Let's Encrypt + Force SSL + HTTP/2"
echo ""
read -rp "$(echo -e "${BOLD}Настрой Proxy Host, проверь https://${ROOT_DOMAIN} → Enter:${NC} ")" _ || true

confirm_stage 4
fi  # END STAGE 4

# =============================================================================
#  ЭТАП 5 — 3x-ui
# =============================================================================
if should_run 5; then
CURRENT_STAGE=5
log_step "ЭТАП 5 — ${STAGE_NAMES[5]}"

cat > /opt/docker/3x-ui/docker-compose.yml << EOF
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    restart: unless-stopped
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
    ports:
      - "${P_VLESS_REALITY}:${P_VLESS_REALITY}"
      - "${P_VLESS_XHTTP}:${P_VLESS_XHTTP}"
      - "${P_TROJAN}:${P_TROJAN}"
      - "${P_SS}:${P_SS}"
      - "${P_SS}:${P_SS}/udp"
    expose:
      - "${XUI_PORT}"
    volumes:
      - /opt/docker/3x-ui/db:/etc/x-ui
      - /opt/docker/3x-ui/cert:/root/cert
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: "0.5"
        reservations:
          memory: 64M
    networks:
      - proxy-net

networks:
  proxy-net:
    external: true
EOF

cd /opt/docker/3x-ui
docker ps --format '{{.Names}}' | grep -q "^3x-ui$" && docker compose down || true
docker compose pull
docker compose up -d
log_info "Ждем запуска 3x-ui (20 сек)..."
sleep 20

docker ps --format '{{.Names}} {{.Status}}' | grep "3x-ui" | grep -q "Up" && \
  log_ok "3x-ui запущен" || log_warn "3x-ui не запустился: docker logs 3x-ui"

#  Автокопирование сертификата NPM → 3x-ui
log_section "5.1 — Сертификат NPM → 3x-ui"
_LE_DIR="/opt/docker/nginx-proxy-manager/letsencrypt/live"
_CERT_FOUND=""

if [[ -d "$_LE_DIR" ]]; then
  for _dir in "${_LE_DIR}"/*/; do
    echo "$_dir" | grep -qi "${XUI_DOMAIN}" && { _CERT_FOUND="$_dir"; break; } || true
  done

  if [[ -z "$_CERT_FOUND" ]]; then
    _CERT_FOUND=$(find "$_LE_DIR" -name "fullchain.pem" \
      -exec stat --format='%Y %n' {} \; 2>/dev/null \
      | sort -rn | head -1 | awk '{print $2}' | xargs dirname 2>/dev/null || true)
  fi
fi

if [[ -n "$_CERT_FOUND" && -f "${_CERT_FOUND}/fullchain.pem" ]]; then
  cp "${_CERT_FOUND}/fullchain.pem" /opt/docker/3x-ui/cert/fullchain.pem
  cp "${_CERT_FOUND}/privkey.pem"   /opt/docker/3x-ui/cert/privkey.pem
  chmod 644 /opt/docker/3x-ui/cert/fullchain.pem
  chmod 600 /opt/docker/3x-ui/cert/privkey.pem
  log_ok "Сертификат скопирован → /opt/docker/3x-ui/cert/"
  log_info "В Panel Settings → Certificate:"
  log_info "  Cert: /root/cert/fullchain.pem"
  log_info "  Key:  /root/cert/privkey.pem"
else
  log_warn "Сертификат NPM не найден — создай сначала Proxy Host для ${XUI_DOMAIN}"
fi

echo ""
echo -e "${BOLD}${YELLOW}*** ДЕЙСТВИЯ В NPM — 3x-ui ***${NC}"
echo -e "${BOLD}${YELLOW}1. Add Proxy Host:${NC}"
echo -e "${BOLD}${YELLOW}   Domain: ${CYAN}${XUI_DOMAIN}${NC}"
echo -e "${BOLD}${YELLOW}   Forward: ${GREEN}3x-ui : ${XUI_PORT}${NC}"
echo -e "${BOLD}${YELLOW}   ✔ Websockets Support | SSL Let's Encrypt + Force SSL${NC}"
echo -e "${BOLD}${YELLOW}2. Войди в панель: ${CYAN}https://${XUI_DOMAIN}${NC}"
echo -e "${BOLD}${YELLOW}   Логин по умолчанию: admin / admin${NC}"
echo -e "${BOLD}${YELLOW}3. Смени пароль (если UI не позволяет):${NC}"
echo -e "${BOLD}${YELLOW}   ${CYAN}docker exec -it 3x-ui x-ui${NC}  → пункт 7"
echo -e "${BOLD}${YELLOW}4. Panel Settings → укажи пути к сертификату${NC}"
echo ""
read -rp "$(echo -e "${BOLD}Настрой NPM и войди в панель 3x-ui → Enter:${NC} ")" _ || true

confirm_stage 5
fi  # END STAGE 5

# =============================================================================
#  ЭТАП 6 — HYSTERIA 2
# =============================================================================
if should_run 6; then
CURRENT_STAGE=6
log_step "ЭТАП 6 — ${STAGE_NAMES[6]}"

_HOME_DIR=$(getent passwd "$NEW_USER" | cut -d: -f6)
_ACME="${_HOME_DIR}/.acme.sh/acme.sh"
_CERT_DIR="/opt/docker/hysteria2/cert"
chown -R "${NEW_USER}:${NEW_USER}" "${_CERT_DIR}"

wait_dns "${H2_DOMAIN}" "${SERVER_IP}"

#  acme.sh
log_section "6.1 — acme.sh"
if [[ -f "$_ACME" ]]; then
  log_warn "acme.sh уже установлен в ${_HOME_DIR}"
else
  su - "$NEW_USER" -c "curl https://get.acme.sh | sh -s email=${LE_EMAIL}"
  log_ok "acme.sh установлен"
fi

#  Получение сертификата
log_section "6.2 — TLS-сертификат для ${H2_DOMAIN}"
_CERT_OK=false

if [[ -f "${_CERT_DIR}/fullchain.pem" ]]; then
  _EXP=$(openssl x509 -in "${_CERT_DIR}/fullchain.pem" -noout -enddate 2>/dev/null \
    | cut -d= -f2 || echo "?")
  log_warn "Сертификат уже существует (истекает: ${_EXP}) — пропускаю"
  _CERT_OK=true
fi

if [[ "$_CERT_OK" == "false" ]]; then
  _WEBROOT="/opt/docker/nginx-proxy-manager/data/letsencrypt-acme-challenge"
  mkdir -p "$_WEBROOT"
  chown -R "${NEW_USER}:${NEW_USER}" "$_WEBROOT"

  log_info "Попытка 1: webroot через NPM..."
  if su - "$NEW_USER" -c \
    "${_ACME} --issue -d ${H2_DOMAIN} --webroot ${_WEBROOT} --server letsencrypt --force 2>&1"
  then
    log_ok "Сертификат получен (webroot)"
    _CERT_OK=true
  else
    log_warn "Webroot не сработал. Попытка 2: standalone (~60 сек, NPM остановится)"
    cd /opt/docker/nginx-proxy-manager && docker compose stop
    sleep 3

    if su - "$NEW_USER" -c \
      "${_ACME} --issue -d ${H2_DOMAIN} --standalone --httpport 80 --server letsencrypt --force 2>&1"
    then
      log_ok "Сертификат получен (standalone)"
      _CERT_OK=true
    fi

    cd /opt/docker/nginx-proxy-manager && docker compose up -d && sleep 10
  fi
fi

[[ "$_CERT_OK" == "true" ]] || die "Не удалось получить сертификат для ${H2_DOMAIN}. DNS настроен? Порт 80 открыт?"

#  Установка сертификата
log_section "6.3 — Установка сертификата"
chown -R "${NEW_USER}:${NEW_USER}" "${_CERT_DIR}"

su - "$NEW_USER" -c "
  ${_ACME} --install-cert -d ${H2_DOMAIN} \
    --cert-file      ${_CERT_DIR}/cert.pem \
    --key-file       ${_CERT_DIR}/key.pem \
    --fullchain-file ${_CERT_DIR}/fullchain.pem \
    --reloadcmd 'docker restart hysteria2 2>/dev/null || true'
"
[[ -f "${_CERT_DIR}/fullchain.pem" ]] && log_ok "Сертификат установлен" || \
  die "Файл сертификата не найден в ${_CERT_DIR}"

#  Конфиг Hysteria2
log_section "6.4 — Конфиг Hysteria 2"
cat > /opt/docker/hysteria2/config.yaml << EOF
listen: :${P_H2}

tls:
  cert: /cert/fullchain.pem
  key: /cert/key.pem

auth:
  type: password
  password: ${H2_PASS}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com
    rewriteHost: true

bandwidth:
  up: 100 mbps
  down: 100 mbps
EOF

cat > /opt/docker/hysteria2/docker-compose.yml << EOF
services:
  hysteria2:
    image: tobyxdd/hysteria:latest
    container_name: hysteria2
    restart: unless-stopped
    ports:
      - "${P_H2}:${P_H2}/udp"
    volumes:
      - /opt/docker/hysteria2/cert:/cert:ro
      - /opt/docker/hysteria2/config.yaml:/etc/hysteria/config.yaml:ro
    command: server
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: "0.5"
        reservations:
          memory: 32M
    networks:
      - proxy-net

networks:
  proxy-net:
    external: true
EOF

cd /opt/docker/hysteria2
docker ps --format '{{.Names}}' | grep -q "^hysteria2$" && docker compose down || true
docker compose up -d && sleep 10

docker ps --format '{{.Names}} {{.Status}}' | grep "hysteria2" | grep -q "Up" && \
  log_ok "Hysteria2 запущен" || log_warn "Hysteria2: docker logs hysteria2"
ss -ulnp | grep -q ":${P_H2}" && log_ok "UDP :${P_H2} слушает" || \
  log_warn "UDP :${P_H2} не найден — проверь: docker logs hysteria2"

HYSTERIA_URI="hysteria2://${H2_PASS}@${H2_DOMAIN}:${P_H2}?sni=${H2_DOMAIN}#Hysteria2"
log_info "Hysteria2: ${H2_DOMAIN}:${P_H2}"
log_info "Пароль: ${H2_PASS}"
log_info "URI: ${HYSTERIA_URI}"

confirm_stage 6
fi  # END STAGE 6

# =============================================================================
#  ЭТАП 7 — TELEMT MTProxy
# =============================================================================
if should_run 7; then
CURRENT_STAGE=7
log_step "ЭТАП 7 — ${STAGE_NAMES[7]}"

_TELEMT_TLS_DOMAIN="${TLS_DOMAIN:-www.apple.com}"
_TELEMT_DOMAIN_HEX=$(python3 -c "print('${_TELEMT_TLS_DOMAIN}'.encode().hex())")
_TELEMT_LINK_SECRET="ee${TELEMT_SECRET}${_TELEMT_DOMAIN_HEX}"
_TELEMT_TG_LINK="tg://proxy?server=${SERVER_IP}&port=${P_TELEMT}&secret=${_TELEMT_LINK_SECRET}"
_TELEMT_HTTPS_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${P_TELEMT}&secret=${_TELEMT_LINK_SECRET}"

python3 << PYEOF
config = """[general]
use_middle_proxy = true

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show = "*"

[server]
port = ${P_TELEMT}

[censorship]
tls_domain = "${TLS_DOMAIN}"

[access.users]
main = "${TELEMT_SECRET}"
"""
with open('/opt/docker/telemt/config.toml', 'w') as f:
    f.write(config)
PYEOF

cat > /opt/docker/telemt/docker-compose.yml << EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    ports:
      - "${P_TELEMT}:${P_TELEMT}"
    volumes:
      - /opt/docker/telemt/config.toml:/run/telemt/config.toml:ro
    working_dir: /run/telemt
    environment:
      - RUST_LOG=info
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,size=10m
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    deploy:
      resources:
        limits:
          memory: 64M
          cpus: "0.25"
        reservations:
          memory: 16M
    networks:
      - proxy-net

networks:
  proxy-net:
    external: true
EOF

cd /opt/docker/telemt
docker ps --format '{{.Names}}' | grep -q "^telemt$" && docker compose down || true
docker compose pull
docker compose up -d
wait_for_container_ready "telemt" 30 || die "Telemt не запустился"

if docker ps --format '{{.Names}} {{.Status}}' | grep "telemt" | grep -q "Up"; then
  log_ok "Telemt запущен"
else
  log_error "Telemt не отвечает после запуска"
  docker logs telemt 2>&1 || true
  die "Telemt: контейнер запущен, но сервис не готов"
fi

log_info "Telegram MTProxy ссылки:"
echo -e "  ${CYAN}${_TELEMT_TG_LINK}${NC}"
echo -e "  ${CYAN}${_TELEMT_HTTPS_LINK}${NC}"

confirm_stage 7
fi  # END STAGE 7

# =============================================================================
#  ИТОГОВАЯ СВОДКА
# =============================================================================
load_vars  # обновляем переменные

# Пересчитываем Telemt ссылки
_TLS_D="${TLS_DOMAIN:-www.apple.com}"
_TLS_HEX=$(python3 -c "print('${_TLS_D}'.encode().hex())" 2>/dev/null || echo "")
_TELEMT_LINK_SECRET="ee${TELEMT_SECRET:-}${_TLS_HEX}"
_TG_LINK="tg://proxy?server=${SERVER_IP}&port=${P_TELEMT}&secret=${_TELEMT_LINK_SECRET}"

log_step "УСТАНОВКА ЗАВЕРШЕНА"

echo "*** ИТОГ УСТАНОВКИ ***"
echo "SSH: ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}"
echo "NPM: https://${NPM_DOMAIN}"
echo "3x-ui: https://${XUI_DOMAIN}"
echo "Сайт: https://${ROOT_DOMAIN}"
echo "Hysteria2: ${H2_DOMAIN}:${P_H2}"
echo "Telemt: ${SERVER_IP}:${P_TELEMT}"
echo "tls_domain: ${TLS_DOMAIN}"
echo "Детали (пароли): ${SUMMARY_FILE}"
show_port_checks

# =============================================================================
#  ЗАПИСЬ ИТОГОВОГО ФАЙЛА
# =============================================================================
cat > "$SUMMARY_FILE" << HEREDOC
*** VPS SETUP SUMMARY — $(date) ***

Удали этот файл после сохранения данных:
  rm ${SUMMARY_FILE}

Пароль SSH (${NEW_USER}) НЕ сохранен в этот файл.
Hysteria2 и Telemt секреты — сгенерированы автоматически.

*** SSH ***
  ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}
  Пользователь: ${NEW_USER}
  Пароль: [введен при установке — не сохраняется]

*** ПАНЕЛИ ***
  NPM: https://${NPM_DOMAIN}
  3x-ui: https://${XUI_DOMAIN}
  Сайт: https://${ROOT_DOMAIN}

  Сменить логин/пароль 3x-ui:
    docker exec -it 3x-ui x-ui -> пункт 7 "Reset username and password"

  Сертификаты для 3x-ui inbounds:
    Cert: /root/cert/fullchain.pem
    Key: /root/cert/privkey.pem
    На хосте: /opt/docker/3x-ui/cert/

*** VPN ПОРТЫ ***
  VLESS-Reality: ${SERVER_IP}:${P_VLESS_REALITY}/tcp
  VLESS-XHTTP: ${SERVER_IP}:${P_VLESS_XHTTP}/tcp
  Trojan: ${SERVER_IP}:${P_TROJAN}/tcp
  Shadowsocks: ${SERVER_IP}:${P_SS}/tcp+udp

*** HYSTERIA2 ***
  Сервер: ${H2_DOMAIN}:${P_H2} (UDP)
  Пароль: ${H2_PASS}
  URI: hysteria2://${H2_PASS}@${H2_DOMAIN}:${P_H2}?sni=${H2_DOMAIN}#H2
  Клиенты: Hiddify, v2rayN, NekoBox, Clash.Meta

*** TELEMT MTPROXY (FakeTLS) ***
  Сервер: ${SERVER_IP}:${P_TELEMT}
  tls_domain: ${TLS_DOMAIN}
  Config secret: ${TELEMT_SECRET}
  Link secret: ${_TELEMT_LINK_SECRET}
  TG: tg://proxy?server=${SERVER_IP}&port=${P_TELEMT}&secret=${_TELEMT_LINK_SECRET}
  HTTPS: https://t.me/proxy?server=${SERVER_IP}&port=${P_TELEMT}&secret=${_TELEMT_LINK_SECRET}

*** UFW / FAIL2BAN: что добавлено и зачем ***
  UFW:
    - default deny incoming
    - default allow outgoing
    - открыт только SSH порт ${SSH_PORT}/tcp
    - открыт только NPM 80/tcp, 443/tcp, 81/tcp (внутренний admin)
    - открыты только VPN порты: ${P_VLESS_REALITY}, ${P_VLESS_XHTTP}, ${P_TROJAN}, ${P_SS}, ${P_H2}, ${P_TELEMT}
    - всё остальное закрыто и недоступно снаружи
  Команды:
    ufw allow 8450/tcp comment 'My app'
    ufw delete allow 8450/tcp
    ufw status numbered

  Fail2Ban:
    - работает для sshd
    - bantime = 5h
    - findtime = 2m
    - maxretry = 3
    - защищает SSH от brute-force атак
  Команды:
    nano /etc/fail2ban/jail.local
    systemctl restart fail2ban
    fail2ban-client status sshd

*** ПОЛЕЗНЫЕ КОМАНДЫ ***
  docker ps --all
  docker stats --no-stream
  docker logs nginx-proxy-manager -f
  docker logs 3x-ui -f
  docker logs hysteria2 -f
  docker logs telemt -f
  ufw status verbose
  fail2ban-client status sshd
  journalctl -u ssh -n 50
  free -h && df -h
  tail -f ${LOG_FILE}

*** ОБНОВЛЕНИЕ КОНТЕЙНЕРОВ ***
  cd /opt/docker/nginx-proxy-manager && docker compose pull && docker compose up -d
  cd /opt/docker/3x-ui && docker compose pull && docker compose up -d
  cd /opt/docker/hysteria2 && docker compose pull && docker compose up -d
  cd /opt/docker/telemt && docker compose pull && docker compose up -d

*** ОБНОВЛЕНИЕ СЕРТИФИКАТА HYSTERIA2 ***
  su - ${NEW_USER} -c "~/.acme.sh/acme.sh --renew -d ${H2_DOMAIN} --force"

*** ИНСТРУКЦИЯ: ДОБАВИТЬ НОВЫЙ ПРОТОКОЛ В 3x-ui ***
  Когда добавляешь новый inbound в 3x-ui на новом порту (например 8450):

  1) Добавь inbound в 3x-ui
  2) Пробрось порт в /opt/docker/3x-ui/docker-compose.yml
      ports:
        - "8450:8450"
        - "8450:8450/udp"   # если нужен UDP
  3) Перезапусти контейнер:
      cd /opt/docker/3x-ui && docker compose up -d
  4) Открой в UFW:
      ufw allow 8450/tcp comment 'My protocol'
  5) Проверь доступность:
      ss -tlnp | grep 8450
      nc -zv ${SERVER_IP} 8450

*** СОВЕТ ***
  Не открывай лишние порты.
  Если не надо — не открывай. В этом скрипте оставлены только нужные порты.

*** СТРУКТУРА ФАЙЛОВ ***
  /opt/docker/
    nginx-proxy-manager/
      data/
      letsencrypt/
      docker-compose.yml
    nginx-site/
      html/index.html
      docker-compose.yml
    3x-ui/
      db/
      cert/
      docker-compose.yml
    hysteria2/
      cert/
      config.yaml
      docker-compose.yml
    telemt/
      config.toml
      docker-compose.yml
HEREDOC

chmod 600 "$SUMMARY_FILE"
save_state "done"

echo ""
log_ok "Сводка сохранена: ${SUMMARY_FILE}"
echo ""
log_warn "Прочитай, скопируй нужное в менеджер паролей, затем удали:"
echo -e "  ${CYAN}cat ${SUMMARY_FILE}${NC}"
echo -e "  ${RED}rm ${SUMMARY_FILE}${NC}"
echo -e "  ${RED}rm ${VARS_FILE}${NC}"
echo ""
log_info "Полный лог установки: ${LOG_FILE}"