# Hysteria2 Server Manager

Скрипт для управления и оптимизации сервера Hysteria2 на Ubuntu/Debian.

## 📦 Установка

Одна команда — установит скрипт и создаст ярлык `hys2`:

    bash <(curl -fsSL https://raw.githubusercontent.com/zotac85/hy-manager/main/install.sh)

После установки запуск:

    hys2

## 🖥️ Возможности менеджера

| № | Действие |
|---|----------|
| 1 | Установить / обновить Hysteria2 |
| 2 | Настроить конфиг Hysteria2 |
| 3 | Перезапустить Hysteria2 |
| 4 | Статус Hysteria2 |
| 5 | Логи Hysteria2 |
| 6 | Оптимизация сети (sysctl + BBR) |
| 7 | Настроить UFW (файрвол) |
| 8 | Настроить Fail2Ban |
| 9 | Генерировать ECH ключи |
| 10 | Оптимизация приоритета Hysteria2 |
| 11 | Показать ECH config для клиента |
| 12 | Бэкап конфигов |

## 🚀 Установка Hysteria2 с нуля

1. Установите Hysteria2 (пункт 1 меню `hys2`):

    bash <(curl -fsSL https://get.hy2.sh/)

2. Настройте конфиг `/etc/hysteria/config.yaml`:

    listen: :53
    bandwidth:
      up: 30 mbps
      down: 30 mbps
    tls:
      cert: /etc/hysteria/cert.pem
      key: /etc/hysteria/key.pem
    auth:
      type: password
      password: "Hs2_auth_ПАРОЛЬ"
    obfs:
      type: salamander
      salamander:
        password: "Salam_ОБФС_ПАРОЛЬ"
    masquerade:
      type: proxy
      proxy:
        url: https://www.icloud.com
        rewriteHost: true

3. Перезапустите:

    systemctl restart hysteria-server
    systemctl enable hysteria-server

## 🔐 Генерация сертификата Let's Encrypt

    apt install -y certbot
    certbot certonly --standalone -d your-domain.com

В конфиге Hysteria:

    tls:
      cert: /etc/letsencrypt/live/your-domain.com/fullchain.pem
      key: /etc/letsencrypt/live/your-domain.com/privkey.pem

## 💻 Оптимизация сети (пункт 6)

- BBR — современный алгоритм контроля перегрузки TCP
- fq — честная очередь пакетов
- Увеличенные буферы UDP (для QUIC)
- Увеличенные TCP-окна
- Отключён slow start
- Увеличены лимиты файловых дескрипторов

Сохраняется в `/etc/sysctl.d/99-hysteria-optimize.conf`.

## 🔥 UFW (пункт 7)

Открывает порты:
- 22/tcp (или ваш SSH-порт)
- 53/udp (Hysteria2)
- 6177/tcp (Hysteria2)

Проверка:

    ufw status verbose

## 🛡️ Fail2Ban (пункт 8)

- Бан на 1 час после 5 неудачных попыток
- Период наблюдения — 10 минут

Проверка:

    fail2ban-client status sshd

## 🔐 ECH (пункт 9)

Генерирует ключи шифрования SNI. Строку для клиента смотрите в пункте 11.
Ключи сохраняются в `/etc/hysteria/ech.pem`.

## 📱 Настройка клиента

| Параметр | Значение |
|----------|----------|
| Протокол | Hysteria2 |
| Адрес | Ваш домен или IP |
| Порт | 53 (или внешний порт из панели) |
| Пароль | Hs2_auth_ПАРОЛЬ |
| Обфускация | salamander |
| Пароль обфускации | Salam_ОБФС_ПАРОЛЬ |
| SNI | your-domain.com или www.icloud.com |
| Insecure | включено (для самоподписанных) |

### Ссылка для Happ / Nekoray

    hysteria2://ПАРОЛЬ@ДОМЕН:53/?sni=www.icloud.com&obfs=salamander&obfs-password=ОБФС_ПАРОЛЬ&insecure=1

### JSON-конфиг для sing-box

    {
      "outbounds": [
        {
          "type": "hysteria2",
          "tag": "Hysteria2",
          "server": "ВАШ_ДОМЕН",
          "server_port": 53,
          "password": "Hs2_auth_ПАРОЛЬ",
          "obfs": {
            "type": "salamander",
            "password": "Salam_ОБФС_ПАРОЛЬ"
          },
          "tls": {
            "enabled": true,
            "server_name": "www.icloud.com",
            "insecure": true
          }
        }
      ]
    }

## 🛠️ Полезные команды

    systemctl status hysteria-server
    systemctl restart hysteria-server
    systemctl stop hysteria-server
    systemctl enable hysteria-server
    journalctl -u hysteria-server -n 50
    ss -tulpn | grep hysteria
    openssl x509 -in /etc/hysteria/cert.pem -noout -fingerprint -sha256

### Swap-файл (для 512 МБ RAM)

    dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    free -h

## 🔄 Обновление скрипта

    cd /root/hy-manager
    cp /usr/local/bin/hy-manager.sh ./hy-manager.sh
    git add .
    git commit -m "Обновление"
    git push

Обновить на других серверах:

    bash <(curl -fsSL https://raw.githubusercontent.com/zotac85/hy-manager/main/install.sh)

## ⚠️ Важные замечания

- Порт 53 используется для DNS. Отключите systemd-resolved:
      systemctl stop systemd-resolved
      systemctl disable systemd-resolved

- UFW может заблокировать SSH. Проверьте, что SSH-порт открыт.

- После ECH перезапустите Hysteria: systemctl restart hysteria-server

- Backup — пункт 12 меню.

## 📄 Лицензия

MIT
