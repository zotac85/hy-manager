#!/bin/bash
# ============================================================
#  Full Server Setup — Hysteria2 + h-ui + hy-manager
# ============================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1"; }

# ============================================================
#  1. Обновление системы
# ============================================================
log "Обновление пакетов..."
apt update -qq && apt upgrade -y -qq

# ============================================================
#  2. Базовые утилиты
# ============================================================
log "Установка базовых утилит..."
apt install -y -qq curl wget git nano ufw fail2ban certbot openssl

# ============================================================
#  3. Docker
# ============================================================
if ! command -v docker &> /dev/null; then
    log "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker > /dev/null 2>&1
else
    log "Docker уже установлен"
fi

# ============================================================
#  4. h-ui (Docker)
# ============================================================
log "Разворачиваем h-ui..."
mkdir -p /h-ui/{bin,bin/certs,data,logs,export}

if docker ps -a --format '{{.Names}}' | grep -q '^h-ui$'; then
    warn "Контейнер h-ui уже существует"
else
    docker run -d --name h-ui --restart=always \
      -p 8888:8888 \
      -v /h-ui/bin:/h-ui/bin \
      -v /h-ui/data:/h-ui/data \
      -v /h-ui/logs:/h-ui/logs \
      -v /h-ui/export:/h-ui/export \
      jonssonyan/h-ui:latest
fi

# ============================================================
#  5. Hysteria2 бинарник
# ============================================================
log "Установка Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/) > /dev/null 2>&1

# ============================================================
#  6. hy-manager.sh + renew-cert.sh
# ============================================================
log "Установка hy-manager.sh..."
curl -fsSL "https://raw.githubusercontent.com/zotac85/hy-manager/main/hy-manager.sh" \
    -o /usr/local/bin/hy-manager.sh
chmod +x /usr/local/bin/hy-manager.sh
ln -sf /usr/local/bin/hy-manager.sh /usr/local/bin/hys2

log "Установка renew-cert.sh..."
curl -fsSL "https://raw.githubusercontent.com/zotac85/hy-manager/main/renew-cert.sh" \
    -o /usr/local/bin/renew-cert.sh
chmod +x /usr/local/bin/renew-cert.sh

# ============================================================
#  7. Cron для продления сертификата
# ============================================================
log "Настройка cron для продления сертификата..."
cat > /etc/cron.d/certbot-renew << 'CRON'
0 3 * * * root /usr/local/bin/renew-cert.sh
CRON
chmod 644 /etc/cron.d/certbot-renew

# ============================================================
#  8. UFW
# ============================================================
log "Настройка UFW..."
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
[ -z "$SSH_PORT" ] && SSH_PORT=22

ufw --force enable > /dev/null 2>&1
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1
ufw allow "$SSH_PORT"/tcp comment 'SSH' > /dev/null 2>&1
ufw allow 8888/tcp comment 'h-ui' > /dev/null 2>&1
ufw allow 80/tcp comment 'Certbot' > /dev/null 2>&1
ufw allow 443/tcp comment 'Masquerade HTTPS' > /dev/null 2>&1
ufw allow 53/udp comment 'Hysteria2 default' > /dev/null 2>&1
ufw allow 8443/udp comment 'Hysteria2 recommended' > /dev/null 2>&1

# ============================================================
#  9. BBR + оптимизация сети
# ============================================================
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

# ============================================================
#  10. Проверка бэкапа
# ============================================================
if [ -f /root/migration.tar.gz ]; then
    warn "Найден бэкап /root/migration.tar.gz"
    read -p "Восстановить данные? (y/n): " RESTORE
    if [[ "$RESTORE" == "y" ]]; then
        tar xzf /root/migration.tar.gz -C /root/
        [ -f /root/migration/hysteria2.yaml ] && cp /root/migration/hysteria2.yaml /h-ui/bin/
        [ -d /root/migration/certs ] && cp -r /root/migration/certs/* /h-ui/bin/certs/ 2>/dev/null
        [ -d /root/migration/data ] && cp -r /root/migration/data/* /h-ui/data/ 2>/dev/null
        [ -d /root/migration/letsencrypt ] && cp -r /root/migration/letsencrypt /etc/ 2>/dev/null
        docker restart h-ui
        log "Данные восстановлены"
    fi
fi

# ============================================================
#  11. Финальная проверка
# ============================================================
log "Проверка..."
echo ""
echo -e "${CYAN}=== Статус контейнера ===${NC}"
docker ps | grep h-ui || echo "h-ui НЕ запущен"

echo ""
echo -e "${CYAN}=== Порт 8888 (h-ui) ===${NC}"
ss -tulpn | grep :8888 || echo "Порт 8888 не слушается"

echo ""
echo -e "${CYAN}=== UFW ===${NC}"
ufw status | grep -E "Status|22|53|80|443|8443|8888"

echo ""
echo "======================================================"
echo -e "${GREEN}✅ Установка завершена!${NC}"
echo "======================================================"
echo ""
echo -e "${YELLOW}Следующие шаги:${NC}"
echo "1. Откройте панель:  http://ВАШ_IP:8888"
echo "2. Создайте администратора"
echo "3. Настройте Hysteria (порт, SNI, obfs, masquerade)"
echo "4. Получите сертификат: hys2 → пункт 15"
echo "5. Запустите Hysteria через панель"
echo ""
echo -e "${CYAN}Управление: hys2${NC}"
echo "======================================================"
