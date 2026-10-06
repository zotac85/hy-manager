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

hysteria_menu() {
    while true; do
        clear
        echo -e "${CYAN}=== 🔧 Hysteria2 ===${NC}"
        local st="❌ не работает"; systemctl is-active --quiet hysteria-server 2>/dev/null && st="✅ работает"
        echo -e "  Статус: $st"
        echo -e "  Порт 53: $(ss -ulpn 2>/dev/null | grep -q ':53 ' && echo '✅ занят' || echo '❌ свободен')"
        echo ""
        echo "  1) Установить"
        echo "  2) Запустить"
        echo "  3) Перезапустить"
        echo "  4) Остановить"
        echo "  5) Логи (30 строк)"
        echo "  6) Удалить"
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) install_hysteria; pause ;;
            2) systemctl start hysteria-server && log "Запущена"; pause ;;
            3) systemctl restart hysteria-server && log "Перезапущена"; pause ;;
            4) systemctl stop hysteria-server && log "Остановлена"; pause ;;
            5) journalctl -u hysteria-server -n 30 --no-pager; pause ;;
            6) remove_hysteria; pause ;;
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
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) setup_ufw; pause ;;
            2) remove_ufw; pause ;;
            3) setup_fail2ban; pause ;;
            4) remove_fail2ban; pause ;;
            5) ufw status verbose; pause ;;
            6) fail2ban-client status sshd 2>/dev/null || echo "Fail2Ban не запущен"; pause ;;
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
        echo "  0) Назад"
        read -p "  Выбор: " c
        case $c in
            1) change_sni; pause ;;
            2) change_masq_url; pause ;;
            3) change_passwords; pause ;;
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

#  МЕНЮ
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
    echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} 🚀 Полный автосетап"
    echo -e "  ${GREEN}2)${NC} 🔧 Hysteria2"
    echo -e "  ${GREEN}3)${NC} 🎛️  Панель h-ui"
    echo -e "  ${GREEN}4)${NC} 🌐 Mimic (UDP→TCP)"
    echo -e "  ${GREEN}5)${NC} 🛡️  Безопасность (UFW, Fail2Ban)"
    echo -e "  ${GREEN}6)${NC} 📜 Сертификаты"
    echo -e "  ${GREEN}7)${NC} ⚙️  Параметры (SNI, URL, пароли)"
    echo -e "  ${GREEN}8)${NC} 🔍 Проверки и инфо"
    echo -e "  ${GREEN}9)${NC} 📝 Редактировать конфиг (nano)"
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
