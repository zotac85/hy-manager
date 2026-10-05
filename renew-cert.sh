#!/bin/bash
LOG="/var/log/certbot-renew.log"
echo "$(date): Старт продления" >> $LOG

# Функция: живая ли Hysteria (не зомби + порт 53 занят)
is_hysteria_alive() {
    local alive_proc
    alive_proc=$(ps -eo pid,stat,cmd | grep "hysteria-linux" | grep -v grep | grep -v " Z " | head -1)
    local port_busy
    port_busy=$(ss -tulpn 2>/dev/null | grep ':53 ' | grep -c hysteria)
    [ -n "$alive_proc" ] && [ "$port_busy" -gt 0 ]
}

# Запоминаем, была ли Hysteria жива
WAS_RUNNING=0
if is_hysteria_alive; then
    WAS_RUNNING=1
fi

# Останавливаем Hysteria
pkill -9 -f "hysteria-linux" 2>/dev/null
sleep 5
echo "$(date): Hysteria остановлена" >> $LOG

# Продлеваем сертификат
certbot renew --quiet >> $LOG 2>&1
echo "$(date): Certbot завершён" >> $LOG

# Копируем новый сертификат в h-ui
for cert_dir in /etc/letsencrypt/live/*/; do
    if [ -f "$cert_dir/fullchain.pem" ]; then
        cp "$cert_dir/fullchain.pem" /h-ui/bin/certs/domain.crt
        cp "$cert_dir/privkey.pem" /h-ui/bin/certs/domain.key
        chmod 644 /h-ui/bin/certs/domain.crt
        chmod 600 /h-ui/bin/certs/domain.key
        echo "$(date): Сертификат скопирован" >> $LOG
    fi
done

# Новый отпечаток
echo "$(date): Новый отпечаток:" >> $LOG
openssl x509 -in /h-ui/bin/certs/domain.crt -noout -fingerprint -sha256 | sed 's/://g' >> $LOG

# Перезапускаем Hysteria через полный рестарт h-ui
if [ "$WAS_RUNNING" = "1" ]; then
    echo "$(date): Перезапуск h-ui (для чистого старта Hysteria)..." >> $LOG

    # Убиваем h-ui (это заберёт зомби)
    pkill -9 -f "h-ui -p" 2>/dev/null
    sleep 3

    # Запускаем h-ui заново
    cd /h-ui && nohup ./h-ui -p 8888 > /var/log/h-ui.log 2>&1 &
    echo "$(date): h-ui запущена, ждём Hysteria..." >> $LOG

    # Ждём до 60 секунд
    for i in {1..60}; do
        sleep 1
        if is_hysteria_alive; then
            echo "$(date): ✅ Hysteria работает (через ${i}с)" >> $LOG
            exit 0
        fi
    done

    echo "$(date): ❌ КРИТИЧНО: Hysteria не поднялась за 60 секунд!" >> $LOG
fi
