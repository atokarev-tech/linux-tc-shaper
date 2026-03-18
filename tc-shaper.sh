#!/bin/bash

# Функция для запроса данных у пользователя
ask_for_interfaces() {
    echo "Доступные сетевые интерфейсы:"
    ip link show | grep -v lo | grep -o '^[0-9]: [^:]*' | cut -d' ' -f2
    echo ""
    
    read -p "Введите WAN интерфейс (интернет): " WAN
    read -p "Введите LAN интерфейс (локальная сеть): " LAN
    read -p "Введите скорость интернета по контракту (в Мбит/с, например 100): " SPEED_MBIT
    
    # Конвертируем в килобиты для tc
    LIMIT_RATE="${SPEED_MBIT}Mbit"
    
    # Автоматический расчет r2q: rate (в битах) / 60000
    # RATE_BITS = SPEED_MBIT * 1000000
    R2Q_VALUE=$(( (SPEED_MBIT * 1000000) / 60000 ))
    
    # Минимальное значение r2q - 1, максимальное - 60000
    if [ $R2Q_VALUE -lt 1 ]; then
        R2Q_VALUE=1
    elif [ $R2Q_VALUE -gt 60000 ]; then
        R2Q_VALUE=60000
    fi
    
    BURST="256k"
    
    echo ""
    echo "Настройки:"
    echo "WAN: $WAN"
    echo "LAN: $LAN"
    echo "Скорость: $LIMIT_RATE"
    echo "r2q: $R2Q_VALUE"
    echo ""
    
    read -p "Применить эти настройки? (y/n): " CONFIRM
    if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        echo "Отменено"
        exit 1
    fi
}

# Основная функция настройки шейпера
configure_shaper() {
    # Очистка предыдущих правил
    tc qdisc del dev $WAN root 2>/dev/null
    tc qdisc del dev $LAN root 2>/dev/null
    
    # Настройка для WAN
    tc qdisc add dev $WAN root handle 1: htb default 10 r2q $R2Q_VALUE
    tc class add dev $WAN parent 1: classid 1:1 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    tc class add dev $WAN parent 1:1 classid 1:10 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    
    # Настройка для LAN
    tc qdisc add dev $LAN root handle 1: htb default 10 r2q $R2Q_VALUE
    tc class add dev $LAN parent 1: classid 1:1 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    tc class add dev $LAN parent 1:1 classid 1:10 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    
    echo "Шейпер настроен: ограничение $LIMIT_RATE на каждом интерфейсе"
}

# Функция создания systemd службы
create_systemd_service() {
    local SCRIPT_PATH="/usr/local/bin/tc-shaper.sh"
    
    # Копируем текущий скрипт
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    
    # Создаем service файл
    cat > /etc/systemd/system/tc-shaper.service << EOF
[Unit]
Description=TC Traffic Shaper
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

    # Перезагружаем systemd и включаем службу
    systemctl daemon-reload
    systemctl enable tc-shaper.service
    
    echo "Systemd служба создана и включена в автозагрузку"
    
    read -p "Запустить шейпер сейчас? (y/n): " RUN_NOW
    if [[ $RUN_NOW == "y" || $RUN_NOW == "Y" ]]; then
        systemctl start tc-shaper.service
        systemctl status tc-shaper.service
    fi
}

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo "Этот скрипт должен запускаться с правами root"
    exit 1
fi

# Главное меню
echo "=== Настройка TC Traffic Shaper ==="
echo "1. Настроить и запустить шейпер"
echo "2. Только создать systemd службу (с существующими настройками)"
echo "3. Удалить шейпер"
echo "4. Выйти"
echo ""

read -p "Выберите действие (1-4): " ACTION

case $ACTION in
    1)
        ask_for_interfaces
        configure_shaper
        
        # Сохраняем настройки для будущих запусков
        cat > /etc/tc-shaper.conf << EOF
WAN=$WAN
LAN=$LAN
LIMIT_RATE=$LIMIT_RATE
R2Q_VALUE=$R2Q_VALUE
BURST=$BURST
EOF
        
        echo "Настройки сохранены в /etc/tc-shaper.conf"
        
        read -p "Создать systemd службу для автозагрузки? (y/n): " CREATE_SERVICE
        if [[ $CREATE_SERVICE == "y" || $CREATE_SERVICE == "Y" ]]; then
            create_systemd_service
        fi
        ;;
    2)
        if [ -f /etc/tc-shaper.conf ]; then
            source /etc/tc-shaper.conf
            create_systemd_service
        else
            echo "Конфигурационный файл не найден. Сначала выполните настройку."
            exit 1
        fi
        ;;
    3)
        systemctl stop tc-shaper.service 2>/dev/null
        systemctl disable tc-shaper.service 2>/dev/null
        rm -f /etc/systemd/system/tc-shaper.service
        rm -f /usr/local/bin/tc-shaper.sh
        systemctl daemon-reload
        
        tc qdisc del dev $WAN root 2>/dev/null
        tc qdisc del dev $LAN root 2>/dev/null
        
        echo "Шейпер удален"
        ;;
    4)
        exit 0
        ;;
    *)
        echo "Неверный выбор"
        exit 1
        ;;
esac
