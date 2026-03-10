yum install apr apr-util bash bzip2 curl krb5-devel libcgroup-tools libcurl libuuid libevent libxml2 libyaml zlib openldap openssh openssl openssl-libs perl readline rsync R sed tar zip m4 tmux java-1.8.0-openjdk

#!/bin/bash
set -e # Выход при ошибке

echo "=== Обновление системы и установка необходимых пакетов ==="
sudo dnf update -y
sudo dnf install -y wget git curl policycoreutils-python-utils

echo "=== Добавление официального репозитория PostgreSQL ==="
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql

echo "=== Установка PostgreSQL 17 ==="
sudo dnf install -y postgresql17-server postgresql17-contrib

echo "=== Инициализация и запуск PostgreSQL ==="
sudo /usr/pgsql-17/bin/postgresql-17-setup initdb
sudo systemctl enable postgresql-17
sudo systemctl start postgresql-17

echo "=== НАСТРОЙКА СИСТЕМЫ (ЯДРО) ==="
# Эти параметры критически важны для производительности БД
sudo tee -a /etc/sysctl.conf << EOF
# Параметры для PostgreSQL

# Позволяет использовать больше памяти для общих буферов
kernel.shmmax = 17179869184  # ~16 ГБ (для shared_buffers)
kernel.shmall = 4194304       # 16 ГБ / 4 КБ

# Управление памятью
vm.swappiness = 1              # Минимизируем использование swap
vm.dirty_background_ratio = 3  # Начинаем сброс "грязных" страниц раньше
vm.dirty_ratio = 10            # Максимальный процент "грязных" страниц
vm.overcommit_memory = 2       # Стратегия выделения памяти

# Сеть (увеличиваем буферы для высокой пропускной способности)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
EOF

sudo sysctl -p # Применяем настройки ядра

echo "=== НАСТРОЙКА ОГРАНИЧЕНИЙ (limits) для пользователя postgres ==="
sudo tee -a /etc/security/limits.conf << EOF
postgres soft nofile 65536
postgres hard nofile 65536
postgres soft nproc 131072
postgres hard nproc 131072
postgres soft memlock unlimited
postgres hard memlock unlimited
EOF

echo "=== ОПТИМИЗАЦИЯ ДИСКОВОЙ ПОДСИСТЕМЫ ==="
# Отключаем прозрачные огромные страницы (Transparent Huge Pages - THP).
# THH могут фрагментировать память и снижать производительность БД.
echo 'never' | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
# Делаем отключение постоянным
sudo tee -a /etc/rc.local << EOF
if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
EOF
sudo chmod +x /etc/rc.local

echo "=== НАСТРОЙКА PostgreSQL под 32 ГБ RAM ==="
PG_CONF="/var/lib/pgsql/17/data/postgresql.conf"

# Резервное копирование оригинального конфига
sudo -u postgres cp $PG_CONF ${PG_CONF}.backup

# Очищаем файл и записываем новые настройки
sudo -u postgres tee $PG_CONF << EOF
# -----------------------------
# ПОДКЛЮЧЕНИЯ И АУТЕНТИФИКАЦИЯ
# -----------------------------
listen_addresses = '*'
port = 5432
max_connections = 300

# -----------------------------
# РЕСУРСЫ (ПАМЯТЬ) - 32 ГБ RAM
# -----------------------------
shared_buffers = 8GB           # 25% от RAM
huge_pages = try
work_mem = 64MB                 # Увеличено для сложных сортировок
maintenance_work_mem = 2GB      # Для VACUUM, CREATE INDEX
effective_cache_size = 24GB      # 75% от RAM

# -----------------------------
# WAL (ЖУРНАЛ ПРЕДЗАПИСИ)
# -----------------------------
wal_level = replica
fsync = on
synchronous_commit = off        # Увеличивает скорость на риск потери данных при сбое ОС. Для максимальной надежности - on
wal_sync_method = fsync
full_page_writes = on
wal_buffers = 16MB
wal_writer_delay = 200ms
wal_writer_flush_after = 1MB
checkpoint_timeout = 15min
max_wal_size = 64GB             # Под большие нагрузки
min_wal_size = 16GB
checkpoint_completion_target = 0.9

# -----------------------------
# ОПТИМИЗАТОР ЗАПРОСОВ
# -----------------------------
random_page_cost = 1.1          # Для SSD дисков (1.0 для NVMe)
effective_io_concurrency = 300   # Для SSD
default_statistics_target = 500

# -----------------------------
# ПАРАЛЛЕЛЬНЫЕ ЗАПРОСЫ
# -----------------------------
max_worker_processes = 16
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
parallel_leader_participation = on

# -----------------------------
# АВТОВАКУУМ
# -----------------------------
autovacuum = on
autovacuum_max_workers = 5
autovacuum_naptime = 30s
autovacuum_vacuum_scale_factor = 0.05
autovacuum_vacuum_threshold = 500
autovacuum_analyze_scale_factor = 0.02
autovacuum_analyze_threshold = 250
autovacuum_vacuum_cost_delay = 5ms
autovacuum_vacuum_cost_limit = 1000
EOF

echo "=== НАСТРОЙКА ПРАВ ДОСТУПА (pg_hba.conf) для подключений ==="
# Будьте осторожны с этой настройкой! Это пример для доверительной сети.
# Для продакшена используйте шифрование (md5/scram-sha-256) и ограничьте IP-адреса.
PG_HBA="/var/lib/pgsql/17/data/pg_hba.conf"
sudo -u postgres cp $PG_HBA ${PG_HBA}.backup

# Разрешаем подключения с доверенных сетей (замените 192.168.1.0/24 на вашу подсеть в Яндекс.Облаке)
sudo -u postgres tee -a $PG_HBA << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
host    all             all             192.168.0.0/16          md5
host    replication     all             192.168.0.0/16          md5
EOF

echo "=== ПЕРЕЗАПУСК PostgreSQL ДЛЯ ПРИМЕНЕНИЯ НАСТРОЕК ==="
sudo systemctl restart postgresql-17
sudo systemctl status postgresql-17

echo "=== УСТАНОВКА ДОПОЛНИТЕЛЬНЫХ ИНСТРУМЕНТОВ (опционально) ==="
# pg_stat_statements для мониторинга
sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

echo "=== ГОТОВО! ==="
echo "PostgreSQL 17 установлен и настроен для максимальной производительности."
echo "Не забудьте настроить файрвол (firewalld) и сменить пароль пользователя postgres:"
echo "sudo -u postgres psql -c \"ALTER USER postgres PASSWORD 'Новый_Сложный_Пароль';\""
