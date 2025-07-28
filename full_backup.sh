#!/bin/bash
# Явно указываем пути к бинарникам
PSQL_PATH=/usr/local/greenplum-db/bin/psql
PGBACKREST_PATH=/usr/local/bin/pgbackrest
LOG_FILE="/home/gpadmin/backup_scripts/restore_points.log"
export PGOPTIONS="-c gp_session_role=utility"
source ~/.bashrc

# Выполнение полного бэкапа
for i in -1 0 1 2; do
    PGOPTIONS="-c gp_session_role=utility" $PGBACKREST_PATH --stanza=gpseg$i --type=full backup
done

# Создание и логирование точки восстановления
timestamp=$(date +%Y%m%d%H%M%S)
restore_point="backup_full_${timestamp}"

# Явное указание параметров подключения для psql
$PSQL_PATH -h mdw -U gpadmin -d postgres -c "SELECT gp_create_restore_point('${restore_point}');" && \
echo "$(date '+%Y-%m-%d %H:%M:%S') | FULL | ${restore_point}" >> $LOG_FILE
