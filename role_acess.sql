WITH RECURSIVE
-- 1. Укажите схему для анализа здесь
target_schema AS (
    SELECT oid, nspname, nspowner
    FROM pg_namespace
    WHERE nspname = 'public'  -- ⬅️ ИЗМЕНИТЕ НА НУЖНУЮ СХЕМУ
),
-- 2. Прямые права на схему из ACL
direct_schema_privs AS (
    SELECT
        ts.nspname AS schema_name,
        priv.privilege_type,
        priv.grantee::regrole AS granted_to_role,
        priv.is_grantable,
        priv.grantor::regrole AS granted_by
    FROM target_schema ts
    CROSS JOIN LATERAL aclexplode(ts.nspacl) AS priv
    WHERE ts.nspacl IS NOT NULL
    UNION ALL
    -- Добавляем владельца схемы как супер-пользователя
    SELECT
        ts.nspname,
        'ALL' AS privilege_type,
        ts.nspowner::regrole AS granted_to_role,
        true AS is_grantable,
        NULL::regrole AS granted_by
    FROM target_schema ts
),
-- 3. Рекурсивно собираем иерархию ролей (кто кого включает)
role_hierarchy AS (
    -- Базовый случай: все роли, которым выданы прямые права на схему
    SELECT
        dsp.granted_to_role AS role_name,
        dsp.granted_to_role AS inherited_via,
        0 AS depth,
        dsp.privilege_type,
        dsp.is_grantable,
        dsp.granted_by,
        dsp.schema_name
    FROM direct_schema_privs dsp
    
    UNION ALL
    
    -- Рекурсивный случай: находим всех, кто наследует эти роли
    SELECT
        rm.member::regrole AS role_name,
        rh.role_name AS inherited_via,
        rh.depth + 1 AS depth,
        rh.privilege_type,
        rh.is_grantable,
        rh.granted_by,
        rh.schema_name
    FROM role_hierarchy rh
    JOIN pg_auth_members am ON am.roleid = rh.role_name::regrole::oid
    JOIN pg_roles rm ON rm.oid = am.member
),
-- 4. Агрегируем итоговые права для каждой роли
final_privileges AS (
    SELECT DISTINCT
        schema_name,
        role_name,
        privilege_type,
        CASE
            WHEN MIN(depth) = 0 THEN 'Direct'
            ELSE 'Inherited via ' || MIN(inherited_via) 
                || ' (levels: ' || MIN(depth) || ')'
        END AS grant_source,
        BOOL_OR(is_grantable) AS can_grant,
        MAX(granted_by) AS original_grantor
    FROM role_hierarchy
    GROUP BY schema_name, role_name, privilege_type
)
-- 5. Форматируем результат
SELECT
    schema_name AS "Схема",
    role_name AS "Роль",
    privilege_type AS "Тип права",
    grant_source AS "Источник права",
    CASE WHEN can_grant THEN 'YES' ELSE 'NO' END AS "Может передавать",
    original_grantor AS "Выдавший роль"
FROM final_privileges
ORDER BY 
    schema_name,
    role_name,
    privilege_type,
    grant_source;
