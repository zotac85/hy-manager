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
        chown -R hysteria:hysteria /etc/hysteria/
    fi
    log "Сертификат установлен (домен: $NEW_DOMAIN)"

    DOMAIN="$NEW_DOMAIN"
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$NEW_DOMAIN\"|" /root/hy-menu.sh
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
        chown -R hysteria:hysteria /etc/hysteria/
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

# ============================================================
#  УПРАВЛЕНИЕ
# ============================================================

start_hysteria() {
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
    log "Настройка UFW..."
    apt install -y ufw > /dev/null 2>&1
    local SSH_PORT
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    ufw --force enable > /dev/null 2>&1
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw allow "$SSH_PORT"/tcp comment 'SSH' > /dev/null 2>&1
    ufw allow "$PORT"/udp comment 'Hysteria2' > /dev/null 2>&1
    ufw allow 80/tcp comment 'Masquerade HTTP' > /dev/null 2>&1
    ufw allow 443/tcp comment 'Masquerade HTTPS' > /dev/null 2>&1
    ufw allow "$HUI_PORT"/tcp comment 'h-ui Panel' > /dev/null 2>&1
    ufw reload > /dev/null 2>&1

    log "UFW настроен:"
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
    sed -i "s|^SNI=.*|SNI=\"$NEW_SNI\"|" /root/hy-menu.sh
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
    sed -i "s|^MASQ_URL=.*|MASQ_URL=\"$NEW_URL\"|" /root/hy-menu.sh

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
        sed -i "s|^AUTH_PASS=.*|AUTH_PASS=\"$NEW_AUTH\"|" /root/hy-menu.sh
    fi

    echo -n "Новый пароль obfs (Enter = оставить текущий): "
    read NEW_OBFS
    if [ -n "$NEW_OBFS" ]; then
        OBFS_PASS="$NEW_OBFS"
        sed -i "s|^OBFS_PASS=.*|OBFS_PASS=\"$NEW_OBFS\"|" /root/hy-menu.sh
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
#  МЕНЮ
# ============================================================
show_menu() {
    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}           Hysteria2 Manager v3.0${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "${GREEN}🚀 БЫСТРЫЙ СТАРТ${NC}"
    echo -e "  1) Полный автосетап (без UFW/Fail2Ban)"
    echo ""
    echo -e "${YELLOW}⚙️  УСТАНОВКА${NC}"
    echo -e "  2) Установить Hysteria2"
    echo -e "  3) Освободить порт 53"
    echo -e "  4) Получить/обновить сертификат"
    echo -e "  5) Создать конфиг"
    echo -e "  6) Установить панель h-ui (systemd, без Docker)"
    echo ""
    echo -e "${MAGENTA}🔧 УПРАВЛЕНИЕ${NC}"
    echo -e "  7) Запустить Hysteria"
    echo -e "  8) Перезапустить Hysteria"
    echo -e "  9) Остановить Hysteria"
    echo -e " 10) Статус"
    echo -e " 11) Логи (30 строк)"
    echo ""
    echo -e "${CYAN}🛡️  БЕЗОПАСНОСТЬ${NC}"
    echo -e " 12) Настроить UFW"
    echo -e " 13) Установить и настроить Fail2Ban"
    echo -e " 14) Настроить автопродление сертификата"
    echo ""
    echo -e "${GREEN}⚡ ИЗМЕНЕНИЕ ПАРАМЕТРОВ${NC}"
    echo -e " 15) Сменить SNI"
    echo -e " 16) Сменить URL маскировки"
    echo -e " 17) Сменить пароли (auth + obfs)"
    echo ""
    echo -e "${YELLOW}🔍 ПРОВЕРКИ И ИНФО${NC}"
    echo -e " 18) Проверить маскировку"
    echo -e " 19) Показать отпечаток сертификата"
    echo -e " 20) Показать ключ для Happ"
    echo ""
    echo -e "${MAGENTA}📝 РЕДАКТИРОВАНИЕ${NC}"
    echo -e " 21) Редактировать конфиг вручную (nano)"
    echo ""
    echo -e "${RED} 0) Выход${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo "  Домен: $DOMAIN"
    echo "  Порт:  $PORT"
    echo "  SNI:   $SNI"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "${GREEN}🔑 ГОТОВЫЙ КЛЮЧ ДЛЯ HAPP:${NC}"
    echo ""
    echo -e "${YELLOW}$(show_key_compact)${NC}"
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    read -p "Выберите пункт: " choice

    case $choice in
        1)  auto_setup; pause ;;
        2)  install_hysteria; pause ;;
        3)  free_port_53; pause ;;
        4)  get_cert; pause ;;
        5)  create_config; pause ;;
        6)  install_hui; pause ;;
        7)  start_hysteria; pause ;;
        8)  restart_hysteria; pause ;;
        9)  stop_hysteria; pause ;;
        10) show_status; pause ;;
        11) show_logs; pause ;;
        12) setup_ufw; pause ;;
        13) setup_fail2ban; pause ;;
        14) setup_renew; pause ;;
        15) change_sni; pause ;;
        16) change_masq_url; pause ;;
        17) change_passwords; pause ;;
        18) check_masq; pause ;;
        19) show_fingerprint; pause ;;
        20) show_key; pause ;;
        21) edit_config; pause ;;
        0)  exit 0 ;;
        *)  echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
}

# ---------- Запуск ----------
if [ "$EUID" -ne 0 ]; then
    err "Запустите от root!"
    exit 1
fi

chmod +x /root/hy-menu.sh
ln -sf /root/hy-menu.sh /usr/local/bin/hys

while true; do
    show_menu
done
