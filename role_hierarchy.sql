WITH RECURSIVE members AS (
    SELECT oid, rolname
    FROM pg_roles
    WHERE rolname = 'readers'

    UNION ALL

    SELECT r.oid, r.rolname
    FROM members m
    JOIN pg_auth_members a ON a.roleid = m.oid
    JOIN pg_roles r ON a.member = r.oid
)
SELECT rolname FROM members WHERE oid <> (SELECT oid FROM pg_roles WHERE rolname = 'readers');
