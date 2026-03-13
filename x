systemctl stop firewalld.service;
systemctl disable firewalld.service;

VI /etc/selinux/config

mv 
cp /home/gpadmin/pgbackrest /usr/local/bin/ ;chown gpadmin:gpadmin /usr/local/bin/pgbackrest; chmod 750 /usr/local/bin/pgbackrest
dnf config-manager --set-enabled powertools;
dnf install epel-release -y;
dnf config-manager --set-enabled epel-release;
yum install git gcc openssl-devel libxml2-devel bzip2-devel libzstd-devel lz4-devel libyaml-devel zlib-devel libssh2-devel -y

yum install libssh2-devel

--для хранилища
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-8-x86_64/pgdg-redhat-repo-latest.noarch.rpm;
dnf config-manager --enable pgdg13;
dnf install libpq -y

mkdir -p /etc/pgbackrest/ ; touch /etc/pgbackrest/pgbackrest.conf; chown -R gpadmin:gpadmin /etc/pgbackrest/ ;chmod 750 /etc/pgbackrest/pgbackrest.conf

mkdir -p /backup_storage/local/pgbackrest/
mkdir -p /backup_storage/config/
chown -R gpadmin:gpadmin /backup_storage/


mkdir -p /etc/greenplum_disaster_recovery/; touch /etc/greenplum_disaster_recovery/project_config_same_site.toml ; chown -R gpadmin:gpadmin /etc/greenplum_disaster_recovery/

do_gpdr -project-config=/etc/greenplum_disaster_recovery/project_config_same_site.toml configure-backup


process_max=3
user="gpadmin"
port=5432
host="mdw1"
repo_path="/backup_storage/local/pgbackrest/"
restore_repo_path="/backup_storage/local/pgbackrest/"
config_path="/etc/pgbackrest/"
log_level="info"
backup_sleep=0
repo_retention_full=2
restore_config="greenplum_cluster.conf"

[segments.-1]
user="gpadmin"
hostname="mdw1"
directory="/data/master/gpseg-1"
repo_host="stg"
repo_host_user="gpadmin"

[segments.0]
user="gpadmin"
hostname="sdw1"
directory="/data/primary/gpseg0"
repo_host="stg"

[segments.1]
user="gpadmin"
hostname="sdw1"
directory="/data/primary/gpseg1"
repo_host="stg"

[segments.2]
user="gpadmin"
hostname="sdw2"
directory="/data/primary/gpseg2"
repo_host="stg"

[segments.3]
user="gpadmin"
hostname="sdw2"
directory="/data/primary/gpseg3"
repo_host="stg"



vi
process_max=3
user="gpadmin"
port=5432
host="mdw1"
repo_path="/backup_storage/local/pgbackrest/"
config_path="/etc/pgbackrest/"
log_level="info"
backup_sleep=0
restore_config="greenplum_cluster.conf"

[segments.-1]
host="mdw1"
repo_path="/data/master/gpseg-1"

[segments.0]
host="sdw1"
repo_path="/data/primary/gpseg0"

[segments.1]
host="sdw1"
repo_path="/data/primary/gpseg1"
