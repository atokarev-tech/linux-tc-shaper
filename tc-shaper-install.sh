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

# Функция проверки интерфейсов
check_interfaces() {
    if ! ip link show $WAN >/dev/null 2>&1; then
        echo "Ошибка: Интерфейс $WAN не существует"
        exit 1
    fi
    
    if ! ip link show $LAN >/dev/null 2>&1; then
        echo "Ошибка: Интерфейс $LAN не существует"
        exit 1
    fi
    
    # Проверяем, что интерфейсы не одинаковые
    if [ "$WAN" = "$LAN" ]; then
        echo "Ошибка: WAN и LAN интерфейсы должны быть разными"
        exit 1
    fi
}

# Основная функция настройки шейпера
configure_shaper() {
    # Очистка предыдущих правил
    tc qdisc del dev $WAN root 2>/dev/null
    tc qdisc del dev $LAN root 2>/dev/null
    
    # Проверяем, что интерфейсы подняты
    ip link set dev $WAN up
    ip link set dev $LAN up
    
    # Настройка для WAN
    tc qdisc add dev $WAN root handle 1: htb default 10 r2q $R2Q_VALUE
    tc class add dev $WAN parent 1: classid 1:1 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    tc class add dev $WAN parent 1:1 classid 1:10 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    
    # Настройка для LAN
    tc qdisc add dev $LAN root handle 1: htb default 10 r2q $R2Q_VALUE
    tc class add dev $LAN parent 1: classid 1:1 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    tc class add dev $LAN parent 1:1 classid 1:10 htb rate $LIMIT_RATE ceil $LIMIT_RATE burst $BURST cburst $BURST
    
    echo "✅ Шейпер настроен: ограничение $LIMIT_RATE на каждом интерфейсе"
    
    # Показываем результат
    echo ""
    echo "Текущие настройки:"
    tc -s qdisc show dev $WAN
    echo ""
    tc -s qdisc show dev $LAN
}

# Функция создания systemd службы (ИСПРАВЛЕННАЯ)
create_systemd_service() {
    local SCRIPT_SOURCE="$0"
    local SCRIPT_DEST="/usr/local/bin/tc-shaper.sh"
    
    echo "Создание systemd службы..."
    
    # Создаем директорию, если её нет
    mkdir -p /usr/local/bin
    
    # Копируем текущий скрипт с проверкой
    if [ -f "$SCRIPT_SOURCE" ]; then
        cp "$SCRIPT_SOURCE" "$SCRIPT_DEST"
        chmod 755 "$SCRIPT_DEST"
        echo "✅ Скрипт скопирован в $SCRIPT_DEST"
    else
        echo "❌ Ошибка: Не найден исходный скрипт $SCRIPT_SOURCE"
        exit 1
    fi
    
    # Проверяем, что файл создан
    if [ ! -f "$SCRIPT_DEST" ]; then
        echo "❌ Ошибка: Не удалось создать $SCRIPT_DEST"
        exit 1
    fi
    
    # Создаем service файл
    cat > /etc/systemd/system/tc-shaper.service << EOF
[Unit]
Description=TC Traffic Shaper
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DEST --apply
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    echo "✅ Service файл создан /etc/systemd/system/tc-shaper.service"
    
    # Перезагружаем systemd и включаем службу
    systemctl daemon-reload
    systemctl enable tc-shaper.service
    
    if [ $? -eq 0 ]; then
        echo "✅ Служба включена в автозагрузку"
    else
        echo "❌ Ошибка при включении автозагрузки"
    fi
}

# Функция применения сохраненных настроек (для запуска из systemd)
apply_saved_config() {
    if [ -f /etc/tc-shaper.conf ]; then
        source /etc/tc-shaper.conf
        echo "Применение сохраненной конфигурации..."
        check_interfaces
        configure_shaper
    else
        echo "❌ Ошибка: Конфигурационный файл /etc/tc-shaper.conf не найден"
        exit 1
    fi
}

# Функция удаления шейпера
remove_shaper() {
    echo "Удаление шейпера..."
    
    # Останавливаем и отключаем службу
    systemctl stop tc-shaper.service 2>/dev/null
    systemctl disable tc-shaper.service 2>/dev/null
    
    # Удаляем файлы
    rm -f /etc/systemd/system/tc-shaper.service
    rm -f /usr/local/bin/tc-shaper.sh
    systemctl daemon-reload
    
    # Очищаем правила tc
    if [ -f /etc/tc-shaper.conf ]; then
        source /etc/tc-shaper.conf
        tc qdisc del dev $WAN root 2>/dev/null
        tc qdisc del dev $LAN root 2>/dev/null
        rm -f /etc/tc-shaper.conf
    fi
    
    echo "✅ Шейпер удален"
}

# Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo "❌ Этот скрипт должен запускаться с правами root"
    exit 1
fi

# Обработка аргументов командной строки
if [ "$1" = "--apply" ]; then
    apply_saved_config
    exit 0
fi

# Главное меню
while true; do
    echo ""
    echo "=== Настройка TC Traffic Shaper ==="
    echo "1. Настроить и запустить шейпер"
    echo "2. Только создать systemd службу (с существующими настройками)"
    echo "3. Удалить шейпер"
    echo "4. Показать статус"
    echo "5. Выйти"
    echo ""
    
    read -p "Выберите действие (1-5): " ACTION
    
    case $ACTION in
        1)
            ask_for_interfaces
            check_interfaces
            
            # Сохраняем настройки для будущих запусков
            cat > /etc/tc-shaper.conf << EOF
WAN=$WAN
LAN=$LAN
LIMIT_RATE=$LIMIT_RATE
R2Q_VALUE=$R2Q_VALUE
BURST=$BURST
EOF
            echo "✅ Настройки сохранены в /etc/tc-shaper.conf"
            
            configure_shaper
            
            read -p "Создать systemd службу для автозагрузки? (y/n): " CREATE_SERVICE
            if [[ $CREATE_SERVICE == "y" || $CREATE_SERVICE == "Y" ]]; then
                create_systemd_service
                
                read -p "Запустить службу сейчас? (y/n): " RUN_NOW
                if [[ $RUN_NOW == "y" || $RUN_NOW == "Y" ]]; then
                    systemctl start tc-shaper.service
                    echo "✅ Служба запущена"
                    systemctl status tc-shaper.service --no-pager
                fi
            fi
            ;;
        2)
            if [ -f /etc/tc-shaper.conf ]; then
                create_systemd_service
                echo "✅ Служба создана. Для запуска выполните: systemctl start tc-shaper.service"
            else
                echo "❌ Конфигурационный файл не найден. Сначала выполните настройку (пункт 1)."
            fi
            ;;
        3)
            remove_shaper
            ;;
        4)
            echo ""
            echo "=== Статус ==="
            systemctl status tc-shaper.service 2>/dev/null || echo "Служба не установлена"
            echo ""
            echo "Текущие правила tc:"
            tc qdisc show
            ;;
        5)
            echo "Выход"
            exit 0
            ;;
        *)
            echo "❌ Неверный выбор"
            ;;
    esac
done
