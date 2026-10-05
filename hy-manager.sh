#!/bin/bash
# ============================================================
#  Hysteria2 Server Manager v2.0
# ============================================================

HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
HYSTERIA_SERVICE="hysteria-server"
HYSTERIA_BIN="/usr/local/bin/hysteria"
ECH_KEY="/etc/hysteria/ech.pem"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

pause() { echo ""; read -p "Нажмите Enter для продолжения..." _; }

# ---------- 1. Установка ----------
install_hysteria() {
    echo -e "${CYAN}>>> Установка / обновление Hysteria2...${NC}"
    bash <(curl -fsSL https://get.hy2.sh/)
    echo -e "${GREEN}Готово!${NC}"
}

# ---------- 2. Конфиг ----------
configure_hysteria() {
    if [ ! -f "$HYSTERIA_CONFIG" ]; then
        echo -e "${RED}Файл $HYSTERIA_CONFIG не найден!${NC}"; return
    fi
    echo -e "${CYAN}>>> Текущий конфиг:${NC}"
    cat -n "$HYSTERIA_CONFIG"
    echo ""
    read -p "Редактировать вручную? (y/n): " ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        nano "$HYSTERIA_CONFIG"
        systemctl restart "$HYSTERIA_SERVICE"
        echo -e "${GREEN}Сохранено и перезапущено.${NC}"
    fi
}

# ---------- 3. Перезапуск ----------
restart_hysteria() {
    echo -e "${CYAN}>>> Перезапуск Hysteria2...${NC}"
    systemctl restart "$HYSTERIA_SERVICE"
    sleep 2
    systemctl status "$HYSTERIA_SERVICE" --no-pager -l | head -15
}

# ---------- 4. Статус ----------
status_hysteria() {
    systemctl status "$HYSTERIA_SERVICE" --no-pager -l
}

# ---------- 5. Логи ----------
logs_hysteria() {
    echo -e "${CYAN}>>> Последние 50 строк логов:${NC}"
    journalctl -u "$HYSTERIA_SERVICE" -n 50 --no-pager
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
    echo -e "${YELLOW}Обнаружен SSH порт: $SSH_PORT${NC}"

    ufw allow "$SSH_PORT"/tcp comment 'SSH' > /dev/null 2>&1
    ufw allow 53/udp comment 'Hysteria2 UDP' > /dev/null 2>&1
    ufw allow 6177/tcp comment 'Hysteria2 TCP' > /dev/null 2>&1

    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1

    echo -e "${GREEN}UFW настроен:${NC}"
    ufw status verbose
}

# ---------- 8. Fail2Ban ----------
setup_fail2ban() {
    echo -e "${CYAN}>>> Установка и настройка Fail2Ban...${NC}"
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

# ---------- 9. ECH (ИСПРАВЛЕНО) ----------
generate_ech() {
    echo -e "${CYAN}>>> Генерация ECH ключей...${NC}"

    if [ ! -f "$HYSTERIA_BIN" ]; then
        echo -e "${RED}Hysteria не установлен!${NC}"; return
    fi

    echo -e "${YELLOW}Введите домен для маскировки (Enter = www.icloud.com):${NC}"
    read -r public_name
    [ -z "$public_name" ] && public_name="www.icloud.com"

    # Генерируем ключи
    "$HYSTERIA_BIN" ech --public-name "$public_name" > "$ECH_KEY" 2>&1

    if [ ! -s "$ECH_KEY" ]; then
        echo -e "${RED}Ошибка генерации ECH. Проверьте версию Hysteria (нужна >= 2.12.3).${NC}"
        return
    fi

    echo -e "${GREEN}ECH ключи сохранены: $ECH_KEY${NC}"
    echo ""

    # Добавляем в конфиг, если ещё нет
    if ! grep -q "^ech:" "$HYSTERIA_CONFIG" 2>/dev/null; then
        sed -i "/^tls:/i ech:\n  keyFile: $ECH_KEY" "$HYSTERIA_CONFIG"
        echo -e "${GREEN}Секция ech добавлена в конфиг.${NC}"
    else
        echo -e "${YELLOW}Секция ech уже присутствует в конфиге.${NC}"
    fi

    systemctl restart "$HYSTERIA_SERVICE"
    sleep 2

    echo ""
    echo -e "${MAGENTA}==========================================================${NC}"
    echo -e "${MAGENTA}  СТРОКА ДЛЯ КЛИЕНТА (скопируйте всё до конца):${NC}"
    echo -e "${MAGENTA}==========================================================${NC}"
    echo ""
    # Показываем содержимое файла — это и есть ECH config
    cat "$ECH_KEY"
    echo ""
    echo -e "${MAGENTA}==========================================================${NC}"
    echo -e "${YELLOW}Вставьте эту строку в поле 'ech' или 'tls.ech' в клиенте.${NC}"
}

# ---------- 10. Приоритет процесса ----------
optimize_priority() {
    echo -e "${CYAN}>>> Оптимизация приоритета Hysteria2...${NC}"
    mkdir -p /etc/systemd/system/"$HYSTERIA_SERVICE".service.d/

    cat > /etc/systemd/system/"$HYSTERIA_SERVICE".service.d/priority.conf << 'PRIORITY'
[Service]
CPUWeight=1000
IOSchedulingClass=realtime
IOSchedulingPriority=0
Nice=-20
LimitNOFILE=1048576
LimitNPROC=1048576
LimitMEMLOCK=infinity
PRIORITY

    systemctl daemon-reload
    systemctl restart "$HYSTERIA_SERVICE"
    echo -e "${GREEN}Приоритет процесса повышен.${NC}"
}

# ---------- 11. Показать ключ ECH (новый пункт) ----------
show_ech() {
    if [ ! -f "$ECH_KEY" ]; then
        echo -e "${RED}Файл $ECH_KEY не найден. Сначала сгенерируйте ключи (пункт 9).${NC}"
        return
    fi
    echo -e "${MAGENTA}=== ECH CONFIG ДЛЯ КЛИЕНТА ===${NC}"
    echo ""
    cat "$ECH_KEY"
    echo ""
    echo -e "${MAGENTA}==============================${NC}"
}

# ---------- 12. Бэкап конфига ----------
backup_config() {
    BACKUP_DIR="/root/hysteria-backups"
    mkdir -p "$BACKUP_DIR"
    STAMP=$(date +%Y%m%d-%H%M%S)
    cp "$HYSTERIA_CONFIG" "$BACKUP_DIR/config-$STAMP.yaml" 2>/dev/null
    [ -f "$ECH_KEY" ] && cp "$ECH_KEY" "$BACKUP_DIR/ech-$STAMP.pem"
    echo -e "${GREEN}Бэкап сохранён в $BACKUP_DIR${NC}"
    ls -lh "$BACKUP_DIR" | tail -5
}

# ---------- МЕНЮ ----------
show_menu() {
    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}           Hysteria2 Server Manager v2.0${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN} 1) Установить / обновить Hysteria2${NC}"
    echo -e "${GREEN} 2) Настроить конфиг Hysteria2${NC}"
    echo -e "${GREEN} 3) Перезапустить Hysteria2${NC}"
    echo -e "${GREEN} 4) Статус Hysteria2${NC}"
    echo -e "${GREEN} 5) Логи Hysteria2${NC}"
    echo ""
    echo -e "${YELLOW} 6) Оптимизация сети (sysctl + BBR)${NC}"
    echo -e "${YELLOW} 7) Настроить UFW (файрвол)${NC}"
    echo -e "${YELLOW} 8) Настроить Fail2Ban${NC}"
    echo -e "${YELLOW} 9) Генерировать ECH ключи${NC}"
    echo -e "${YELLOW}10) Оптимизация приоритета Hysteria2${NC}"
    echo ""
    echo -e "${MAGENTA}11) Показать ECH config для клиента${NC}"
    echo -e "${MAGENTA}12) Бэкап конфигов${NC}"
    echo ""
    echo -e "${RED} 0) Выход${NC}"
    echo -e "${CYAN}============================================================${NC}"
    read -p "Выберите пункт: " choice

    case $choice in
        1)  install_hysteria; pause ;;
        2)  configure_hysteria; pause ;;
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
        0)  exit 0 ;;
        *)  echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
    esac
}

# ---------- ЦИКЛ ----------
while true; do
    show_menu
done
