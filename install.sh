#!/bin/bash
# ============================================================
#  Hysteria2 Universal Installer
#  GitHub: https://github.com/zotac85/hy-manager
# ============================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }
pause() { echo ""; read -p "Нажмите Enter для продолжения..." _; }

# ============================================================
#  БАЗОВЫЕ ФУНКЦИИ
# ============================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "Запустите от root!"
        exit 1
    fi
}

base_setup() {
    log "Обновление пакетов..."
    apt update -qq && apt upgrade -y -qq
    log "Установка утилит..."
    apt install -y -qq curl wget git nano ufw fail2ban certbot openssl tcpdump
}

install_docker() {
    if command -v docker &> /dev/null; then
        log "Docker уже установлен"
    else
        log "Установка Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker > /dev/null 2>&1
    fi
}

free_port_53() {
    log "Отключение systemd-resolved (освобождаем порт 53)..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf 2>/dev/null || true
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    log "Порт 53 освобождён, DNS переключён на 1.1.1.1"
}

install_hysteria_bin() {
    log "Установка Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) > /dev/null 2>&1
    log "Hysteria2 установлена"
}

install_hui_docker() {
    log "Разворачиваем h-ui..."
    mkdir -p /h-ui/{bin,bin/certs,data,logs,export}

    if docker ps -a --format '{{.Names}}' | grep -q '^h-ui$'; then
        warn "Контейнер h-ui уже существует"
    else
        docker run -d --name h-ui --restart=always \
          --network host \
          -v /h-ui/bin:/h-ui/bin \
          -v /h-ui/data:/h-ui/data \
          -v /h-ui/logs:/h-ui/logs \
          -v /h-ui/export:/h-ui/export \
          jonssonyan/h-ui:latest
        log "Контейнер h-ui запущен"
    fi
}

install_manager() {
    log "Установка hy-manager.sh..."
    curl -fsSL "https://raw.githubusercontent.com/zotac85/hy-manager/main/hy-manager.sh" \
        -o /usr/local/bin/hy-manager.sh
    chmod +x /usr/local/bin/hy-manager.sh
    ln -sf /usr/local/bin/hy-manager.sh /usr/local/bin/hys2

    log "Установка renew-cert.sh..."
    curl -fsSL "https://raw.githubusercontent.com/zotac85/hy-manager/main/renew-cert.sh" \
        -o /usr/local/bin/renew-cert.sh
    chmod +x /usr/local/bin/renew-cert.sh

    log "Установка certbot-renew cron..."
    cat > /etc/cron.d/certbot-renew << 'CRON'
0 3 * * * root /usr/local/bin/renew-cert.sh
CRON
    chmod 644 /etc/cron.d/certbot-renew
}

setup_ufw() {
    log "Настройка UFW..."
    local SSH_PORT
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    ufw --force enable > /dev/null 2>&1
    ufw default deny incoming > /dev/null 2>&1
    ufw default allow outgoing > /dev/null 2>&1
    ufw allow "$SSH_PORT"/tcp comment 'SSH' > /dev/null 2>&1
    ufw allow 8888/tcp comment 'h-ui' > /dev/null 2>&1
    ufw allow 80/tcp comment 'Certbot' > /dev/null 2>&1
    ufw allow 443/tcp comment 'Masquerade' > /dev/null 2>&1
    ufw allow 53/udp comment 'Hysteria2' > /dev/null 2>&1
    ufw allow 8443/udp comment 'Hysteria2 alt' > /dev/null 2>&1
    log "UFW настроен (SSH=$SSH_PORT, 8888/tcp, 53/udp, 8443/udp)"
}

setup_bbr() {
    log "Оптимизация сети (BBR + буферы)..."
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
SYSCTL
    sysctl --system > /dev/null 2>&1
    log "BBR включён, буферы увеличены"
}

restore_backup() {
    if [ ! -f /root/migration.tar.gz ]; then
        err "Файл /root/migration.tar.gz не найден!"
        return
    fi
    log "Восстановление из бэкапа..."
    tar xzf /root/migration.tar.gz -C /root/
    [ -f /root/migration/hysteria2.yaml ] && cp /root/migration/hysteria2.yaml /h-ui/bin/
    [ -d /root/migration/certs ] && cp -r /root/migration/certs/* /h-ui/bin/certs/ 2>/dev/null
    [ -d /root/migration/data ] && cp -r /root/migration/data/* /h-ui/data/ 2>/dev/null
    [ -d /root/migration/letsencrypt ] && cp -r /root/migration/letsencrypt /etc/ 2>/dev/null
    docker restart h-ui 2>/dev/null
    log "Данные восстановлены"
}

# ============================================================
#  КОМБИНИРОВАННЫЕ СЦЕНАРИИ
# ============================================================

install_full() {
    check_root
    base_setup
    free_port_53
    install_docker
    install_hui_docker
    install_hysteria_bin
    install_manager
    setup_ufw
    setup_bbr

    if [ -f /root/migration.tar.gz ]; then
        echo ""
        warn "Найден бэкап /root/migration.tar.gz"
        read -p "Восстановить данные? (y/n): " RESTORE
        [[ "$RESTORE" == "y" ]] && restore_backup
    fi

    echo ""
    echo -e "${GREEN}✅ Установка с панелью завершена!${NC}"
    echo "1. Панель:  http://$(curl -4 -s ifconfig.me):8888"
    echo "2. Создайте администратора"
    echo "3. Настройте Hysteria в панели"
    echo "4. Управление: hys2"
}

install_clean() {
    check_root
    base_setup
    free_port_53
    install_hysteria_bin
    install_manager
    setup_ufw
    setup_bbr

    echo ""
    warn "Установка БЕЗ панели h-ui."
    warn "Настройте /etc/hysteria/config.yaml вручную."
    echo ""
    read -p "Открыть конфиг сейчас? (y/n): " EDIT
    if [[ "$EDIT" == "y" ]]; then
        mkdir -p /etc/hysteria
        nano /etc/hysteria/config.yaml
    fi

    echo ""
    echo -e "${GREEN}✅ Установка без панели завершена!${NC}"
}

# ============================================================
#  МЕНЮ
# ============================================================

show_menu() {
    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}         Hysteria2 Universal Installer${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "${GREEN} 1) Полная установка (Hysteria2 + панель h-ui)${NC}"
    echo -e "${GREEN} 2) Установка без панели (только Hysteria2)${NC}"
    echo -e "${GREEN} 3) Восстановить из бэкапа${NC}"
    echo ""
    echo -e "${YELLOW} 4) Только базовые пакеты${NC}"
    echo -e "${YELLOW} 5) Только Docker${NC}"
    echo -e "${YELLOW} 6) Только освободить порт 53${NC}"
    echo -e "${YELLOW} 7) Только hy-manager (hys2)${NC}"
    echo ""
    echo -e "${MAGENTA} 8) Настроить UFW${NC}"
    echo -e "${MAGENTA} 9) Настроить BBR + буферы${NC}"
    echo -e "${MAGENTA}10) Установить/обновить Hysteria2 (bin)${NC}"
    echo ""
    echo -e "${RED} 0) Выход${NC}"
    echo -e "${CYAN}============================================================${NC}"
    read -p "Выберите пункт: " choice

    case $choice in
        1) install_full; pause ;;
        2) install_clean; pause ;;
        3) check_root; restore_backup; pause ;;
        4) check_root; base_setup; pause ;;
        5) check_root; install_docker; pause ;;
        6) check_root; free_port_53; pause ;;
        7) check_root; install_manager; pause ;;
        8) check_root; setup_ufw; pause ;;
        9) check_root; setup_bbr; pause ;;
        10) check_root; install_hysteria_bin; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
}

while true; do
    show_menu
done
