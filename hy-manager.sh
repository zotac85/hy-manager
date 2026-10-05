#!/bin/bash
# ============================================================
#  Hysteria2 Manager for h-ui (v3.0)
# ============================================================

CONFIG_FILE="/h-ui/bin/hysteria2.yaml"
ECH_KEY="/h-ui/bin/ech.pem"
HYSTERIA_PROC="hysteria-linux"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

pause() { echo ""; read -p "Нажмите Enter для продолжения..." _; }

# ---------- 1. Обновить Hysteria ----------
install_hysteria() {
    echo -e "${CYAN}>>> Установка/обновление Hysteria2...${NC}"
    bash <(curl -fsSL https://get.hy2.sh/)
    echo -e "${GREEN}Готово!${NC}"
}

# ---------- 2. Редактировать конфиг ----------
edit_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Файл $CONFIG_FILE не найден!${NC}"; return
    fi
    echo -e "${CYAN}>>> Текущий конфиг:${NC}"
    cat -n "$CONFIG_FILE"
    echo ""
    read -p "Редактировать вручную? (y/n): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        nano "$CONFIG_FILE"
        echo -e "${YELLOW}Не забудьте перезапустить Hysteria (пункт 3).${NC}"
    fi
}

# ---------- 3. Перезапуск ----------
restart_hysteria() {
    echo -e "${CYAN}>>> Перезапуск Hysteria...${NC}"
    pkill -f "$HYSTERIA_PROC"
    sleep 3
    if pgrep -f "$HYSTERIA_PROC" > /dev/null; then
        echo -e "${GREEN}Hysteria успешно перезапущена (h-ui поднял процесс).${NC}"
    else
        echo -e "${RED}Процесс не запустился. Перезапустите панель h-ui вручную.${NC}"
    fi
}

# ---------- 4. Статус ----------
status_hysteria() {
    echo -e "${CYAN}>>> Статус Hysteria:${NC}"
    if pgrep -f "$HYSTERIA_PROC" > /dev/null; then
        echo -e "${GREEN}Работает${NC}"
        ps aux | grep "$HYSTERIA_PROC" | grep -v grep
    else
        echo -e "${RED}Не работает${NC}"
    fi
    echo ""
    echo -e "${CYAN}>>> Порт 53:${NC}"
    ss -tulpn | grep :53
}

# ---------- 5. Логи ----------
logs_hysteria() {
    echo -e "${CYAN}>>> Последние 50 строк логов:${NC}"
    journalctl -u h-ui -n 50 --no-pager 2>/dev/null || \
    tail -50 /h-ui/logs/*.log 2>/dev/null || \
    echo -e "${YELLOW}Логи не найдены. Проверьте /h-ui/logs/.${NC}"
}

# ---------- 6. Оптимизация сети ----------
optimize_sysctl() {
    echo -e "${CYAN}>>> Оптимизация сетевых параметров...${NC}"
    cat > /etc/sysctl.d/99-hysteria-optimize.conf << 'SYSCTL'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1000000
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
SYSCTL
    sysctl --system > /dev/null 2>&1
    echo -e "${GREEN}Сетевые параметры оптимизированы.${NC}"
}

# ---------- 7. UFW ----------
setup_ufw() {
    echo -e "${CYAN}>>> Настройка UFW...${NC}"
    apt install -y ufw > /dev/null 2>&1
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    echo -e "${YELLOW}SSH порт: $SSH_PORT${NC}"
    ufw allow "$SSH_PORT"/tcp comment 'SSH' > /dev/null 2>&1
    ufw allow 53/udp comment 'Hysteria2' > /dev/null 2>&1
    ufw allow 6177/tcp comment 'Hysteria2' > /dev/null 2>&1
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    echo -e "${GREEN}UFW настроен:${NC}"
    ufw status verbose
}

# ---------- 8. Fail2Ban ----------
setup_fail2ban() {
    echo -e "${CYAN}>>> Настройка Fail2Ban...${NC}"
    apt install -y fail2ban > /dev/null 2>&1
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
    echo -e "${GREEN}Fail2Ban настроен.${NC}"
    sleep 2
    fail2ban-client status sshd 2>/dev/null || echo -e "${YELLOW}Проверьте позже: fail2ban-client status sshd${NC}"
}

# ---------- 9. ECH ----------
generate_ech() {
    echo -e "${CYAN}>>> Генерация ECH ключей...${NC}"
    if ! command -v hysteria &> /dev/null; then
        echo -e "${RED}Hysteria не установлен!${NC}"; return
    fi
    echo -e "${YELLOW}Введите домен для маскировки (Enter = www.icloud.com):${NC}"
    read -r public_name
    [ -z "$public_name" ] && public_name="www.icloud.com"
    hysteria ech --public-name "$public_name" > "$ECH_KEY" 2>&1
    if [ ! -s "$ECH_KEY" ]; then
        echo -e "${RED}Ошибка генерации ECH.${NC}"; return
    fi
    echo -e "${GREEN}ECH ключи сохранены: $ECH_KEY${NC}"
    echo ""
    if ! grep -q "^ech:" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "/^tls:/i ech:\n  keyFile: $ECH_KEY" "$CONFIG_FILE"
        echo -e "${GREEN}Секция ech добавлена в конфиг.${NC}"
    else
        echo -e "${YELLOW}Секция ech уже есть в конфиге.${NC}"
    fi
    echo -e "${YELLOW}Не забудьте перезапустить Hysteria (пункт 3).${NC}"
    echo ""
    echo -e "${MAGENTA}=== ECH CONFIG ДЛЯ КЛИЕНТА ===${NC}"
    cat "$ECH_KEY"
    echo ""
    echo -e "${MAGENTA}==============================${NC}"
}

# ---------- 10. Приоритет ----------
optimize_priority() {
    echo -e "${CYAN}>>> Оптимизация приоритета...${NC}"
    PID=$(pgrep -f "$HYSTERIA_PROC" | head -1)
    if [ -z "$PID" ]; then
        echo -e "${RED}Hysteria не запущена.${NC}"; return
    fi
    renice -n -20 -p "$PID" > /dev/null 2>&1
    ionice -c 1 -n 0 -p "$PID" > /dev/null 2>&1
    echo -e "${GREEN}Приоритет процесса $PID повышен.${NC}"
}

# ---------- 11. Показать ECH ----------
show_ech() {
    if [ ! -f "$ECH_KEY" ]; then
        echo -e "${RED}Файл $ECH_KEY не найден.${NC}"; return
    fi
    echo -e "${MAGENTA}=== ECH CONFIG ДЛЯ КЛИЕНТА ===${NC}"
    cat "$ECH_KEY"
    echo ""
    echo -e "${MAGENTA}==============================${NC}"
}

# ---------- 12. Бэкап ----------
backup_config() {
    BACKUP_DIR="/root/hysteria-backups"
    mkdir -p "$BACKUP_DIR"
    STAMP=$(date +%Y%m%d-%H%M%S)
    cp "$CONFIG_FILE" "$BACKUP_DIR/hysteria2-$STAMP.yaml" 2>/dev/null
    [ -f "$ECH_KEY" ] && cp "$ECH_KEY" "$BACKUP_DIR/ech-$STAMP.pem"
    [ -f "/h-ui/bin/certs/domain.crt" ] && cp "/h-ui/bin/certs/domain.crt" "$BACKUP_DIR/domain-$STAMP.crt"
    [ -f "/h-ui/bin/certs/domain.key" ] && cp "/h-ui/bin/certs/domain.key" "$BACKUP_DIR/domain-$STAMP.key"
    echo -e "${GREEN}Бэкап сохранён в $BACKUP_DIR${NC}"
    ls -lh "$BACKUP_DIR" | tail -6
}

# ---------- 13. Проверить маскировку ----------
check_masquerade() {
    echo -e "${CYAN}>>> Проверка маскировки...${NC}"
    DOMAIN=$(openssl x509 -in /h-ui/bin/certs/domain.crt -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
    if [ -z "$DOMAIN" ]; then
        echo -e "${YELLOW}Не удалось определить домен из сертификата.${NC}"
        return
    fi
    echo -e "${YELLOW}Домен: $DOMAIN${NC}"
    echo -e "${CYAN}Отправляем запрос на localhost:443 с правильным SNI...${NC}"
    curl -sk --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" | head -20
    echo ""
    echo -e "${CYAN}Если вы видите HTML iCloud — маскировка работает.${NC}"
}

# ---------- 14. Освободить порт 53 ----------
free_port_53() {
    echo -e "${CYAN}>>> Проверка порта 53...${NC}"
    OWNER=$(ss -tulpn | grep ':53 ' | grep -v 'hysteria' | head -1)
    if [ -z "$OWNER" ]; then
        echo -e "${GREEN}Порт 53 свободен или занят Hysteria. Всё в порядке.${NC}"
        return
    fi
    echo -e "${YELLOW}Порт занят: $OWNER${NC}"
    read -p "Остановить systemd-resolved и dnsmasq? (y/n): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        systemctl stop systemd-resolved 2>/dev/null
        systemctl disable systemd-resolved 2>/dev/null
        systemctl stop dnsmasq 2>/dev/null
        systemctl disable dnsmasq 2>/dev/null
        echo -e "${GREEN}Сервисы остановлены.${NC}"
        echo -e "${CYAN}Перезапускаем Hysteria...${NC}"
        restart_hysteria
    fi
}

# ---------- 15. Установить сертификат Let's Encrypt ----------
install_cert_letsencrypt() {
    echo -e "${CYAN}>>> Установка сертификата Let's Encrypt...${NC}"
    if ! command -v certbot &> /dev/null; then
        echo -e "${YELLOW}Установка certbot...${NC}"
        apt install -y certbot > /dev/null 2>&1
    fi
    echo -e "${YELLOW}Введите домен (например, example.com):${NC}"
    read -r DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Домен не указан.${NC}"; return
    fi
    echo -e "${YELLOW}Останавливаем Hysteria (освобождаем порт 80)...${NC}"
    pkill -f "$HYSTERIA_PROC"
    sleep 2
    echo -e "${CYAN}Получаем сертификат...${NC}"
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo -e "${RED}Не удалось получить сертификат.${NC}"
        echo -e "${YELLOW}Проверьте, что домен указывает на этот IP и порт 80 открыт.${NC}"
        return
    fi
    mkdir -p /h-ui/bin/certs
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /h-ui/bin/certs/domain.crt
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" /h-ui/bin/certs/domain.key
    chmod 644 /h-ui/bin/certs/domain.crt
    chmod 600 /h-ui/bin/certs/domain.key
    echo -e "${GREEN}Сертификат установлен в /h-ui/bin/certs/${NC}"
    echo -e "${CYAN}Настраиваем автопродление (cron)...${NC}"
    cat > /etc/cron.d/certbot-renew << 'CRON'
0 3 * * * root certbot renew --quiet --deploy-hook "cp $RENEWED_LINEAGE/fullchain.pem /h-ui/bin/certs/domain.crt && cp $RENEWED_LINEAGE/privkey.pem /h-ui/bin/certs/domain.key && pkill -f hysteria-linux"
CRON
    echo -e "${GREEN}Автопродление настроено (проверка ежедневно в 3:00).${NC}"
    echo -e "${YELLOW}Hysteria перезапустится сама через панель h-ui.${NC}"
}

# ---------- 16. Создать самоподписанный сертификат ----------
install_cert_selfsigned() {
    echo -e "${CYAN}>>> Создание самоподписанного сертификата...${NC}"
    echo -e "${YELLOW}Введите домен (CN сертификата):${NC}"
    read -r DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="www.icloud.com"
    mkdir -p /h-ui/bin/certs
    echo -e "${CYAN}Генерация ключа и сертификата...${NC}"
    openssl ecparam -genkey -name prime256v1 -out /h-ui/bin/certs/domain.key
    openssl req -new -x509 -days 3650 -key /h-ui/bin/certs/domain.key -out /h-ui/bin/certs/domain.crt -subj "/CN=$DOMAIN"
    chmod 644 /h-ui/bin/certs/domain.crt
    chmod 600 /h-ui/bin/certs/domain.key
    echo -e "${GREEN}Сертификат создан на 10 лет (CN=$DOMAIN).${NC}"
    echo -e "${CYAN}Отпечаток для клиента:${NC}"
    openssl x509 -in /h-ui/bin/certs/domain.crt -noout -fingerprint -sha256 | sed "s/://g"
    echo -e "${YELLOW}Hysteria перезапустится сама через панель h-ui.${NC}"
}

# ---------- 17. Проверить сертификат ----------
check_cert() {
    echo -e "${CYAN}>>> Информация о сертификате${NC}"
    if [ ! -f /h-ui/bin/certs/domain.crt ]; then
        echo -e "${RED}Сертификат /h-ui/bin/certs/domain.crt не найден!${NC}"; return
    fi
    echo ""
    echo -e "${YELLOW}=== Subject / Issuer ===${NC}"
    openssl x509 -in /h-ui/bin/certs/domain.crt -noout -subject -issuer
    echo ""
    echo -e "${YELLOW}=== Срок действия ===${NC}"
    openssl x509 -in /h-ui/bin/certs/domain.crt -noout -dates
    echo ""
    echo -e "${YELLOW}=== Отпечаток SHA-256 (pinSHA256 для клиента) ===${NC}"
    openssl x509 -in /h-ui/bin/certs/domain.crt -noout -fingerprint -sha256 | sed "s/://g"
    echo ""
    echo -e "${YELLOW}=== Проверка соответствия ключа ===${NC}"
    CRT_HASH=$(openssl x509 -in /h-ui/bin/certs/domain.crt -noout -pubkey | openssl sha256)
    KEY_HASH=$(openssl ec -in /h-ui/bin/certs/domain.key -pubout 2>/dev/null | openssl sha256)
    if [ "$CRT_HASH" = "$KEY_HASH" ]; then
        echo -e "${GREEN}Сертификат и ключ совпадают.${NC}"
    else
        echo -e "${RED}Сертификат и ключ НЕ совпадают!${NC}"
    fi
    echo ""
    DAYS_LEFT=$(( ($(date -d "$(openssl x509 -in /h-ui/bin/certs/domain.crt -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    echo -e "${CYAN}=== Полные пути для панели h-ui ===${NC}"
    echo -e "${YELLOW}Поле cert:${NC} /h-ui/bin/certs/domain.crt"
    echo -e "${YELLOW}Поле key:${NC}  /h-ui/bin/certs/domain.key"
    echo ""
    echo -e "${YELLOW}Осталось дней: $DAYS_LEFT${NC}"
    if [ "$DAYS_LEFT" -lt 30 ]; then
        echo -e "${RED}Сертификат скоро истечёт! Обновите его.${NC}"
    fi
}

# ---------- МЕНЮ ----------
show_menu() {
    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}        Hysteria2 Manager for h-ui (v3.0)${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN} 1) Обновить Hysteria2${NC}"
    echo -e "${GREEN} 2) Редактировать конфиг (/h-ui/bin/hysteria2.yaml)${NC}"
    echo -e "${GREEN} 3) Перезапустить Hysteria${NC}"
    echo -e "${GREEN} 4) Статус Hysteria${NC}"
    echo -e "${GREEN} 5) Логи Hysteria${NC}"
    echo ""
    echo -e "${YELLOW} 6) Оптимизация сети (sysctl + BBR)${NC}"
    echo -e "${YELLOW} 7) Настроить UFW${NC}"
    echo -e "${YELLOW} 8) Настроить Fail2Ban${NC}"
    echo -e "${YELLOW} 9) Генерировать ECH ключи${NC}"
    echo -e "${YELLOW}10) Оптимизация приоритета${NC}"
    echo ""
    echo -e "${MAGENTA}11) Показать ECH config${NC}"
    echo -e "${MAGENTA}12) Бэкап конфигов${NC}"
    echo -e "${MAGENTA}13) Проверить маскировку${NC}"
    echo -e "${MAGENTA}14) Освободить порт 53${NC}"
echo -e "${CYAN}--- Сертификаты ---${NC}"
echo -e "${GREEN}15) Установить сертификат Let's Encrypt${NC}"
echo -e "${GREEN}16) Создать самоподписанный сертификат${NC}"
echo -e "${GREEN}17) Проверить сертификат${NC}"
    echo ""
    echo -e "${RED} 0) Выход${NC}"
    echo -e "${CYAN}============================================================${NC}"
    read -p "Выберите пункт: " choice

    case $choice in
        1)  install_hysteria; pause ;;
        2)  edit_config; pause ;;
        3)  restart_hysteria; pause ;;
        4)  status_hysteria; pause ;;
        5)  logs_hysteria; pause ;;
        6)  optimize_sysctl; pause ;;
        7)  setup_ufw; pause ;;
        8)  setup_fail2ban; pause ;;
        9)  generate_ech; pause ;;
        10) optimize_priority; pause ;;
        11) show_ech; pause ;;
        12) backup_config; pause ;;
        13) check_masquerade; pause ;;
        14) free_port_53; pause ;;
        15) install_cert_letsencrypt; pause ;;
        16) install_cert_selfsigned; pause ;;
        17) check_cert; pause ;;
        0)  exit 0 ;;
        *)  echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
    esac
}

while true; do
    show_menu
done
