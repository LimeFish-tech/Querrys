#!/bin/bash
# process_table_sizes.sh
# Обработка собранных данных о размерах таблиц: разделение на партиции и непартицированные,
# вычисление дельт между последним и предыдущим сбором.

set -e

# Параметры подключения (можно переопределить через переменные окружения)
: ${PGHOST:=localhost}
: ${PGPORT:=5432}
: ${PGDATABASE:=your_db}
: ${PGUSER:=your_user}
export PGPASSWORD="${PGPASSWORD:-your_password}"  # лучше использовать .pgpass

# Функция для выполнения SQL (вывод без форматирования, останов при ошибке)
exec_psql() {
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -Atc "$1"
}

echo "=== Создание схемы dbatools (если не существует) ==="
exec_psql "CREATE SCHEMA IF NOT EXISTS dbatools;"

echo "=== Создание таблиц и функции (если не существуют) ==="
exec_psql "
-- Таблица для истории партиций
CREATE TABLE IF NOT EXISTS dbatools.partition_sizes_history (
    collection_time timestamptz,
    schema_oid      oid,
    schema_name     name,
    parent_relname  name,
    partition_name  name,
    partition_oid   oid,
    byte_size       numeric,
    readable_size   text
);
CREATE INDEX IF NOT EXISTS idx_partition_sizes_history_time ON dbatools.partition_sizes_history (collection_time);
CREATE INDEX IF NOT EXISTS idx_partition_sizes_history_parent ON dbatools.partition_sizes_history (parent_relname, partition_name);

-- Таблица для дельт партиций
CREATE TABLE IF NOT EXISTS dbatools.partition_deltas (
    delta_time           timestamptz,
    schema_oid           oid,
    schema_name          name,
    parent_relname       name,
    partition_name       name,
    previous_byte_size   numeric,
    current_byte_size    numeric,
    byte_size_delta      numeric,
    previous_readable_size text,
    current_readable_size text,
    delta_period         interval
);
CREATE INDEX IF NOT EXISTS idx_partition_deltas_time ON dbatools.partition_deltas (delta_time);

-- Таблица для истории непартицированных таблиц
CREATE TABLE IF NOT EXISTS dbatools.non_partitioned_sizes_history (
    collection_time timestamptz,
    schema_oid      oid,
    schema_name     name,
    relname         name,
    reloid          oid,
    byte_size       numeric,
    readable_size   text
);
CREATE INDEX IF NOT EXISTS idx_nonpart_sizes_history_time ON dbatools.non_partitioned_sizes_history (collection_time);
CREATE INDEX IF NOT EXISTS idx_nonpart_sizes_history_rel ON dbatools.non_partitioned_sizes_history (relname);

-- Таблица для дельт непартицированных таблиц
CREATE TABLE IF NOT EXISTS dbatools.non_partitioned_deltas (
    delta_time           timestamptz,
    schema_oid           oid,
    schema_name          name,
    relname              name,
    previous_byte_size   numeric,
    current_byte_size    numeric,
    byte_size_delta      numeric,
    previous_readable_size text,
    current_readable_size text,
    delta_period         interval
);
CREATE INDEX IF NOT EXISTS idx_nonpart_deltas_time ON dbatools.non_partitioned_deltas (delta_time);
"

# Определяем последнее время сбора
current_time=$(exec_psql "SELECT MAX(collection_time) FROM dbatools.table_sizes_heap;")
if [[ -z "$current_time" || "$current_time" == "NULL" ]]; then
    echo "Ошибка: нет данных в dbatools.table_sizes_heap."
    exit 1
fi
echo "Последнее время сбора: $current_time"

# Проверяем, не обработаны ли уже эти данные (по наличию записей в partition_sizes_history)
already=$(exec_psql "SELECT 1 FROM dbatools.partition_sizes_history WHERE collection_time = '$current_time' LIMIT 1;")
if [[ -n "$already" ]]; then
    echo "Данные за это время уже обработаны. Выход."
    exit 0
fi

echo "=== Заполнение partition_sizes_history (партиции) ==="
exec_psql "
INSERT INTO dbatools.partition_sizes_history (collection_time, schema_oid, schema_name, parent_relname, partition_name, partition_oid, byte_size, readable_size)
SELECT
    s.collection_time,
    s.relnamespace,
    n.nspname AS schema_name,
    parent.relname AS parent_relname,
    c.relname AS partition_name,
    c.oid AS partition_oid,
    s.byte_size,
    s.readable_size
FROM dbatools.table_sizes_heap s
JOIN pg_class c ON c.relnamespace = s.relnamespace AND c.relname = s.relname
JOIN pg_namespace n ON n.oid = s.relnamespace
JOIN pg_inherits i ON i.inhrelid = c.oid   -- таблица является партицией (наследником)
JOIN pg_class parent ON parent.oid = i.inhparent   -- родительская таблица
WHERE s.collection_time = '$current_time';
"

echo "=== Заполнение non_partitioned_sizes_history (остальные таблицы) ==="
exec_psql "
INSERT INTO dbatools.non_partitioned_sizes_history (collection_time, schema_oid, schema_name, relname, reloid, byte_size, readable_size)
SELECT
    s.collection_time,
    s.relnamespace,
    n.nspname,
    s.relname,
    c.oid,
    s.byte_size,
    s.readable_size
FROM dbatools.table_sizes_heap s
JOIN pg_class c ON c.relnamespace = s.relnamespace AND c.relname = s.relname
JOIN pg_namespace n ON n.oid = s.relnamespace
LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
WHERE s.collection_time = '$current_time'
  AND i.inhrelid IS NULL;   -- исключаем партиции
"

echo "=== Вычисление дельт для непартицированных таблиц ==="
exec_psql "
INSERT INTO dbatools.non_partitioned_deltas (delta_time, schema_oid, schema_name, relname,
    previous_byte_size, current_byte_size, byte_size_delta,
    previous_readable_size, current_readable_size, delta_period)
WITH current AS (
    SELECT collection_time, schema_oid, schema_name, relname, byte_size, readable_size
    FROM dbatools.non_partitioned_sizes_history
    WHERE collection_time = '$current_time'
),
previous AS (
    SELECT collection_time, schema_oid, schema_name, relname, byte_size, readable_size
    FROM dbatools.non_partitioned_sizes_history
    WHERE collection_time = (
        SELECT MAX(collection_time)
        FROM dbatools.non_partitioned_sizes_history
        WHERE collection_time < '$current_time'
    )
)
SELECT
    current.collection_time AS delta_time,
    COALESCE(current.schema_oid, previous.schema_oid),
    COALESCE(current.schema_name, previous.schema_name),
    COALESCE(current.relname, previous.relname),
    previous.byte_size,
    current.byte_size,
    COALESCE(current.byte_size, 0) - COALESCE(previous.byte_size, 0),
    previous.readable_size,
    current.readable_size,
    current.collection_time - previous.collection_time
FROM current
FULL JOIN previous ON current.schema_oid = previous.schema_oid AND current.relname = previous.relname
WHERE current.relname IS NOT NULL OR previous.relname IS NOT NULL;
"

echo "=== Вычисление дельт для партиций ==="
exec_psql "
INSERT INTO dbatools.partition_deltas (delta_time, schema_oid, schema_name, parent_relname, partition_name,
    previous_byte_size, current_byte_size, byte_size_delta,
    previous_readable_size, current_readable_size, delta_period)
WITH current AS (
    SELECT collection_time, schema_oid, schema_name, parent_relname, partition_name, byte_size, readable_size
    FROM dbatools.partition_sizes_history
    WHERE collection_time = '$current_time'
),
previous AS (
    SELECT collection_time, schema_oid, schema_name, parent_relname, partition_name, byte_size, readable_size
    FROM dbatools.partition_sizes_history
    WHERE collection_time = (
        SELECT MAX(collection_time)
        FROM dbatools.partition_sizes_history
        WHERE collection_time < '$current_time'
    )
)
SELECT
    current.collection_time AS delta_time,
    COALESCE(current.schema_oid, previous.schema_oid),
    COALESCE(current.schema_name, previous.schema_name),
    COALESCE(current.parent_relname, previous.parent_relname),
    COALESCE(current.partition_name, previous.partition_name),
    previous.byte_size,
    current.byte_size,
    COALESCE(current.byte_size, 0) - COALESCE(previous.byte_size, 0),
    previous.readable_size,
    current.readable_size,
    current.collection_time - previous.collection_time
FROM current
FULL JOIN previous ON current.schema_oid = previous.schema_oid
                  AND current.parent_relname = previous.parent_relname
                  AND current.partition_name = previous.partition_name
WHERE current.partition_name IS NOT NULL OR previous.partition_name IS NOT NULL;
"

echo "=== Обработка завершена ==="
