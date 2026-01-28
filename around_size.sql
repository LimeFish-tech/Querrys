-- Фаза 1: Подготовка временной таблицы с фильтрацией
CREATE TEMP TABLE filtered_tables AS
WITH table_list AS (
    SELECT 
        c.oid,
        n.nspname AS schema_name,
        c.relname AS table_name,
        c.relkind,
        c.relam,
        c.relispartition AS is_partition,
        c.relhassubclass AS has_partitions,
        CASE 
            WHEN am.amname IN ('heap', 'ao_row') THEN 'ROW'
            WHEN am.amname = 'ao_column' THEN 'COLUMN'
            ELSE 'OTHER'
        END AS storage_orientation
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    LEFT JOIN pg_am am ON c.relam = am.oid
    WHERE n.nspname IN ('x', 'y', 'z')  -- ваши схемы
        AND c.relkind IN ('r', 'p')  -- обычные и партиционированные таблицы
        AND NOT EXISTS (
            SELECT 1 FROM pg_foreign_table ft 
            WHERE ft.ftrelid = c.oid
        )
)
SELECT 
    *,
    CASE 
        WHEN has_partitions THEN 'PARTITIONED_TABLE'
        WHEN is_partition THEN 'PARTITION'
        ELSE 'ORDINARY_TABLE'
    END AS table_category
FROM table_list;

-- Фаза 2: Расчет размера строк для ROW-ориентированных таблиц
WITH column_analysis AS (
    SELECT 
        ft.oid,
        ft.schema_name,
        ft.table_name,
        ft.table_category,
        ft.storage_orientation,
        a.attnum,
        a.attname,
        t.typname,
        t.typlen,
        t.typalign,
        CASE t.typalign
            WHEN 'c' THEN 1  -- char
            WHEN 's' THEN 2  -- smallint
            WHEN 'i' THEN 4  -- int
            WHEN 'd' THEN 8  -- double
            ELSE 1
        END AS alignment_bytes,
        CASE 
            WHEN t.typlen = -1 THEN  -- переменная длина
                CASE 
                    WHEN t.typname IN ('text', 'varchar') THEN 'VARIABLE'
                    ELSE 'UNKNOWN'
                END
            ELSE 'FIXED'
        END AS length_type
    FROM filtered_tables ft
    JOIN pg_attribute a ON a.attrelid = ft.oid
    JOIN pg_type t ON a.atttypid = t.oid
    WHERE a.attnum > 0  -- исключаем системные атрибуты
        AND NOT a.attisdropped
        AND ft.storage_orientation = 'ROW'  -- только для ROW таблиц
    ORDER BY ft.oid, a.attnum
),
row_size_calculation AS (
    SELECT 
        oid,
        schema_name,
        table_name,
        table_category,
        storage_orientation,
        -- Расчет накопленного смещения с учетом выравнивания
        SUM(
            CASE 
                WHEN attnum = 1 THEN 0
                ELSE LAG(current_offset) OVER w
            END
        ) AS total_data_offset,
        -- Сумма размеров фиксированных столбцов
        SUM(CASE WHEN length_type = 'FIXED' THEN typlen ELSE 0 END) AS fixed_columns_size,
        -- Заголовок строки (24 байта + битмап null)
        24 + CEIL(COUNT(*)::float / 8) AS row_header_size,
        -- Максимальное требование выравнивания
        MAX(alignment_bytes) AS max_alignment_requirement
    FROM (
        SELECT 
            *,
            -- Текущее смещение с учетом выравнивания
            CASE 
                WHEN attnum = 1 THEN 
                    CASE 
                        WHEN alignment_bytes > 1 
                        THEN (alignment_bytes - 1) 
                        ELSE 0 
                    END
                ELSE 
                    CASE 
                        WHEN alignment_bytes > LAG(alignment_bytes) OVER (PARTITION BY oid ORDER BY attnum)
                        THEN (alignment_bytes - 1)
                        ELSE 0
                    END
            END AS current_offset
        FROM column_analysis
    ) AS with_offsets
    GROUP BY oid, schema_name, table_name, table_category, storage_orientation
    WINDOW w AS (PARTITION BY oid ORDER BY attnum)
)
SELECT 
    rsc.*,
    -- Итоговый размер строки с учетом заголовка и выравнивания
    CEIL(
        (row_header_size + total_data_offset + fixed_columns_size)::float / 
        max_alignment_requirement
    ) * max_alignment_requirement AS calculated_row_size_bytes,
    -- Расчет для COLUMN-ориентированных таблиц (отдельный подход)
    CASE 
        WHEN storage_orientation = 'COLUMN' THEN
            'Для COLUMN таблиц размер рассчитывается по статистике использования столбцов'
        ELSE NULL
    END AS column_table_note
FROM row_size_calculation rsc
ORDER BY schema_name, table_name;

-- Фаза 3: Дополнительная информация по партициям
SELECT 
    ft.schema_name,
    ft.table_name,
    ft.table_category,
    ft.storage_orientation,
    p.partitiontype,
    p.partitionlevel,
    COUNT(*) OVER (PARTITION BY ft.oid) as partition_count
FROM filtered_tables ft
LEFT JOIN pg_partitions p ON ft.table_name = p.tablename 
    AND ft.schema_name = p.schemaname
WHERE ft.table_category IN ('PARTITIONED_TABLE', 'PARTITION')
ORDER BY ft.schema_name, ft.table_name;