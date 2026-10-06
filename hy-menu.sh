#!/bin/bash
# ============================================================
#  Hysteria2 Manager v3.0 (без панели / с опциональной h-ui)
# ============================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# --- НАСТРОЙКИ ---
DOMAIN="x7q9m2v4k8n3p6r1w5zt.footbol.lol"
PORT=53
AUTH_PASS="Hy2_Malika_Xk9pQ3mNv7Rw"
OBFS_PASS="Salam_Nx7Km2Pq9Rt4Vw8"
SNI="dl.google.com"
MASQ_URL="https://dl.google.com"
BANDWIDTH_UP="50"
BANDWIDTH_DOWN="50"
HUI_PORT=8081
# -----------------

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
pause() { echo ""; read -p "Нажмите Enter..." _; }

get_fingerprint() {
    if [ -f /etc/hysteria/cert.pem ]; then
        openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/cert.pem 2>/dev/null | sed 's/^.*=//' | tr -d ':'
    fi
}

show_key_compact() {
    local FP
    FP=$(get_fingerprint)
    if [ -n "$FP" ]; then
        echo "hysteria2://$AUTH_PASS@$DOMAIN:$PORT/?sni=$SNI&obfs=salamander&obfs-password=$OBFS_PASS&pinSHA256=$FP#Hysteria"
    else
        echo "hysteria2://$AUTH_PASS@$DOMAIN:$PORT/?sni=$SNI&obfs=salamander&obfs-password=$OBFS_PASS&insecure=1#Hysteria"
    fi
}

# ============================================================
#  УСТАНОВКА
# ============================================================

install_hysteria() {
    log "Установка Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/)
    log "Готово"
}

free_port_53() {
    log "Отключаем systemd-resolved и освобождаем порт 53..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf 2>/dev/null || true
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    log "DNS переключён на 1.1.1.1"
    echo ""
    echo "Кто слушает :53 сейчас:"
    ss -ulpn | grep ":53" || echo "  Порт 53 свободен"
}

get_cert() {
    echo -n "Введите домен (Enter = $DOMAIN): "
    read NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && NEW_DOMAIN="$DOMAIN"

    log "Останавливаем Hysteria (освобождаем порт 80)..."
    systemctl stop hysteria-server 2>/dev/null || true
    pkill -f hysteria 2>/dev/null || true
    sleep 3

    apt install -y certbot > /dev/null 2>&1

    log "Запрос сертификата для $NEW_DOMAIN..."
    certbot certonly --standalone -d "$NEW_DOMAIN" \
        --non-interactive --agree-tos --register-unsafely-without-email

    if [ ! -f "/etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem" ]; then
        err "Не удалось получить сертификат."
        return 1
    fi

    log "Копируем сертификаты в /etc/hysteria/..."
    mkdir -p /etc/hysteria
    cp "/etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem" /etc/hysteria/cert.pem
    cp "/etc/letsencrypt/live/$NEW_DOMAIN/privkey.pem" /etc/hysteria/key.pem
    chmod 644 /etc/hysteria/cert.pem
    chmod 600 /etc/hysteria/key.pem
    if id "hysteria" &>/dev/null; then
        fix_perm
    fi
    log "Сертификат установлен (домен: $NEW_DOMAIN)"

    DOMAIN="$NEW_DOMAIN"
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$NEW_DOMAIN\"|" "$(readlink -f "$0")"
}

create_config() {
    if [ ! -f /etc/hysteria/cert.pem ]; then
        err "Сначала получите сертификат (пункт 4)!"
        return
    fi
    log "Создание конфига..."
    cat > /etc/hysteria/config.yaml << EOF
listen: :$PORT

tls:
  cert: /etc/hysteria/cert.pem
  key: /etc/hysteria/key.pem
  sniGuard: disable

auth:
  type: password
  password: "$AUTH_PASS"

obfs:
  type: salamander
  salamander:
    password: "$OBFS_PASS"

bandwidth:
  up: $BANDWIDTH_UP mbps
  down: $BANDWIDTH_DOWN mbps

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: true
    insecure: true
  listenHTTP: :80
  listenHTTPS: :443
  forceHTTPS: true
EOF
    if id "hysteria" &>/dev/null; then
        fix_perm
    fi
    log "Конфиг создан: /etc/hysteria/config.yaml"
}

# ============================================================
#  ПАНЕЛЬ H-UI (БЕЗ DOCKER)
# ============================================================

install_hui() {
    log "Установка панели h-ui (systemd)..."
    echo -n "Введите порт для веб-панели (Enter = $HUI_PORT): "
    read NEW_PORT
    [ -n "$NEW_PORT" ] && HUI_PORT="$NEW_PORT"

    mkdir -p /usr/local/h-ui/

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) BIN="h-ui-linux-amd64" ;;
        aarch64) BIN="h-ui-linux-arm64" ;;
        *) err "Неподдерживаемая архитектура: $ARCH"; return 1 ;;
    esac

    log "Скачиваем бинарник ($BIN)..."
    curl -fsSL "https://github.com/jonssonyan/h-ui/releases/latest/download/$BIN" \
        -o /usr/local/h-ui/h-ui
    chmod +x /usr/local/h-ui/h-ui

    log "Создаём systemd-сервис..."
    cat > /etc/systemd/system/h-ui.service << EOF
[Unit]
Description=h-ui Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/local/h-ui
ExecStart=/usr/local/h-ui/h-ui -p $HUI_PORT
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable h-ui > /dev/null 2>&1
    systemctl restart h-ui
    sleep 3

    if systemctl is-active --quiet h-ui; then
        log "✅ Панель h-ui запущена"
        echo ""
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${YELLOW}Доступ к панели:${NC}"
        echo "  http://$(curl -4 -s ifconfig.me):$HUI_PORT"
        echo ""
        echo -e "${YELLOW}Логин по умолчанию:${NC}"
        echo "  Логин:  sysadmin"
        echo "  Пароль: sysadmin"
        echo ""
        warn "Обязательно смените пароль после входа!"
        echo -e "${CYAN}============================================================${NC}"
    else
        err "Панель не запустилась. Логи:"
        journalctl -u h-ui -n 20 --no-pager
    fi
}

fix_perm() {
    chmod 644 /etc/hysteria/cert.pem 2>/dev/null
    chmod 644 /etc/hysteria/config.yaml 2>/dev/null
    if id hysteria &>/dev/null; then
        chown root:hysteria /etc/hysteria/key.pem 2>/dev/null
        chmod 640 /etc/hysteria/key.pem 2>/dev/null
    fi
}

# ============================================================
#  УПРАВЛЕНИЕ
# ============================================================

start_hysteria() {
    fix_perm 2>/dev/null
    log "Запуск Hysteria..."
    systemctl daemon-reload
    systemctl enable hysteria-server > /dev/null 2>&1
    systemctl restart hysteria-server
    sleep 3
    show_status
}

restart_hysteria() {
    log "Перезапуск Hysteria..."
    systemctl restart hysteria-server
    sleep 2
    show_status
}

stop_hysteria() {
    log "Остановка Hysteria..."
    systemctl stop hysteria-server
    log "Остановлена"
}

show_status() {
    echo ""
    echo -e "${CYAN}=== Статус ===${NC}"
    if systemctl is-active --quiet hysteria-server; then
        echo -e "${GREEN}✅ Hysteria работает${NC}"
    else
        echo -e "${RED}❌ Hysteria не работает${NC}"
    fi
    echo ""
    echo "Порты:"
    ss -ulpn | grep ":$PORT" || echo "  UDP $PORT: не занят"
    ss -tlnp | grep ":80 " || echo "  TCP 80: не занят"
    ss -tlnp | grep ":443 " || echo "  TCP 443: не занят"
    if systemctl is-active --quiet h-ui; then
        echo -e "${GREEN}✅ Панель h-ui работает${NC}"
        ss -tlnp | grep ":$HUI_PORT " || echo "  TCP $HUI_PORT: не занят"
    fi
}

show_logs() {
    echo -e "${CYAN}Последние 30 строк логов Hysteria:${NC}"
    journalctl -u hysteria-server -n 30 --no-pager
}

# ============================================================
#  БЕЗОПАСНОСТЬ
# ============================================================

setup_ufw() {
    echo ""
    log "Настройка UFW..."

    local SSH_PORT
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    echo -e "  SSH-порт: ${GREEN}$SSH_PORT${NC}"
    echo ""

    if ! command -v ufw &>/dev/null; then
        log "Устанавливаем ufw..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw < /dev/null
    fi

    log "Разрешаем SSH (порт $SSH_PORT)..."
    ufw allow "$SSH_PORT"/tcp comment 'SSH' 2>&1 | head -3

    log "Устанавливаем политики..."
    ufw default deny incoming 2>&1 | head -1
    ufw default allow outgoing 2>&1 | head -1

    log "Разрешаем порты Hysteria и панели..."
    ufw allow "$PORT"/udp comment 'Hysteria2' 2>&1 | head -1
    ufw allow 80/tcp comment 'Masquerade HTTP' 2>&1 | head -1
    ufw allow 443/tcp comment 'Masquerade HTTPS' 2>&1 | head -1
    ufw allow "$HUI_PORT"/tcp comment 'h-ui Panel' 2>&1 | head -1

    echo ""
    log "Включаем UFW..."
    echo "y" | ufw --force enable 2>&1 | head -3

    echo ""
    log "✅ UFW настроен"
    echo ""
    ufw status verbose | head -20
}

setup_fail2ban() {
    log "Установка и настройка Fail2Ban..."
    apt install -y fail2ban > /dev/null 2>&1

    local SSH_PORT
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    cat > /etc/fail2ban/jail.local << F2B
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = systemd
F2B

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban > /dev/null 2>&1
    sleep 2

    log "Fail2Ban запущен:"
    fail2ban-client status sshd 2>/dev/null || warn "Проверьте позже: fail2ban-client status sshd"
}

setup_renew() {
    log "Настройка автопродления сертификата..."
    cat > /etc/cron.d/certbot-renew << 'CRON'
0 3 * * * root certbot renew --quiet --deploy-hook "cp \$RENEWED_LINEAGE/fullchain.pem /etc/hysteria/cert.pem && cp \$RENEWED_LINEAGE/privkey.pem /etc/hysteria/key.pem && chown hysteria:hysteria /etc/hysteria/cert.pem /etc/hysteria/key.pem 2>/dev/null; systemctl restart hysteria-server"
CRON
    chmod 644 /etc/cron.d/certbot-renew
    log "Автопродление настроено (ежедневно в 3:00)"
}

# ============================================================
#  ПРОВЕРКИ И ИНФО
# ============================================================

check_masq() {
    echo -n "Введите SNI для проверки (Enter = $SNI): "
    read TEST_SNI
    [ -z "$TEST_SNI" ] && TEST_SNI="$SNI"

    log "Запрос на localhost с SNI=$TEST_SNI..."
    echo ""
    curl -sk --resolve "$TEST_SNI:443:127.0.0.1" "https://$TEST_SNI/" 2>&1 | head -20
    echo ""
    echo "Если видите HTML Google/Apple — маскировка работает"
}

show_fingerprint() {
    local FP
    FP=$(get_fingerprint)
    if [ -z "$FP" ]; then
        err "Сертификат не найден"
        return
    fi
    echo ""
    echo -e "${CYAN}=== Отпечаток SHA-256 сертификата ===${NC}"
    echo -e "${GREEN}$FP${NC}"
    echo ""
    echo "Для ключа клиента: pinSHA256=$FP"
}

show_key() {
    local FP
    FP=$(get_fingerprint)
    if [ -z "$FP" ]; then
        warn "Сертификат не найден. Ключ будет без pinSHA256."
    fi

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${YELLOW}КЛЮЧ ДЛЯ HAPP:${NC}"
    echo ""
    echo -e "${GREEN}$(show_key_compact)${NC}"
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${YELLOW}Данные для ручного ввода:${NC}"
    echo "  Адрес:    $DOMAIN"
    echo "  Порт:     $PORT"
    echo "  Пароль:   $AUTH_PASS"
    echo "  SNI:      $SNI"
    echo "  Obfs:     salamander"
    echo "  Obfs-пароль: $OBFS_PASS"
    if [ -n "$FP" ]; then
        echo "  pinSHA256: $FP"
    else
        echo "  Без проверки TLS: ВКЛ"
    fi
    echo -e "${CYAN}============================================================${NC}"
}

# ============================================================
#  ИЗМЕНЕНИЕ ПАРАМЕТРОВ
# ============================================================

change_sni() {
    echo -n "Новый SNI (текущий: $SNI): "
    read NEW_SNI
    if [ -z "$NEW_SNI" ]; then
        warn "SNI не изменён"
        return
    fi
    SNI="$NEW_SNI"
    sed -i "s|^SNI=.*|SNI=\"$NEW_SNI\"|" "$(readlink -f "$0")"
    log "SNI изменён на: $NEW_SNI"
    warn "Не забудьте также изменить masquerade URL (пункт 15) и ключ в клиенте"
}

change_masq_url() {
    echo -n "Новый URL маскировки (текущий: $MASQ_URL): "
    read NEW_URL
    if [ -z "$NEW_URL" ]; then
        warn "URL не изменён"
        return
    fi
    MASQ_URL="$NEW_URL"
    sed -i "s|^MASQ_URL=.*|MASQ_URL=\"$NEW_URL\"|" "$(readlink -f "$0")"

    if [ -f /etc/hysteria/config.yaml ]; then
        sed -i "s|url: .*|url: $NEW_URL|" /etc/hysteria/config.yaml
        systemctl restart hysteria-server
        log "URL маскировки изменён и Hysteria перезапущена"
    else
        log "URL сохранён в меню (конфиг создастся позже)"
    fi
}

change_passwords() {
    echo -n "Новый пароль auth (Enter = оставить текущий): "
    read NEW_AUTH
    if [ -n "$NEW_AUTH" ]; then
        AUTH_PASS="$NEW_AUTH"
        sed -i "s|^AUTH_PASS=.*|AUTH_PASS=\"$NEW_AUTH\"|" "$(readlink -f "$0")"
    fi

    echo -n "Новый пароль obfs (Enter = оставить текущий): "
    read NEW_OBFS
    if [ -n "$NEW_OBFS" ]; then
        OBFS_PASS="$NEW_OBFS"
        sed -i "s|^OBFS_PASS=.*|OBFS_PASS=\"$NEW_OBFS\"|" "$(readlink -f "$0")"
    fi

    if [ -f /etc/hysteria/config.yaml ]; then
        if [ -n "$NEW_AUTH" ]; then
            sed -i "s|password: \"Hy2_.*\"|password: \"$AUTH_PASS\"|" /etc/hysteria/config.yaml
        fi
        if [ -n "$NEW_OBFS" ]; then
            sed -i "s|password: \"Salam_.*\"|password: \"$OBFS_PASS\"|" /etc/hysteria/config.yaml
        fi
        systemctl restart hysteria-server
        log "Пароли обновлены и Hysteria перезапущена"
    else
        log "Пароли сохранены в меню"
    fi
}

# ============================================================
#  РЕДАКТИРОВАНИЕ КОНФИГА
# ============================================================
edit_config() {
    if [ ! -f /etc/hysteria/config.yaml ]; then
        err "Конфиг /etc/hysteria/config.yaml не найден!"
        return 1
    fi
    log "Открываем конфиг в редакторе..."
    cp /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak
    warn "Создан бэкап: /etc/hysteria/config.yaml.bak"
    echo ""
    sleep 1
    nano /etc/hysteria/config.yaml

    echo ""
    read -p "Перезапустить Hysteria с новыми настройками? (y/n): " RESTART
    if [ "$RESTART" = "y" ]; then
        systemctl restart hysteria-server
        sleep 3
        if systemctl is-active --quiet hysteria-server; then
            log "✅ Hysteria перезапущена"
        else
            err "❌ Hysteria не запустилась. Восстановить бэкап? Смотрите логи:"
            journalctl -u hysteria-server -n 20 --no-pager
        fi
    else
        warn "Изменения сохранены, но Hysteria не перезапущена"
    fi
}


# ---------- Удаление Hysteria2 ----------
remove_hysteria() {
    warn "Будет удалено: Hysteria2, сервис, конфиг, сертификаты"
    read -p "  Продолжить? (y/n): " A
    [ "$A" != "y" ] && return
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    rm -f /usr/local/bin/hysteria
    rm -f /etc/systemd/system/hysteria-server*.service
    rm -rf /etc/hysteria
    systemctl daemon-reload
    log "Hysteria2 удалена"
}

# ---------- Удаление h-ui ----------
remove_hui() {
    warn "Будет удалено: h-ui, сервис, файлы"
    read -p "  Продолжить? (y/n): " A
    [ "$A" != "y" ] && return
    systemctl stop h-ui 2>/dev/null || true
    systemctl disable h-ui 2>/dev/null || true
    rm -f /etc/systemd/system/h-ui.service
    rm -rf /usr/local/h-ui
    systemctl daemon-reload
    log "h-ui удалена"
}

# ---------- Удаление Mimic ----------
install_mimic() {
    log "Установка Mimic (eBPF UDP->TCP)..."

    log "Обновляем список пакетов..."
    DEBIAN_FRONTEND=noninteractive apt update -qq < /dev/null

    log "Устанавливаем mimic и mimic-dkms..."
    DEBIAN_FRONTEND=noninteractive apt install -y mimic mimic-dkms < /dev/null

    if ! command -v mimic &> /dev/null; then
        err "❌ Пакет mimic не найден в репозиториях"
        warn "Проверьте, что у вас Ubuntu 24.04+ или Debian 12+"
        return 1
    fi

    log "Загрузка модуля ядра mimic..."
    modprobe mimic 2>/dev/null || true
    echo "mimic" > /etc/modules-load.d/mimic.conf 2>/dev/null

    log "✅ Mimic установлен"
    mimic --version 2>/dev/null || true
}

enable_mimic() {
    if ! command -v mimic &> /dev/null; then
        err "Mimic не установлен. Сначала установите (пункт 1)."
        return 1
    fi
    if [ ! -f /etc/hysteria/config.yaml ]; then
        err "Конфиг /etc/hysteria/config.yaml не найден!"
        return 1
    fi
    if grep -q "^mimic:" /etc/hysteria/config.yaml; then
        warn "Mimic уже включён в конфиге"
        return 0
    fi
    log "Добавляем блок mimic в конфиг..."
    cp /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak
    printf "\nmimic:\n  enabled: true\n" >> /etc/hysteria/config.yaml
    log "Перезапуск Hysteria..."
    systemctl restart hysteria-server
    sleep 3
    if systemctl is-active --quiet hysteria-server; then
        log "✅ Mimic включён, Hysteria перезапущена"
    else
        err "❌ Hysteria не запустилась. Логи:"
        journalctl -u hysteria-server -n 15 --no-pager
    fi
}

disable_mimic() {
    if [ ! -f /etc/hysteria/config.yaml ]; then
        err "Конфиг не найден!"
        return 1
    fi
    if ! grep -q "^mimic:" /etc/hysteria/config.yaml; then
        warn "Mimic не включён в конфиге"
        return 0
    fi
    log "Отключаем Mimic в конфиге..."
    cp /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak
    sed -i '/^mimic:/,/^  enabled:/d' /etc/hysteria/config.yaml
    log "Перезапуск Hysteria..."
    systemctl restart hysteria-server
    sleep 3
    if systemctl is-active --quiet hysteria-server; then
        log "✅ Mimic отключён, Hysteria перезапущена"
    else
        err "❌ Hysteria не запустилась. Восстановите: cp /etc/hysteria/config.yaml.bak /etc/hysteria/config.yaml"
    fi
}

remove_mimic() {
    warn "Будет удалено: пакеты Mimic, модуль ядра, блок в конфиге"
    read -p "  Продолжить? (y/n): " A
    [ "$A" != "y" ] && return
    if [ -f /etc/hysteria/config.yaml ] && grep -q "^mimic:" /etc/hysteria/config.yaml; then
        sed -i '/^mimic:/,/^  enabled:/d' /etc/hysteria/config.yaml
        systemctl restart hysteria-server 2>/dev/null
    fi
    apt purge -y mimic mimic-dkms > /dev/null 2>&1 || true
    apt autoremove -y > /dev/null 2>&1 || true
    rmmod mimic 2>/dev/null || true
    rm -f /etc/modules-load.d/mimic.conf
    log "Mimic удалён"
}

# ---------- Удаление UFW ----------
remove_ufw() {
    warn "Будет отключён и удалён UFW"
    read -p "  Продолжить? (y/n): " A
    [ "$A" != "y" ] && return
    ufw --force disable 2>/dev/null || true
    apt purge -y ufw > /dev/null 2>&1 || true
    apt autoremove -y > /dev/null 2>&1 || true
    log "UFW удалён"
}

# ---------- Удаление Fail2Ban ----------
remove_fail2ban() {
    warn "Будет удалён Fail2Ban"
    read -p "  Продолжить? (y/n): " A
    [ "$A" != "y" ] && return
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    apt purge -y fail2ban > /dev/null 2>&1 || true
    rm -rf /etc/fail2ban
    apt autoremove -y > /dev/null 2>&1 || true
    log "Fail2Ban удалён"
}

# ---------- Удаление Certbot ----------
remove_certbot() {
    warn "Будет удалено: Certbot, сертификаты, cron автопродления"
    read -p "  Продолжить? (y/n): " A
    [ "$A" != "y" ] && return
    rm -f /etc/cron.d/certbot-renew
    rm -rf /etc/letsencrypt
    rm -f /etc/hysteria/cert.pem /etc/hysteria/key.pem
    apt purge -y certbot > /dev/null 2>&1 || true
    apt autoremove -y > /dev/null 2>&1 || true
    log "Certbot и сертификаты удалены"
}

# ============================================================
#  АВТОСЕТАП
# ============================================================
auto_setup() {
    warn "Автоматическая установка по шагам:"
    echo "  1) Установить Hysteria2"
    echo "  2) Освободить порт 53"
    echo "  3) Получить сертификат"
    echo "  4) Создать конфиг (с маскировкой 80/443)"
    echo "  5) Запустить Hysteria"
    echo "  6) Настроить автопродление"
    echo ""
    warn "UFW и Fail2Ban НЕ устанавливаются — настраивайте вручную (пункты 11, 12)"
    echo ""
    read -p "Продолжить? (y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return

    install_hysteria
    free_port_53
    get_cert || return
    create_config
    start_hysteria
    setup_renew
    show_key
}

# ============================================================
update_script() {
    log "Проверка обновлений с GitHub..."
    local URL="https://raw.githubusercontent.com/zotac85/hy-manager/main/hy-menu.sh"
    local TMP="/tmp/hy-menu-new.sh"
    if ! curl -fsSL "$URL" -o "$TMP"; then
        err "Не удалось скачать скрипт с GitHub"
        return 1
    fi
    if [ ! -s "$TMP" ]; then
        err "Скачанный файл пустой"
        return 1
    fi
    local OLD_HASH=$(md5sum /usr/local/bin/hy-menu.sh 2>/dev/null | awk '{print $1}')
    local NEW_HASH=$(md5sum "$TMP" | awk '{print $1}')
    if [ "$OLD_HASH" = "$NEW_HASH" ]; then
        log "У вас уже последняя версия"
        rm -f "$TMP"
        return 0
    fi
    log "Найдена новая версия. Обновляем..."
    cp /usr/local/bin/hy-menu.sh /usr/local/bin/hy-menu.sh.bak
    cp "$TMP" /usr/local/bin/hy-menu.sh
    chmod +x /usr/local/bin/hy-menu.sh
    ln -sf /usr/local/bin/hy-menu.sh /usr/local/bin/hys
    rm -f "$TMP"
    log "✅ Скрипт обновлён. Бэкап: /usr/local/bin/hy-menu.sh.bak"
    warn "Перезапустите меню: выйдите (0) и запустите hys снова"
}

show_version() {
    local V=""
    if command -v hysteria &>/dev/null; then
        V=$(hysteria version 2>/dev/null | grep -i "^Version:" | awk '{print $2}')
    fi
    [ -z "$V" ] && V="не установлена"
    echo -e "  Текущая версия: ${GREEN}$V${NC}"
}

hysteria_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 🔧 Hysteria2 ===${NC}"
        local st="❌ не работает"; systemctl is-active --quiet hysteria-server 2>/dev/null && st="✅ работает"
        echo -e "  Статус: $st"
        echo -e "  Порт 53: $(ss -ulpn 2>/dev/null | grep -q ':53 ' && echo '✅ занят' || echo '❌ свободен')"
        show_version
        echo ""
        echo "  1) Установить"
        echo "  2) Запустить"
        echo "  3) Перезапустить"
        echo "  4) Остановить"
        echo "  5) Логи (30 строк)"
        echo "  6) Обновить / сменить версию"
        echo "  7) Удалить"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) install_hysteria; pause ;;
            2) systemctl start hysteria-server && log "Запущена"; pause ;;
            3) systemctl restart hysteria-server && log "Перезапущена"; pause ;;
            4) systemctl stop hysteria-server && log "Остановлена"; pause ;;
            5) journalctl -u hysteria-server -n 30 --no-pager; pause ;;
            6) update_hysteria; pause ;;
            7) remove_hysteria; pause ;;
            0) return ;;
        esac
    done
}

hui_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 🎛️ Панель h-ui ===${NC}"
        local st="❌ не установлена"; systemctl is-active --quiet h-ui 2>/dev/null && st="✅ работает"
        echo -e "  Статус: $st"
        echo ""
        echo "  1) Установить"
        echo "  2) Запустить"
        echo "  3) Перезапустить"
        echo "  4) Остановить"
        echo "  5) Логи"
        echo "  6) Удалить"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) install_hui; pause ;;
            2) systemctl start h-ui 2>/dev/null && log "Запущена" || err "Не удалось"; pause ;;
            3) systemctl restart h-ui 2>/dev/null && log "Перезапущена" || err "Не удалось"; pause ;;
            4) systemctl stop h-ui 2>/dev/null && log "Остановлена" || err "Не удалось"; pause ;;
            5) journalctl -u h-ui -n 30 --no-pager 2>/dev/null || err "Сервис не найден"; pause ;;
            6) remove_hui; pause ;;
            0) return ;;
        esac
    done
}

mimic_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 🌐 Mimic (UDP→TCP) ===${NC}"
        local st="❌ не установлен"; command -v mimic &>/dev/null && st="✅ установлен"
        local cfg="❌ не включён"; grep -q "^mimic:" /etc/hysteria/config.yaml 2>/dev/null && cfg="✅ включён"
        echo -e "  Пакет: $st"
        echo -e "  Конфиг: $cfg"
        echo ""
        echo "  1) Установить"
        echo "  2) Включить в конфиге"
        echo "  3) Отключить в конфиге"
        echo "  4) Полностью удалить"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) install_mimic; pause ;;
            2) enable_mimic; pause ;;
            3) disable_mimic; pause ;;
            4) remove_mimic; pause ;;
            0) return ;;
        esac
    done
}

security_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 🛡️ Безопасность ===${NC}"
        local u="❌ выключен"; ufw status 2>/dev/null | grep -q "Status: active" && u="✅ активен"
        local f="❌ не работает"; systemctl is-active --quiet fail2ban 2>/dev/null && f="✅ работает"
        echo -e "  UFW: $u"
        echo -e "  Fail2Ban: $f"
        echo ""
        echo "  1) UFW: настроить"
        echo "  2) UFW: удалить"
        echo "  3) Fail2Ban: настроить"
        echo "  4) Fail2Ban: удалить"
        echo "  5) Показать статус UFW"
        echo "  6) Показать статус Fail2Ban"
        echo "  7) 🌐 Оптимизация сети (BBR + буферы)"
        echo "  8) 🔎 Показать сетевые настройки"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) setup_ufw; pause ;;
            2) remove_ufw; pause ;;
            3) setup_fail2ban; pause ;;
            4) remove_fail2ban; pause ;;
            5) ufw status verbose; pause ;;
            6) fail2ban-client status sshd 2>/dev/null || echo "Fail2Ban не запущен"; pause ;;
            7) optimize_network; pause ;;
            8) check_network; pause ;;
            0) return ;;
        esac
    done
}

cert_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 📜 Сертификаты ===${NC}"
        if [ -f /etc/hysteria/cert.pem ]; then
            echo -e "  $(openssl x509 -in /etc/hysteria/cert.pem -noout -subject 2>/dev/null | sed 's/^subject=//')"
            echo -e "  Истекает: $(openssl x509 -in /etc/hysteria/cert.pem -noout -enddate 2>/dev/null | cut -d= -f2)"
        else
            echo -e "  ❌ сертификат не установлен"
        fi
        echo ""
        echo "  1) Получить/обновить Let's Encrypt"
        echo "  2) Показать отпечаток SHA-256"
        echo "  3) Настроить автопродление"
        echo "  4) Удалить Certbot и сертификаты"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) get_cert; pause ;;
            2) show_fingerprint; pause ;;
            3) setup_renew; pause ;;
            4) remove_certbot; pause ;;
            0) return ;;
        esac
    done
}

params_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== ⚙️ Параметры ===${NC}"
        echo -e "  Домен: $DOMAIN"
        echo -e "  Порт:  $PORT"
        echo -e "  SNI:   $SNI"
        echo -e "  URL:   $MASQ_URL"
        echo ""
        echo "  1) Сменить SNI"
        echo "  2) Сменить URL маскировки"
        echo "  3) Сменить пароли (auth + obfs)"
        echo "  4) Сменить домен (новый сертификат)"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) change_sni; pause ;;
            2) change_masq_url; pause ;;
            3) change_passwords; pause ;;
            4) change_domain; pause ;;
            0) return ;;
        esac
    done
}

checks_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 🔍 Проверки и инфо ===${NC}"
        echo ""
        echo "  1) Проверить маскировку"
        echo "  2) Показать отпечаток сертификата"
        echo "  3) Показать ключ для Happ (полно)"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) check_masq; pause ;;
            2) show_fingerprint; pause ;;
            3) show_key; pause ;;
            0) return ;;
        esac
    done
}

backup_hysteria() {
    local DIR="/root/hysteria-backup"
    local FILE="/root/hysteria-backup.tar.gz"
    rm -rf "$DIR" "$FILE"
    mkdir -p "$DIR"
    log "Собираем данные..."

    # Конфиг и сертификаты Hysteria
    [ -f /etc/hysteria/config.yaml ] && cp /etc/hysteria/config.yaml "$DIR/"
    [ -f /etc/hysteria/cert.pem ] && cp /etc/hysteria/cert.pem "$DIR/"
    [ -f /etc/hysteria/key.pem ] && cp /etc/hysteria/key.pem "$DIR/"

    # Сервис systemd
    [ -f /etc/systemd/system/hysteria-server.service ] && \
        cp /etc/systemd/system/hysteria-server.service "$DIR/"

    # Let's Encrypt
    if [ -d /etc/letsencrypt ]; then
        mkdir -p "$DIR/letsencrypt"
        cp -r /etc/letsencrypt/* "$DIR/letsencrypt/" 2>/dev/null
    fi

    # h-ui (если установлена)
    if [ -d /h-ui/data ]; then
        mkdir -p "$DIR/h-ui-data"
        cp -r /h-ui/data/* "$DIR/h-ui-data/" 2>/dev/null
    fi
    if [ -d /usr/local/h-ui ]; then
        mkdir -p "$DIR/h-ui-bin"
        cp -r /usr/local/h-ui/* "$DIR/h-ui-bin/" 2>/dev/null
    fi

    # Скрипт меню
    [ -f /usr/local/bin/hy-menu.sh ] && cp /usr/local/bin/hy-menu.sh "$DIR/"

    # Метаданные
    {
        echo "Date: $(date)"
        echo "Hostname: $(hostname)"
        echo "IP: $(curl -4 -s --max-time 2 ifconfig.me 2>/dev/null || echo 'n/a')"
        echo "Domain: $DOMAIN"
        echo "Port: $PORT"
        echo "SNI: $SNI"
    } > "$DIR/meta.txt"

    tar czf "$FILE" -C /root hysteria-backup
    rm -rf "$DIR"

    if [ -f "$FILE" ]; then
        log "✅ Бэкап создан: $FILE"
        echo ""
        echo -e "${YELLOW}Содержимое:${NC}"
        tar tzf "$FILE" | head -20
        echo ""
        echo -e "${YELLOW}Размер:${NC} $(du -h "$FILE" | awk '{print $1}')"
        echo ""
        echo -e "${YELLOW}Скачать на компьютер:${NC}"
        echo "  scp root@$(curl -4 -s --max-time 2 ifconfig.me):$FILE ."
    else
        err "Не удалось создать бэкап"
    fi
}

restore_hysteria() {
    local FILE="/root/hysteria-backup.tar.gz"
    if [ ! -f "$FILE" ]; then
        err "Файл $FILE не найден!"
        echo ""
        echo "Сначала загрузите бэкап на сервер:"
        echo "  scp /путь/на/пк/hysteria-backup.tar.gz root@IP:/root/"
        return 1
    fi

    warn "Восстановление перезапишет текущий конфиг и сертификаты."
    read -p "  Продолжить? (y/n): " C
    [ "$C" != "y" ] && return

    local DIR="/root/hysteria-restore"
    rm -rf "$DIR"
    mkdir -p "$DIR"
    tar xzf "$FILE" -C "$DIR" 2>/dev/null

    # Определяем корень архива
    local SRC
    if [ -d "$DIR/hysteria-backup" ]; then
        SRC="$DIR/hysteria-backup"
    else
        SRC="$DIR"
    fi

    log "Восстанавливаем конфиг и сертификаты..."
    mkdir -p /etc/hysteria
    [ -f "$SRC/config.yaml" ] && cp "$SRC/config.yaml" /etc/hysteria/
    [ -f "$SRC/cert.pem" ] && cp "$SRC/cert.pem" /etc/hysteria/
    [ -f "$SRC/key.pem" ] && cp "$SRC/key.pem" /etc/hysteria/

    log "Восстанавливаем сервис systemd..."
    if [ -f "$SRC/hysteria-server.service" ]; then
        cp "$SRC/hysteria-server.service" /etc/systemd/system/
        systemctl daemon-reload
    fi

    log "Восстанавливаем Let's Encrypt..."
    if [ -d "$SRC/letsencrypt" ] && [ ! -d /etc/letsencrypt ]; then
        mkdir -p /etc/letsencrypt
        cp -r "$SRC/letsencrypt/"* /etc/letsencrypt/ 2>/dev/null
    fi

    log "Восстанавливаем h-ui (если есть)..."
    if [ -d "$SRC/h-ui-data" ]; then
        mkdir -p /h-ui/data
        cp -r "$SRC/h-ui-data/"* /h-ui/data/ 2>/dev/null
    fi
    if [ -d "$SRC/h-ui-bin" ]; then
        mkdir -p /usr/local/h-ui
        cp -r "$SRC/h-ui-bin/"* /usr/local/h-ui/ 2>/dev/null
        chmod +x /usr/local/h-ui/h-ui 2>/dev/null
    fi

    # Права на key.pem
    fix_perm

    log "Перезапускаем Hysteria..."
    systemctl restart hysteria-server 2>/dev/null
    sleep 3

    if systemctl is-active --quiet hysteria-server; then
        log "✅ Восстановление успешно!"
        rm -rf "$DIR"
    else
        err "Hysteria не запустилась. Логи:"
        journalctl -u hysteria-server -n 15 --no-pager
    fi
}


update_hysteria() {
    show_version
    echo ""
    echo "  1) Обновить до последней версии"
    echo "  2) Установить конкретную версию (из списка)"
    echo "  3) Проверить наличие обновления"
    echo "  0) Назад"
    read -p "  Выбор: " c
    case $c in
        1) update_hysteria_latest ;;
        2) update_hysteria_pick ;;
        3) check_hysteria_update ;;
        0) return ;;
        *) return ;;
    esac
}

update_hysteria_latest() {
    log "Установка последней версии Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) > /dev/null 2>&1
    if systemctl is-active --quiet hysteria-server; then
        systemctl restart hysteria-server
        sleep 2
    fi
    echo ""
    show_version
    systemctl is-active --quiet hysteria-server && log "✅ Hysteria работает" || err "Hysteria не запущена"
}

check_hysteria_update() {
    log "Проверяем последнюю версию на GitHub..."
    local LATEST=$(curl -sL --max-time 10 "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)
    LATEST="${LATEST#app/}"
    local CURRENT=""
    if command -v hysteria &>/dev/null; then
        CURRENT=$(hysteria version 2>/dev/null | grep -i "^Version:" | awk '{print $2}')
    fi
    echo ""
    echo -e "  Установлена: ${YELLOW}${CURRENT:-нет}${NC}"
    echo -e "  На GitHub:   ${GREEN}${LATEST:-не удалось узнать}${NC}"
    echo ""
    if [ -n "$LATEST" ] && [ "v$CURRENT" = "$LATEST" ]; then
        log "У вас последняя версия"
    elif [ -n "$LATEST" ]; then
        warn "Доступно обновление до $LATEST"
    fi
}

update_hysteria_pick() {
    log "Загружаем список версий с GitHub..."
    local VERSIONS=$(curl -sL --max-time 10 "https://api.github.com/repos/apernet/hysteria/releases?per_page=15" | grep -oP '"tag_name":\s*"\K[^"]+' | head -15)

    if [ -z "$VERSIONS" ]; then
        err "Не удалось получить список версий"
        return 1
    fi

    echo ""
    echo -e "${CYAN}Доступные версии:${NC}"
    local i=1
    for v in $VERSIONS; do
        echo "  $i) ${v#app/}"
        i=$((i+1))
    done
    echo "  0) Назад"
    echo ""
    read -p "  Выберите номер: " N

    [ "$N" = "0" ] && return
    [ -z "$N" ] && return

    local SELECTED=$(echo "$VERSIONS" | sed -n "${N}p")
    if [ -z "$SELECTED" ]; then
        err "Неверный номер"
        return 1
    fi

    warn "Будет установлена версия: $SELECTED"
    read -p "  Продолжить? (y/n): " C
    [ "$C" != "y" ] && return

    log "Скачиваем $SELECTED..."

    # Определяем архитектуру
    local ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) DEB_ARCH="amd64" ;;
        aarch64) DEB_ARCH="arm64" ;;
        *) err "Неподдерживаемая архитектура: $ARCH"; return 1 ;;
    esac

    local URL="https://github.com/apernet/hysteria/releases/download/app/${SELECTED}/hysteria-linux-${DEB_ARCH}"
    local TMP="/tmp/hysteria-new"

    if ! curl -fsSL "$URL" -o "$TMP"; then
        err "Не удалось скачать $SELECTED"
        return 1
    fi

    if [ ! -s "$TMP" ]; then
        err "Скачанный файл пустой"
        rm -f "$TMP"
        return 1
    fi

    # Бэкап текущего
    if [ -f /usr/local/bin/hysteria ]; then
        cp /usr/local/bin/hysteria /usr/local/bin/hysteria.bak
        log "Бэкап: /usr/local/bin/hysteria.bak"
    fi

    chmod +x "$TMP"
    mv "$TMP" /usr/local/bin/hysteria

    log "Перезапуск Hysteria..."
    systemctl restart hysteria-server
    sleep 3

    echo ""
    show_version
    systemctl is-active --quiet hysteria-server && log "✅ Hysteria работает" || err "Hysteria не запустилась"
}

#  МЕНЮ
change_domain() {
    echo ""
    echo -e "${YELLOW}Текущий домен:${NC} $DOMAIN"
    echo ""
    echo "  Шаги:"
    echo "   1. Новый домен должен указывать A-записью на IP: $(curl -4 -s --max-time 2 ifconfig.me)"
    echo "   2. Certbot выпустит новый сертификат"
    echo "   3. Hysteria перезапустится с новым доменом"
    echo "   4. Ключ для клиентов изменится (старый перестанет работать)"
    echo ""
    read -p "  Новый домен (Enter = отмена): " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && { warn "Отменено"; return; }
    [ "$NEW_DOMAIN" = "$DOMAIN" ] && { warn "Домен не изменился"; return; }

    # Проверяем DNS
    log "Проверяем A-запись $NEW_DOMAIN..."
    local RESOLVED=$(dig +short "$NEW_DOMAIN" 2>/dev/null | head -1)
    local MY_IP=$(curl -4 -s --max-time 2 ifconfig.me 2>/dev/null)
    echo "  Домен резолвится в: ${RESOLVED:-не найдено}"
    echo "  IP этого сервера:   $MY_IP"
    if [ "$RESOLVED" != "$MY_IP" ]; then
        warn "Домен НЕ указывает на этот сервер!"
        read -p "  Продолжить всё равно? (y/n): " C
        [ "$C" != "y" ] && return
    fi

    # Останавливаем Hysteria (освобождаем порт 80 для certbot)
    log "Останавливаем Hysteria..."
    systemctl stop hysteria-server 2>/dev/null || true
    sleep 2

    # Получаем сертификат
    log "Запрашиваем сертификат для $NEW_DOMAIN..."
    certbot certonly --standalone -d "$NEW_DOMAIN" \
        --non-interactive --agree-tos --register-unsafely-without-email

    if [ ! -f "/etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem" ]; then
        err "Не удалось получить сертификат для $NEW_DOMAIN"
        warn "Hysteria остаётся на старом домене: $DOMAIN"
        systemctl start hysteria-server 2>/dev/null
        return 1
    fi

    # Копируем сертификаты
    log "Копируем сертификаты..."
    cp "/etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem" /etc/hysteria/cert.pem
    cp "/etc/letsencrypt/live/$NEW_DOMAIN/privkey.pem" /etc/hysteria/key.pem
    fix_perm

    # Меняем переменную в скрипте
    log "Обновляем переменную DOMAIN в скрипте..."
    DOMAIN="$NEW_DOMAIN"
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$NEW_DOMAIN\"|" "$(readlink -f "$0")"

    # Перезапускаем Hysteria
    log "Запускаем Hysteria с новым доменом..."
    systemctl start hysteria-server
    sleep 3

    if systemctl is-active --quiet hysteria-server; then
        log "✅ Домен изменён на: $NEW_DOMAIN"
        echo ""
        echo -e "${YELLOW}Новый отпечаток сертификата:${NC}"
        local FP=$(get_fp)
        echo "  $FP"
        echo ""
        echo -e "${YELLOW}Новый ключ для Happ:${NC}"
        echo ""
        echo -e "${GREEN}$(key_compact)${NC}"
        echo ""
        warn "Раздайте новый ключ клиентам — старый больше не работает"
    else
        err "Hysteria не запустилась с новым доменом"
        journalctl -u hysteria-server -n 15 --no-pager
    fi
}

show_sysinfo() {
    local UP=$(uptime -p 2>/dev/null | sed 's/^up //')
    [ -z "$UP" ] && UP=$(uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')

    local LOAD=$(cat /proc/loadavg | awk '{print $1", "$2", "$3}')

    local CPU=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%.0f", 100-$1}')
    [ -z "$CPU" ] && CPU="?"

    local RAM_TOTAL=$(free -h | awk 'NR==2{print $2}')
    local RAM_USED_MB=$(free -h | awk 'NR==2{print $3}')
    local RAM_PCT=$(free -m | awk 'NR==2{printf "%.0f", $3*100/$2}')

    local DISK_USED=$(df -h / | awk 'NR==2{print $3}')
    local DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
    local DISK_PCT=$(df -h / | awk 'NR==2{print $5}')

    # Трафик с сетевого интерфейса
    local IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$IFACE" ] && IFACE="eth0"
    local RX_BYTES=$(cat /proc/net/dev | grep "$IFACE:" | awk '{print $2}')
    local TX_BYTES=$(cat /proc/net/dev | grep "$IFACE:" | awk '{print $10}')
    local RX=$(numfmt --to=iec --suffix=B "$RX_BYTES" 2>/dev/null || echo "$RX_BYTES B")
    local TX=$(numfmt --to=iec --suffix=B "$TX_BYTES" 2>/dev/null || echo "$TX_BYTES B")

    local HVER="не установлена"
    command -v hysteria &>/dev/null && HVER=$(hysteria version 2>/dev/null | grep -i "^Version:" | awk '{print $2}')

    local CONNS="?"
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        CONNS=$(ss -un 2>/dev/null | grep -c ":53" | tr -d '[:space:]')
    fi

    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}Uptime:${NC} $UP   ${YELLOW}Load:${NC} $LOAD"
    echo -e "  ${YELLOW}CPU:${NC} ${CPU}%  ${YELLOW}RAM:${NC} ${RAM_PCT}%  ${YELLOW}Disk:${NC} ${DISK_PCT}"
    echo -e "  ${YELLOW}Hysteria:${NC} $HVER  ${YELLOW}Conn:${NC} $CONNS  ${YELLOW}↓${NC} $RX  ${YELLOW}↑${NC} $TX"
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
}

key_compact() {
    local FP
    FP=$(openssl x509 -noout -fingerprint -sha256 -in /etc/hysteria/cert.pem 2>/dev/null | sed 's/^.*=//' | tr -d ':')
    if [ -n "$FP" ]; then
        echo "hysteria2://$AUTH_PASS@$DOMAIN:$PORT/?sni=$SNI&obfs=salamander&obfs-password=$OBFS_PASS&pinSHA256=$FP#Hysteria"
    else
        echo "hysteria2://$AUTH_PASS@$DOMAIN:$PORT/?sni=$SNI&obfs=salamander&obfs-password=$OBFS_PASS&insecure=1#Hysteria"
    fi
}

# ============================================================
optimize_network() {
    echo ""
    echo -e "${CYAN}=== Оптимизация сети ===${NC}"
    echo ""

    # Проверяем текущее состояние
    local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    echo -e "  Сейчас: congestion=${YELLOW}$cur_cc${NC}  qdisc=${YELLOW}$cur_qdisc${NC}"
    echo ""

    read -p "  Применить оптимизацию (BBR + буферы)? (y/n): " C
    [ "$C" != "y" ] && { warn "Отменено"; return; }

    # Бэкап текущих настроек
    local BACKUP="/root/net-optimize-backup-$(date +%Y%m%d-%H%M%S).conf"
    {
        echo "# Backup $(date)"
        echo "net.ipv4.tcp_congestion_control = $cur_cc"
        echo "net.core.default_qdisc = $cur_qdisc"
    } > "$BACKUP"
    log "Бэкап: $BACKUP"

    log "Создаём конфиг /etc/sysctl.d/99-hysteria-optimize.conf..."

    cat > /etc/sysctl.d/99-hysteria-optimize.conf << 'SYSCTL'
# ============================================================
# Hysteria2 Network Optimization
# BBR + увеличенные буферы
# ============================================================

# --- BBR + fq ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- UDP буферы (для QUIC/Hysteria) ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# --- TCP буферы ---
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- Очереди и бэклог ---
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535

# --- TCP оптимизация ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_mtu_probing = 1

# --- Файловые дескрипторы ---
fs.file-max = 1000000
SYSCTL

    log "Применяем настройки..."
    sysctl --system > /dev/null 2>&1

    # Проверяем результат
    sleep 1
    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    local new_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)

    echo ""
    echo -e "${CYAN}─── Результат ───${NC}"
    if [ "$new_cc" = "bbr" ]; then
        log "BBR: ${GREEN}включён${NC}"
    else
        err "BBR: ${RED}не включён${NC} (текущий: $new_cc)"
        warn "Возможно, ядро не поддерживает BBR. Проверьте: uname -r"
    fi
    if [ "$new_qdisc" = "fq" ]; then
        log "qdisc: ${GREEN}fq${NC}"
    else
        warn "qdisc: $new_qdisc (ожидался fq)"
    fi
    log "UDP rmem_max: ${GREEN}$new_rmem${NC}"

    echo ""
    echo -e "${YELLOW}Настройки сохранены в /etc/sysctl.d/99-hysteria-optimize.conf${NC}"
    echo -e "${YELLOW}Применятся автоматически при загрузке.${NC}"

    # Перезапускаем Hysteria (буферы применятся к новым сокетам)
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        echo ""
        read -p "  Перезапустить Hysteria сейчас? (y/n): " R
        if [ "$R" = "y" ]; then
            systemctl restart hysteria-server
            sleep 2
            systemctl is-active --quiet hysteria-server && log "✅ Hysteria перезапущена" || err "Hysteria не запустилась"
        fi
    fi
}

check_network() {
    echo ""
    echo -e "${CYAN}=== Текущие сетевые настройки ===${NC}"
    echo ""
    echo -e "  ${YELLOW}Congestion control:${NC} $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "  ${YELLOW}qdisc:${NC}              $(sysctl -n net.core.default_qdisc)"
    echo ""
    echo -e "  ${YELLOW}UDP буферы:${NC}"
    echo -e "    rmem_max: $(sysctl -n net.core.rmem_max)"
    echo -e "    wmem_max: $(sysctl -n net.core.wmem_max)"
    echo ""
    echo -e "  ${YELLOW}TCP буферы:${NC}"
    echo -e "    tcp_rmem: $(sysctl -n net.ipv4.tcp_rmem)"
    echo -e "    tcp_wmem: $(sysctl -n net.ipv4.tcp_wmem)"
    echo ""
    echo -e "  ${YELLOW}Fast Open:${NC} $(sysctl -n net.ipv4.tcp_fastopen)"
    echo -e "  ${YELLOW}File max:${NC}  $(sysctl -n fs.file-max)"
    echo ""
    # Проверка поддержки BBR
    if sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr; then
        log "BBR поддерживается ядром"
    else
        err "BBR НЕ поддерживается ядром"
    fi
}

generate_happ_json() {
    local CERT="/etc/hysteria/cert.pem"
    if [ ! -f "$CERT" ]; then
        echo "ERROR: cert not found" >&2
        return 1
    fi
    local FP
    FP=$(openssl x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null | sed 's/^.*=//' | tr -d ':')
    if [ -z "$FP" ]; then
        echo "ERROR: cannot read fingerprint" >&2
        return 1
    fi
    echo "hysteria2://$AUTH_PASS@$DOMAIN:$PORT/?sni=$SNI&obfs=salamander&obfs-password=$OBFS_PASS&pinSHA256=$FP#Hysteria"
    echo "happ://routing/add/$(generate_routing_link)"
}

GIST_ID_FILE="/root/.hysteria-gist-id"

gist_create_or_update() {
    local TOKEN=$(cat /root/.github-token 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        err "Токен не найден в /root/.github-token"
        return 1
    fi

    local CONTENT
    CONTENT=$(generate_happ_json)
    if [ -z "$CONTENT" ]; then
        err "Не удалось сгенерировать содержимое"
        return 1
    fi

    # Экранируем для JSON-запроса к API
    local ESCAPED
    ESCAPED=$(printf '%s' "$CONTENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    local GIST_ID=""
    [ -f "$GIST_ID_FILE" ] && GIST_ID=$(cat "$GIST_ID_FILE")

    if [ -z "$GIST_ID" ]; then
        log "Создаём новый Gist..."
        local RESPONSE=$(curl -s -X POST \
            -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            https://api.github.com/gists \
            -d "{\"description\":\"Hysteria2 subscription\",\"public\":false,\"files\":{\"hysteria.txt\":{\"content\":$ESCAPED}}}")

        GIST_ID=$(echo "$RESPONSE" | grep -oP '"id":\s*"\K[^"]+' | head -1)
        if [ -z "$GIST_ID" ]; then
            err "Не удалось создать Gist"
            echo "$RESPONSE" | head -10
            return 1
        fi
        echo "$GIST_ID" > "$GIST_ID_FILE"
        chmod 600 "$GIST_ID_FILE"
        log "✅ Gist создан"
    else
        log "Обновляем Gist..."
        local RESPONSE=$(curl -s -X PATCH \
            -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/gists/$GIST_ID" \
            -d "{\"files\":{\"hysteria.txt\":{\"content\":$ESCAPED}}}")

        if echo "$RESPONSE" | grep -q '"id"'; then
            log "✅ Gist обновлён"
        else
            err "Не удалось обновить Gist"
            echo "$RESPONSE" | head -10
            return 1
        fi
    fi

    echo ""
    echo -e "${CYAN}═══ URL для Happ ═══${NC}"
    echo ""
    echo -e "${GREEN}https://gist.githubusercontent.com/zotac85/$GIST_ID/raw/hysteria.txt${NC}"
    echo ""
    echo -e "${YELLOW}Добавьте этот URL в Happ как подписку.${NC}"
}

gist_show_url() {
    local GIST_ID=""
    [ -f "$GIST_ID_FILE" ] && GIST_ID=$(cat "$GIST_ID_FILE")

    if [ -z "$GIST_ID" ]; then
        warn "Gist ещё не создан. Выберите пункт 1."
        return 1
    fi

    echo ""
    echo -e "${CYAN}═══ URL подписки ═══${NC}"
    echo ""
    echo -e "${GREEN}https://gist.githubusercontent.com/zotac85/$GIST_ID/raw/hysteria.txt${NC}"
    echo ""
    echo -e "${YELLOW}Gist ID:${NC} $GIST_ID"
    echo -e "${YELLOW}HTML:${NC}    https://gist.github.com/zotac85/$GIST_ID"
}

gist_delete() {
    local TOKEN=$(cat /root/.github-token 2>/dev/null)
    local GIST_ID=""
    [ -f "$GIST_ID_FILE" ] && GIST_ID=$(cat "$GIST_ID_FILE")

    if [ -z "$GIST_ID" ]; then
        warn "Gist не создан"
        return 1
    fi

    warn "Удалить Gist $GIST_ID?"
    read -p "  Продолжить? (y/n): " C
    [ "$C" != "y" ] && return

    local CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: token $TOKEN" \
        "https://api.github.com/gists/$GIST_ID")

    if [ "$CODE" = "204" ]; then
        rm -f "$GIST_ID_FILE"
        log "✅ Gist удалён"
    else
        err "Ошибка удаления (HTTP $CODE)"
    fi
}

gist_menu() {
    while true; do
        clear
        echo -e "${CYAN}═══ 📱 Подписка для Happ ═══${NC}"
        echo ""
        local GIST_ID=""
        [ -f "$GIST_ID_FILE" ] && GIST_ID=$(cat "$GIST_ID_FILE")

        if [ -n "$GIST_ID" ]; then
            echo -e "  Статус:  ${GREEN}✅ создана${NC}"
            echo -e "  Gist ID: $GIST_ID"
            echo -e "  URL:     ${YELLOW}https://gist.githubusercontent.com/zotac85/$GIST_ID/raw/hysteria.txt${NC}"
        else
            echo -e "  Статус:  ${RED}❌ не создана${NC}"
        fi
        echo ""
        echo "  1) Создать / обновить подписку"
        echo "  2) Показать URL для Happ"
        echo "  3) Удалить подписку"
        echo "  4) Сгенерировать routing-ссылку для Happ"
        echo "  0) Назад"
        echo ""
        read -p "  Выбор: " c
        case $c in
            1) gist_create_or_update; pause ;;
            2) gist_show_url; pause ;;
            3) gist_delete; pause ;;
            4) show_routing_link; pause ;;
            0) return ;;
        esac
    done
}

generate_routing_link() {
    local TS=$(date +%s)
    local JSON
    JSON=$(cat << JSON_EOF
{"Name":"TM-Direct","GlobalProxy":"true","RouteOrder":"block-proxy-direct","RemoteDNSType":"DoH","RemoteDNSDomain":"https://cloudflare-dns.com/dns-query","RemoteDNSIP":"1.1.1.1","DomesticDNSType":"DoH","DomesticDNSDomain":"https://dns.google/dns-query","DomesticDNSIP":"8.8.8.8","Geoipurl":"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat","Geositeurl":"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat","LastUpdated":"$TS","DnsHosts":{"cloudflare-dns.com":"1.1.1.1","dns.google":"8.8.8.8"},"DirectSites":[],"DirectIp":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","224.0.0.0/4","255.255.255.255","geoip:tm"],"ProxySites":[],"ProxyIp":[],"BlockSites":[],"BlockIp":[],"DomainStrategy":"IPIfNonMatch","FakeDNS":"true","UseChunkFiles":"true"}
JSON_EOF
)
    echo -n "$JSON" | base64 -w 0
}

show_routing_link() {
    local B64
    B64=$(generate_routing_link)

    echo ""
    echo -e "${CYAN}═══ Routing-профиль для Happ ═══${NC}"
    echo ""
    echo -e "  ${YELLOW}Правила:${NC}"
    echo "    • geoip:tm → напрямую (Direct)"
    echo "    • Локальные сети (10/8, 172.16/12, 192.168/16) → Direct"
    echo "    • Всё остальное → через прокси"
    echo ""
    echo -e "${GREEN}Скопируйте ссылку ниже и откройте её в Happ:${NC}"
    echo ""
    echo "happ://routing/add/$B64"
    echo ""
    echo -e "${YELLOW}Или отправьте её себе в Telegram/заметки и откройте на телефоне.${NC}"
    echo -e "${YELLOW}Happ предложит добавить профиль маршрутизации.${NC}"
}

show_menu() {
    clear
    local H_ST="❌"; systemctl is-active --quiet hysteria-server 2>/dev/null && H_ST="✅"
    local U_ST="❌"; systemctl is-active --quiet h-ui 2>/dev/null && U_ST="✅"
    local M_ST="❌"; command -v mimic &>/dev/null && M_ST="✅"
    local UFW_ST="❌"; ufw status 2>/dev/null | grep -q "Status: active" && UFW_ST="✅"
    local F2B_ST="❌"; systemctl is-active --quiet fail2ban 2>/dev/null && F2B_ST="✅"
    local IP=$(curl -4 -s --max-time 2 ifconfig.me 2>/dev/null || echo "n/a")

    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           Hysteria2 Manager v4.0${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}IP:${NC} $IP   ${GREEN}Порт:${NC} $PORT   ${GREEN}SNI:${NC} $SNI"
    echo -e "  Hy:$H_ST  h-ui:$U_ST  Mimic:$M_ST  UFW:$UFW_ST  F2B:$F2B_ST"
    show_sysinfo
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} 🚀 Полный автосетап"
    echo -e "  ${GREEN}2)${NC} 🔧 Hysteria2"
    echo -e "  ${GREEN}3)${NC} 🎛️  Панель h-ui"
    echo -e "  ${GREEN}4)${NC} 🌐 Mimic (UDP→TCP)"
    echo -e "  ${GREEN}5)${NC} 🛡️  Безопасность и сеть"
    echo -e "  ${GREEN}6)${NC} 📜 Сертификаты"
    echo -e "  ${GREEN}7)${NC} ⚙️  Параметры (SNI, URL, пароли)"
    echo -e "  ${GREEN}8)${NC} 🔍 Проверки и инфо"
    echo -e "  ${GREEN}9)${NC} 📝 Редактировать конфиг (nano)"
    echo -e "  ${GREEN}10)${NC} 💾 Бэкап (конфиг + сертификаты)"
    echo -e "  ${GREEN}11)${NC} ♻️  Восстановить из бэкапа"
    echo -e "  ${GREEN}14)${NC} 📱 Подписка для Happ (Gist)"
    echo -e "  ${GREEN}28)${NC} 🔄 Обновить скрипт из GitHub"
    echo ""
    echo -e "  ${RED}0)${NC}  Выход"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🔑 КЛЮЧ ДЛЯ HAPP:${NC}"
    echo ""
    echo -e "${YELLOW}$(key_compact)${NC}"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    read -p "  Выберите пункт: " choice

    case $choice in
        1)  auto_setup; pause ;;
        2)  hysteria_menu ;;
        3)  hui_menu ;;
        4)  mimic_menu ;;
        5)  security_menu ;;
        6)  cert_menu ;;
        7)  params_menu ;;
        8)  checks_menu ;;
        9)  edit_config; pause ;;
        10) backup_hysteria; pause ;;
        11) restore_hysteria; pause ;;
        14) gist_menu ;;
        28) update_script; pause ;;
        0)  exit 0 ;;
        *)  echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
}

# ---------- Запуск ----------
if [ "$EUID" -ne 0 ]; then
    err "Запустите от root!"
    exit 1
fi

chmod +x "$(readlink -f "$0")"
ln -sf "$(readlink -f "$0")" /usr/local/bin/hys

while true; do
    show_menu
done
