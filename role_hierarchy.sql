WITH RECURSIVE cte AS (
   SELECT oid, 0 AS steps, true AS inherit_option
   FROM   pg_roles
   WHERE  rolname = 'maxwell'

   UNION ALL
   SELECT m.roleid, c.steps + 1, c.inherit_option AND m.inherit_option
   FROM   cte c
   JOIN   pg_auth_members m ON m.member = c.oid
   )
SELECT oid, oid::regrole::text AS rolename, steps, inherit_option
FROM   cte;
