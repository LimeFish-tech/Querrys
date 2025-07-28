#!/bin/bash
PSQL_PATH=/usr/local/greenplum-db/bin/psql
PGBACKREST_PATH=/usr/local/bin/pgbackrest
LOG_FILE="/home/gpadmin/backup_scripts/restore_points.log"
source ~/.bashrc

# Выполнение инкрементального бэкапа
for i in -1 0 1 2; do
    PGOPTIONS="-c gp_session_role=utility" $PGBACKREST_PATH --stanza=gpseg$i --type=incr backup
done

# Создание и логирование точки восстановления
timestamp=$(date +%Y%m%d%H%M%S)
restore_point="backup_incr_${timestamp}"

$PSQL_PATH -h mdw -U gpadmin -d postgres -c "SELECT gp_create_restore_point('${restore_point}');" && \
echo "$(date '+%Y-%m-%d %H:%M:%S') | INCR | ${restore_point}" >> $LOG_FILE
