#!/bin/bash
# hysteria-optimize.sh — полная оптимизация для hy-menu.sh
LOG="/var/log/hysteria-optimize.log"
echo ""
echo "⚡  ОПТИМИЗАЦИЯ СЕРВЕРА"
echo "━━━━━━━━━━━━━━━━━━━━"
echo "Старт: $(date '+%F %T')"
echo ""

PORT="${HY_PORT:-53}"
MASTER_IP="${1:-}"

step_ok()   { echo "   ✓ $1"; }
step_fail() { echo "   ✗ $1"; }

do_apt() {
    echo "→ apt update && apt upgrade..."
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt-get update -qq 2>&1 | grep -v "^WARNING" | tail -2
    echo "   (может занять 3-5 минут...)"
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade 2>&1 | tail -10
    if [ $? -eq 0 ]; then step_ok "Пакеты обновлены"; else step_fail "apt upgrade"; fi
}

do_ipv6_off() {
    echo "→ Отключение IPv6..."
    cat > /etc/sysctl.d/99-disable-ipv6.conf << 'IPV6EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPV6EOF
    sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1
    step_ok "IPv6 отключён"
}

do_ufw() {
    echo "→ Настройка UFW..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    ufw allow "$SSH_PORT"/tcp comment 'SSH' >/dev/null 2>&1
    ufw allow "$PORT"/udp comment 'Hysteria2' >/dev/null 2>&1
    ufw allow 80/tcp comment 'Masquerade' >/dev/null 2>&1
    ufw allow 443/tcp comment 'Masquerade' >/dev/null 2>&1
    echo "y" | ufw --force enable >/dev/null 2>&1
    if ufw status | grep -q "Status: active"; then
        step_ok "UFW активен (SSH:$SSH_PORT, $PORT/udp, 80, 443)"
    else
        step_fail "UFW"
    fi
}

do_fail2ban() {
    echo "→ Установка Fail2ban..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null 2>&1
    WHITELIST="127.0.0.1/8 ::1"
    [ -n "$MASTER_IP" ] && WHITELIST="$WHITELIST $MASTER_IP"
    cat > /etc/fail2ban/jail.local << F2BEOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = $WHITELIST

[sshd]
enabled = true
port = 22
F2BEOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    if systemctl is-active --quiet fail2ban; then
        step_ok "Fail2ban активен (whitelist: $WHITELIST)"
    else
        step_fail "Fail2ban"
    fi
}

do_bbr() {
    echo "→ Включение TCP BBR..."
    if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    fi
    modprobe tcp_bbr >/dev/null 2>&1
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        step_ok "TCP BBR включён"
    else
        step_fail "TCP BBR"
    fi
}

do_brutal() {
    echo "→ Установка TCP Brutal..."
    if command -v brutalctl >/dev/null 2>&1; then
        brutalctl add 0.0.0.0/0 20 >/dev/null 2>&1
        echo "@reboot sleep 30 && brutalctl add 0.0.0.0/0 20" > /etc/cron.d/hysteria-brutal
        chmod 644 /etc/cron.d/hysteria-brutal
        step_ok "TCP Brutal уже установлен (20 Mbps)"
        return
    fi
    KMAJ=$(uname -r | cut -d. -f1)
    KMIN=$(uname -r | cut -d. -f2)
    if [ "$KMAJ" -lt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -lt 10 ]; }; then
        step_fail "TCP Brutal: нужно ядро 5.10+ (у вас $(uname -r))"
        return
    fi
    bash <(curl -fsSL https://tcp.hy2.sh/) 2>&1 | tail -5
    if command -v brutalctl >/dev/null 2>&1; then
        brutalctl add 0.0.0.0/0 20 >/dev/null 2>&1
        echo "@reboot sleep 30 && brutalctl add 0.0.0.0/0 20" > /etc/cron.d/hysteria-brutal
        chmod 644 /etc/cron.d/hysteria-brutal
        step_ok "TCP Brutal установлен (20 Мбит/с + автозагрузка)"
    else
        step_fail "TCP Brutal"
    fi
}

do_buffers() {
    echo "→ Оптимизация буферов ядра..."
    cat > /etc/sysctl.d/99-hysteria-buffers.conf << 'BUFEOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 100000
net.core.somaxconn = 65535
fs.file-max = 1000000
BUFEOF
    sysctl -p /etc/sysctl.d/99-hysteria-buffers.conf >/dev/null 2>&1
    step_ok "Буферы ядра оптимизированы"
}

do_swap() {
    echo "→ Настройка Swap 1 GB..."
    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
    if [ "$SWAP_TOTAL" -gt 0 ]; then
        step_ok "Swap уже есть ($SWAP_TOTAL MB)"
        return
    fi
    if [ -f /swapfile ]; then
        swapon /swapfile >/dev/null 2>&1
        step_ok "Файл /swapfile активирован"
        return
    fi
    fallocate -l 1G /swapfile >/dev/null 2>&1 || dd if=/dev/zero of=/swapfile bs=1M count=1024 >/dev/null 2>&1
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile >/dev/null 2>&1
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    if [ "$(free -m | awk '/Swap:/ {print $2}')" -gt 0 ]; then
        step_ok "Swap 1 GB создан"
    else
        step_fail "Swap"
    fi
}

print_footer() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo "✅  ОПТИМИЗАЦИЯ ЗАВЕРШЕНА"
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo "Завершено: $(date '+%F %T')"
    echo ""
    if [ -f /var/run/reboot-required ]; then
        echo "⚠️  Требуется ПЕРЕЗАГРУЗКА (обновилось ядро)"
        echo ""
        read -p "Перезагрузить сейчас? (y/n): " _r
        if [ "$_r" = "y" ] || [ "$_r" = "Y" ]; then
            echo "Перезагрузка через 5 сек..."
            nohup bash -c 'sleep 5 && reboot' >/dev/null 2>&1 &
        fi
    fi
}

main() {
    echo "Hysteria2 порт: $PORT"
    [ -n "$MASTER_IP" ] && echo "Whitelist IP: $MASTER_IP"
    echo ""
    do_apt
    # do_ipv6_off  # ОТКЛЮЧЕНО: ломает DNS (возвращает IPv6, но соединение не работает)
    do_ufw
    do_fail2ban
    do_bbr
    # do_brutal  # ОТКЛЮЧЕНО: конфликтует со встроенным Brutal в Hysteria2
    do_buffers
    do_swap
    print_footer
}

main
