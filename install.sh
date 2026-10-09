#!/bin/bash
# ============================================================
#  Hysteria2 Manager — установщик
# ============================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; NC='\033[0m'

REPO="https://raw.githubusercontent.com/zotac85/hy-manager/main"

echo -e "${CYAN}>>> Скачиваем скрипт управления...${NC}"
curl -fsSL "$REPO/hy-menu.sh" -o /usr/local/bin/hy-menu.sh
curl -fsSL "$REPO/hysteria-optimize.sh" -o /usr/local/bin/hysteria-optimize.sh
chmod +x /usr/local/bin/hysteria-optimize.sh

if [ ! -s /usr/local/bin/hy-menu.sh ]; then
    echo -e "${RED}Ошибка: не удалось скачать hy-menu.sh${NC}"
    exit 1
fi

chmod +x /usr/local/bin/hy-menu.sh
ln -sf /usr/local/bin/hy-menu.sh /usr/local/bin/hys

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}✅ Установка завершена!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""
echo -e "${YELLOW}Запуск меню:${NC}  hys"
echo ""
