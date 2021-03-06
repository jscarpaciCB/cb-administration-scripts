#! /bin/bash

install_master() {
    _conn=$1
    echo
    color_echo "-------- CB Server is NOT installed" "1;33"
    color_echo "-------- Installing CB Server"
    Cluster=0
    shards=
    nodes=
    IFS="="
    while read -r name value
    do
        if [ "$name" == "[Cluster]" ]; then
            Cluster=1
        fi
        if [ $Cluster == 1 ] && [ $name == "NodeCount" ]; then
            nodes=$value
        fi
        if [ $Cluster == 1 ] && [ $name == "ShardCount" ]; then
            shards=$value
            break
        fi
    done < $LOCAL_BACKUP_DIR/cluster.conf

    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbyum.tar"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbcerts.tar"
    remote_exec $_conn "yum -y install cb-enterprise"
    color_echo "-------- Initializing CB Server"
    color_echo "-------- Using ShardCount=[\e[0m$shards\e[1;32m] from the backup config"
    remote_exec $_conn "/usr/share/cb/cbinit --proc-store-shards=$shards" 1
    remote_exec $_conn "service cb-enterprise stop"

    # Start the cluster if in the cluster mode
    if [ $ClusterMembership == "Master" ]
    then
        color_echo "-------- Starting and Stopping a standalone cluster for initialization"
        remote_exec $_conn "/usr/share/cb/cbcluster start"
        remote_exec $_conn "/usr/share/cb/cbcluster stop"
    fi
    unset IFS
}

copy_backup_to_remote () {
    _conn=$1
    color_echo "-------- Copying backup files to the remote machine"
    remote_exec $_conn "mkdir -p $REMOTE_RESTORE_DIR"
    remote_copy $_conn "$LOCAL_BACKUP_DIR/*" "$REMOTE_RESTORE_DIR" 0 -r
    _ret_code=$?
    return $_ret_code
}

extract_backup (){
    _conn=$1

    color_echo "-------- Extracting backup files on the remote machine"
    color_echo "-------- Removing known_hosts"
    remote_exec $_conn "rm -rf /root/.ssh/known_hosts"
    color_echo "-------- Extracting hosts file"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbhosts.tar"
    color_echo "-------- Extracting iptables file"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbiptables.tar"
    color_echo "-------- Extracting /etc/ssh folder"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbssh.tar"
    color_echo "-------- Extracting /etc/yum.repos.d/ folder"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbyum.tar"
    color_echo "-------- Extracting /etc/cb/ folder"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbconfig.tar"
    color_echo "-------- Extracting rsyslog.conf file"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrsyslog.tar"
    color_echo "-------- Extracting /etc/rsyslog.d/ folder"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrsyslogd.tar"
    color_echo "-------- Extracting /etc/logrotate.d/cb folder"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cblogrotate.tar"
    color_echo "-------- Removing rabbitmq data folder"
    remote_exec $_conn "rm -rf $RabbitMQDataPath"
    color_echo "-------- Extracting /usr/share/cb/syslog_templates"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbceftemp.tar"
    color_echo "-------- Extracting .erlang.cookie file"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrabbitmqcookie.tar"
    color_echo "-------- Extracting /usr/share/cb/coreservices/installers/"
    remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbinstallers.tar"

    if [ $( remote_exec_get_output $_conn "test -e $REMOTE_RESTORE_DIR/cbrootauthkeys.tar && echo 1 || echo 0" ) == 1 ]
    then
        color_echo "-------- Extracting /user/.ssh/authorized_keys"
        remote_exec $_conn "tar -P -xf $REMOTE_RESTORE_DIR/cbrootauthkeys.tar"
    fi

    color_echo "-------- Extracting custom syslog templates"
    remote_exec $_conn "find $REMOTE_RESTORE_DIR -type f -iname \"syslog_custom*.tar\" -print0 | while IFS= read -r -d $'\0' line; do tar -P -xvf $line; done"
}

re_init_db () {
    _conn=$1
    color_echo "-------- Reinitializing database configs on the remote server"

    insert_command=$(printf '%q' "INSERT INTO investigations VALUES ('1','Default Investigation',to_timestamp((select value from cb_settings where key='ServerInstallTime'),'YYYY-MM-DD hh24:mi:ss'),NULL,to_timestamp((select value from cb_settings where key='ServerInstallTime'),'YYYY-MM-DD hh24:mi:ss'),'Automatically Created at Installation Time');")
    delete_command=$(printf '%q' "delete from watchlist_entries where group_id <> '-1';")
    update_command=$(printf '%q' "update cb_settings SET value = NULL where key like 'EventPurgeEarliestTime%';")
    generate_psqlvalues
    remote_copy $_conn "$LOCAL_BACKUP_DIR/psqlcbvalues" "$REMOTE_RESTORE_DIR" 0

    remote_exec $_conn "service cb-pgsql start"

    remote_exec $_conn "dropdb cb -p 5002"
    remote_exec $_conn "psql template1 -p 5002 -f $REMOTE_RESTORE_DIR/psqlroles.sql >/dev/null"
    remote_exec $_conn "psql template1 -p 5002 -f $REMOTE_RESTORE_DIR/psqldump.sql >/dev/null"
    remote_exec $_conn "psql cb -p 5002 -f $REMOTE_RESTORE_DIR/psqlcbvalues >/dev/null"
    remote_exec $_conn "psql cb -p 5002 -c $insert_command >/dev/null"
    remote_exec $_conn "psql cb -p 5002 -c $delete_command >/dev/null"
    remote_exec $_conn "psql cb -p 5002 -c $update_command >/dev/null"

    remote_exec $_conn "service cb-pgsql stop"
}

generate_psqlvalues () {
cat <<EOT >> $LOCAL_BACKUP_DIR/psqlcbvalues
    SELECT pg_catalog.setval('allianceclient_comm_history_id_seq', 1, false);
    SELECT pg_catalog.setval('allianceclient_pending_uploads_id_seq', 1, false);
    SELECT pg_catalog.setval('allianceclient_uploads_id_seq', 1, false);
    SELECT pg_catalog.setval('cb_useractivity_id_seq', 1, false);
    SELECT pg_catalog.setval('detect_dashboard_average_alert_resolution_history_id_seq', 1, false);
    SELECT pg_catalog.setval('detect_dashboard_binary_dwell_history_id_seq', 1, false);
    SELECT pg_catalog.setval('detect_dashboard_host_hygiene_history_id_seq', 1, false);
    SELECT pg_catalog.setval('investigations_id_seq', 1, false);
    SELECT pg_catalog.setval('maintenance_job_history_id_seq', 1, false);
    SELECT pg_catalog.setval('moduleinfo_events_id_seq', 1, false);
    SELECT pg_catalog.setval('sensor_activity_id_seq', 1, false);
    SELECT pg_catalog.setval('sensor_comm_failures_id_seq', 1, false);
    SELECT pg_catalog.setval('sensor_driver_diagnostics_id_seq', 1, false);
    SELECT pg_catalog.setval('sensor_event_diagnostics_id_seq', 1, false);
    SELECT pg_catalog.setval('sensor_licensing_counts_id_seq', 1, false);
    SELECT pg_catalog.setval('sensor_queued_data_stats_id_seq', 1, false);
    SELECT pg_catalog.setval('sensor_resource_statuses_id_seq', 1, false);
    SELECT pg_catalog.setval('server_storage_stats_id_seq', 1, false);
    SELECT pg_catalog.setval('tagged_events_id_seq', 1, false);
EOT
}

update_all_slaves_with_new_master () {
    old_master=$1
    new_master=$2
    slave_key=$3

    OLD_IP=$( resolve_hostname $old_master )
    NEW_IP=$( resolve_hostname $new_master )

    parse_all_slaves_from_config $LOCAL_BACKUP_DIR

    for _slave_node in "${_slave_nodes[@]}"
    do
        slave_host=$( get_tail_element $_slave_node '|' 1 )
        slave_user=$( get_tail_element $_slave_node '|' 2 )
        _slave_name=$( get_tail_element $_slave_node '|' 3 )

        color_echo "--------------------------------------------------------------------------------------"
        color_echo "Updating $_slave_name [\e[0m$slave_host\e[1;32m]"
        color_echo "--------------------------------------------------------------------------------------"


        open_ssh_tunnel $slave_user $slave_host $slave_key
        if [ $? == 0 ];
        then
            remote_exec $last_conn "service cb-enterprise stop > /dev/null"
            if [ "$_slave_user" == "root" ]; then
                remote_exec $last_conn "ps aux | grep rabbit | grep erlang | grep cb | awk '{print \$2}' | xargs kill -9"
            else
                _process_id=$( remote_exec_get_output $last_conn "ps aux | grep \"[r]abbit\" | grep erlang | grep cb | awk '{print \$2}'" )
                if [ ! -z "$_process_id" ]; then
                    remote_exec $last_conn "kill -9 $_process_id > /dev/null"
                fi
            fi

            remote_exec $last_conn "ps aux | grep rabbit | grep erlang | grep cb | awk '{print \$2}' | xargs kill -9"

            color_echo "-------- Updating cb.conf"
            remote_exec $last_conn "sed -r -i 's/RedisHost=.*/RedisHost=$new_master/g' /etc/cb/cb.conf"
            remote_exec $last_conn "sed -r -i 's/DatabaseURL\=(.*\@).*(:.*)/DatabaseURL=\1$new_master\2/g' /etc/cb/cb.conf"
            remote_exec $last_conn "sed -i 's/$OLD_IP/$NEW_IP/g' /etc/cb/cb.conf"

            color_echo "-------- Copying cluster.conf"
            remote_copy $last_conn "$LOCAL_BACKUP_DIR/cluster.conf" "/etc/cb/" 0

            color_echo "-------- Updating iptables"
            remote_exec $last_conn "service iptables stop > /dev/null"
            remote_exec $last_conn "sed -i 's/$OLD_IP/$NEW_IP/g' /etc/sysconfig/iptables"
            remote_exec $last_conn "service iptables start"

            color_echo "-------- Updating hosts file"
            update_host_file $old_master $OLD_IP $new_master $NEW_IP $last_conn $SAVE_HOSTS

            color_echo "-------- Removing rabbitmq data path"
            remote_exec $last_conn "rm -rf $RabbitMQDataPath"

            color_echo "-------- Copying rabbitmq cookie"
            remote_copy $last_conn "$LOCAL_BACKUP_DIR/.erlang.cookie" "/var/cb/" 0

            close_ssh_tunnel $last_conn
        else
            color_echo "-------- Could not connect to the $slave_host minion ------" "1;33"
            color_echo "-------- Skipping"
        fi
    done
}

udpate_remote_server () {
    _conn=$1
    old_master=$2
    new_master=$3

    if [ ! -z "$NODE_URL_HOST" ];
    then
        new_master_node=$NODE_URL_HOST
    else
        new_master_node=$new_master
    fi

    rm -rf $LOCAL_BACKUP_DIR/cbupdate.py
    cat <<EOF >> $LOCAL_BACKUP_DIR/cbupdate.py
from cb.utils.db import db_session_context
from cb.db.core_models import SensorGroup, ClusterNodeSensorAddress
from cb.utils.config import Config
import re

config = Config()
config.load('/etc/cb/cb.conf')

with db_session_context(config) as db:
    node = db.query(ClusterNodeSensorAddress).get(0)
    node.address="$new_master_node"
    sg = db.query(SensorGroup).get(1)
    sg.sensorbackend_server=re.sub("$old_master", "$new_master_node", sg.sensorbackend_server)
    db.commit()
EOF
    remote_copy $_conn "$LOCAL_BACKUP_DIR/cbupdate.py" "$REMOTE_RESTORE_DIR" 0

    OLD_IP=$( resolve_hostname $old_master )
    NEW_IP=$( resolve_hostname $new_master )

    color_echo "-------- Updating hosts file"
    update_host_file $old_master $OLD_IP $new_master $NEW_IP $_conn $SAVE_HOSTS

    color_echo "-------- Updating cb.conf"
    remote_exec $_conn "sed -i 's/$OLD_IP/$NEW_IP/g' /etc/cb/cb.conf"

    color_echo "-------- Updating cluster.conf"
    remote_exec $_conn "sed -i 's/$old_master\$/$new_master/g' /etc/cb/cluster.conf"
    remote_exec $_conn "sed -i 's/$OLD_IP/$new_master/g' /etc/cb/cluster.conf"

    color_echo "-------- Updating iptables"
    remote_exec $_conn "sed -i 's/$OLD_IP/$NEW_IP/g' /etc/sysconfig/iptables"

    color_echo "-------- Updating master records in the db"
    remote_exec $_conn "service cb-pgsql start"
    remote_exec $_conn "python $REMOTE_RESTORE_DIR/cbupdate.py"
    remote_exec $_conn "service cb-pgsql stop"

}

remove_shards () {
    _conn=$1

    color_echo "-------- Cleaning old shards on the new master"
    # Getting shards info from backup config
    ret_val=$(read_cluster_config 'Master')
    shards=$(get_tail_element "$ret_val" '|' 1)
    shards=$(sed -r 's/shards(=|\s)//g' <<< "$shards")
    shards=$(sed 's/\s//g' <<< $shards)

    find=""
    # Building command line for find with "! iname = shard" filters
    IFS=',' read -ra arr <<< "$shards"
    for i in "${arr[@]}"; do
        find=$find" ! -iname $i"
    done

    find=$find" ! -iname conf"

    # Removing all shards that are not configured to be on the new master
    remote_exec $_conn "find $DatastoreRootDir/solr/cbevents -mindepth 1 -maxdepth 1 $find -exec rm -rf {} \;"
}