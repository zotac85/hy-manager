#!/bin/bash
REPO_URL="https://raw.githubusercontent.com/zotac85/hy-manager/main/hy-manager.sh"
echo ">>> Скачиваем скрипт из GitHub..."
curl -fsSL "$REPO_URL" -o /usr/local/bin/hy-manager.sh
if [ ! -s /usr/local/bin/hy-manager.sh ]; then
    echo "Ошибка: не удалось скачать скрипт!"
    exit 1
fi
chmod +x /usr/local/bin/hy-manager.sh
ln -sf /usr/local/bin/hy-manager.sh /usr/local/bin/hys2
echo "======================================================"
echo "Готово! Запуск: hys2"
echo "======================================================"
