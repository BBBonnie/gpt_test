#!/bin/bash
#
#  script for common helpers that back up block data.
#
set -e
source /home/ubuntu/.infd/.env || true

LOG_PATH=/home/ubuntu/logs/syslog/backup.out
BACKUP_INTERVAL=12 # not allowed two backup in 12 hours
WRITE_LOCK_RETENION_TIME=12
INFD_API="http://127.0.0.1:12345"
S3PATH_PROTOCOL="s3://infstones-protocol"

function usage() {
    echo "
Usage: Backup data
    $(basename $0) data [Options]
[Options]:
    -f | --force_backup # Optional flag. If set, it will force backup data to the earliest S3 directory.
    -h | --help         # Help document.
    "
    exit 1
}

{
    while [[ $# -gt 0 ]]; do
        case $1 in
        -f | --force_backup)
            force_backup="true"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            exit 1
            ;;
        esac
    done

    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) [Begin]: Backing up data... \e[0m"

    data_type="regular"
    output=$(/opt/protocol/protocol_runner "$PROTOCOL_NAME" snapshot_exist | tr -d '\n')
    if [[ $output == "true" ]]; then
        data_type="snapshots"
    fi    
} >> $LOG_PATH 2>&1

function start_backup() {
    local node_data=$(curl -s $INFD_API/data)
    local node_status=$(jq -r '.data.node_status' <<< $node_data)
    
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Check write_lock... \e[0m"
    local write_lock=$(aws s3 ls $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/write_lock)
    local backup_path=""
    local current_time=$(date "+%s") 
    if [[ -z $write_lock ]]; then
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) No write_lock... \e[0m"
        local backup_dir=""
        if [[ -z $(aws s3 ls $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-2) ]]; then
            backup_dir="data-2"
        fi
        if [[ -z $(aws s3 ls $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-1) ]]; then
            backup_dir="data-1"
        fi
        if [[ -z $backup_dir ]]; then
            local latest_backup_timestamp=$(latest_backup_timestamp)
            if [[ $((($current_time - $latest_backup_timestamp) / 3600)) -lt $BACKUP_INTERVAL && $force_backup != "true" ]]; then
                echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The latest backup time is $(date -d @$latest_backup_timestamp), which is within $BACKUP_INTERVAL hours. \nIf you want to backup again, use \"curl -X POST 'http://localhost:12345/backup?force=true' &\". \nExited \e[0m"
                BACKUP_ERROR=1
                return
            fi
            local backup_dir_info_1=$(aws s3 cp $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-1/backup_metadata.json -)
            local backup_dir_info_2=$(aws s3 cp $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-2/backup_metadata.json -)
            local backup_node_id_1=$(echo $backup_dir_info_1 | jq -r ".\"$PROTOCOL_NAME\".NODE_ID")
            local backup_node_id_2=$(echo $backup_dir_info_2 | jq -r ".\"$PROTOCOL_NAME\".NODE_ID")
            local backup_timestamp_1=$(echo $backup_dir_info_1 | jq -r ".\"$PROTOCOL_NAME\".TIMESTAMP")
            local backup_timestamp_2=$(echo $backup_dir_info_2 | jq -r ".\"$PROTOCOL_NAME\".TIMESTAMP")
            local backup_human_readable_time_1=$(date -d @$backup_timestamp_1)
            local backup_human_readable_time_2=$(date -d @$backup_timestamp_2)
            local backup_public_ip_1=$(echo $backup_dir_info_1 | jq -r ".\"$PROTOCOL_NAME\".PUBLIC_IP")
            local backup_public_ip_2=$(echo $backup_dir_info_2 | jq -r ".\"$PROTOCOL_NAME\".PUBLIC_IP")
            local backup_email_1=$(echo $backup_dir_info_1 | jq -r ".\"$PROTOCOL_NAME\".EMAIL")
            local backup_email_2=$(echo $backup_dir_info_2 | jq -r ".\"$PROTOCOL_NAME\".EMAIL")
            local latest_dir="data-2"
            local latest_dir_node_id=$backup_node_id_2
            local earliest_dir="data-1"
            local earliest_dir_node_id=$backup_node_id_1
            if [[ $backup_timestamp_1 -gt $backup_timestamp_2 ]]; then
                latest_dir="data-1"
                latest_dir_node_id=$backup_node_id_1 
                earliest_dir="data-2"
                earliest_dir_node_id=$backup_node_id_2
            fi
            backup_dir=$earliest_dir
            if [[ $earliest_dir_node_id != $NODE_ID && $latest_dir_node_id != $NODE_ID ]]; then
                echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) No backup directory matches current node $NODE_ID. \e[0m"
                echo -e "\e[1;32m\n$S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-1 NODE_ID: $backup_node_id_1, PUBLIC_IP: $backup_public_ip_1, EMAIL: $backup_email_1, BACKUP_TIME: $backup_human_readable_time_1 \e[0m"
                echo -e "\e[1;32m$S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-2 NODE_ID: $backup_node_id_2, PUBLIC_IP: $backup_public_ip_2, EMAIL: $backup_email_2, BACKUP_TIME: $backup_human_readable_time_2 \e[0m"
                echo -e "\e[1;32mYou need to delete one of them first and do the backup again. Before deleting, please contact the data maintainer. \n\e[0m"
                echo -e "\e[1;32mIt is strongly recommended to use the following command to delete the earliest backup directory $earliest_dir. \e[0m"
                echo -e "\e[1;32m\"curl -X DELETE 'http://localhost:12345/backup?protocol=$PROTOCOL_NAME&data_type=$data_type&data_dir=$earliest_dir' &\" \n\nExited \e[0m"
                BACKUP_ERROR=1
                return
            fi
            if [[ $earliest_dir_node_id != $NODE_ID && $latest_dir_node_id == $NODE_ID ]]; then
                echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The current node $NODE_ID is trying to backup data into $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/$latest_dir, which has the latest backup data. Please note that the latest backup data could be in use by other launching nodes. Backup from this node is NOT allowed. \nExited \e[0m"
                BACKUP_ERROR=1
                return
            fi
        fi
        backup_path="$S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/$backup_dir"
    else 
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Found a write_lock... \e[0m"
        local write_lock_info=$(aws s3 cp $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/write_lock -)
        local write_lock_node_id=$(echo $write_lock_info | jq -r '.NODE_ID')
        local write_lock_directory=$(echo $write_lock_info | jq -r '.LOCK_DIRECTORY')
        local write_lock_cloud_provider=$(echo $write_lock_info | jq -r '.CLOUD_PROVIDER')
        local write_lock_deploy_env=$(echo $write_lock_info | jq -r '.DEPLOY_ENV')
        local write_lock_email=$(echo $write_lock_info | jq -r '.EMAIL')
        local write_lock_region=$(echo $write_lock_info | jq -r '.REGION')
        local write_lock_public_ip=$(echo $write_lock_info | jq -r '.PUBLIC_IP')
        local write_lock_time=$(aws s3 ls $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/write_lock | awk '{print $1 "T" $2}')
        local write_lock_timestamp=$(date "+%s" -d $write_lock_time)
        if [[ $((($current_time - $write_lock_timestamp) / 3600)) -lt $WRITE_LOCK_RETENION_TIME ]]; then
            echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The backup from node $write_lock_node_id to $write_lock_directory is currently in progress. \e[0m"
            echo -e "\e[1;32mNode $write_lock_node_id has the Public_IP: $write_lock_public_ip, Deploy_Env: $write_lock_deploy_env, Cloud_Provider: $write_lock_cloud_provider, Region: $write_lock_region, Email: $write_lock_email. \nExited\e[0m" 
            BACKUP_ERROR=1
            return
        fi
        if [[ $NODE_ID != $write_lock_node_id ]]; then
            echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The backup from node $write_lock_node_id failed in the middle. Node $write_lock_node_id has the Public_ip: $write_lock_public_ip, Deploy_env: $write_lock_deploy_env, Cloud_Provider: $write_lock_cloud_provider, Region: $write_lock_region, EMAIL: $write_lock_email. \e[0m"
            echo -e "\e[1;32m\nTo resolve this issue, you can either backup again from the node $write_lock_node_id. \e[0m"
            echo -e "\e[1;32mOr you can delete write_lock and the locked directory $write_lock_directory, and backup from the node directly. Run the following command to delete related files automatically. \e[0m"
            data_dir=$(echo $write_lock_directory | cut -d '/' -f7)
            echo -e "\e[1;32m\"curl -X DELETE 'http://localhost:12345/backup?protocol=$PROTOCOL_NAME&data_type=$data_type&data_dir=$data_dir' &\" \e[0m"
            echo -e "\e[1;32m\nBefore taking any action, you must contact $write_lock_email for advice. \n\nExited \e[0m"
            BACKUP_ERROR=1
            return
        fi
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Last backup by the current node $write_lock_node_id failed. Continue backup to $write_lock_directory \e[0m"
        aws s3 rm $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/write_lock --only-show-errors
        backup_path=$write_lock_directory
    fi

    local write_lock_info=$(cat <<-END
    {"CLOUD_PROVIDER": "$CLOUD_PROVIDER",
    "DEPLOY_ENV": "$DEPLOY_ENV",
    "PUBLIC_IP": "$(curl -s $INFD_API/data | jq -r '.data.public_ip')",
    "EMAIL": "$EMAIL",
    "REGION": "$REGION",
    "NODE_ID": "$NODE_ID",
    "LOCK_DIRECTORY": "$backup_path"}
END
)
    jq -r '.' <<< $write_lock_info > /tmp/write_lock
    aws s3 mv /tmp/write_lock $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/
    if [[ -n $(aws s3 ls ${backup_path%/*}/read_lock) ]]; then
        aws s3 cp ${backup_path%/*}/read_lock /tmp/read_lock
        if [[ $(jq ".\"$backup_path\" | length" /tmp/read_lock) -gt 0 ]]; then
            local latest_read_lock_info=$(jq ".\"$backup_path\" | sort_by(.TIMESTAMP) | reverse | .[0]" /tmp/read_lock)
            local latest_read_lock_node_id=$(echo $latest_read_lock_info | jq '.NODE_ID')
            local latest_read_lock_directory=$(echo $latest_read_lock_info | jq '.LOCK_DIRECTORY')
            local latest_read_lock_public_ip=$(echo $latest_read_lock_info | jq '.PUBLIC_IP')
            local latest_read_lock_deploy_env=$(echo $latest_read_lock_info | jq '.DEPLOY_ENV')
            local latest_read_lock_cloud_provider=$(echo $latest_read_lock_info | jq '.CLOUD_PROVIDER')
            local latest_read_lock_region=$(echo $latest_read_lock_info | jq '.REGION')
            local latest_read_lock_email=$(echo $latest_read_lock_info | jq '.EMAIL')
            local latest_read_lock_creation_time=$(echo $latest_read_lock_info | jq '.TIMESTAMP') # seconds
            local file_size=$(aws s3 cp $backup_path/backup_metadata.json - | jq -r ".\"$PROTOCOL_NAME\".FILE_SIZE") # bytes
            local download_speed=50000000 # bytes/s
            local read_lock_retention_time=$(($file_size / $download_speed)) # seconds
            local wait_time=$(($latest_read_lock_creation_time + $read_lock_retention_time - $current_time)) # seconds
            if [[ $wait_time -gt 0 ]]; then
                echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The bootstrap from node $latest_read_lock_node_id is currently downloading data from $latest_read_lock_directory. \e[0m"
                echo -e "\e[1;32mNode $latest_read_lock_node_id has the Public_IP: $latest_read_lock_public_ip, Deploy_Env: $latest_read_lock_deploy_env, Cloud_Provider: $latest_read_lock_cloud_provider, Region: $latest_read_lock_region, Email: $latest_read_lock_email. \e[0m" 
                echo -e "\e[1;32mWill backup to $latest_read_lock_directory $wait_time seconds later when the read lock is released. \e[0m"
                sleep $wait_time
            else
                echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The bootstrap from node $latest_read_lock_node_id has failed during downloading data from $latest_read_lock_directory. \e[0m"
                echo -e "\e[1;32mNode $latest_read_lock_node_id has the Public_IP: $latest_read_lock_public_ip, Deploy_Env: $latest_read_lock_deploy_env, Cloud_Provider: $latest_read_lock_cloud_provider, Region: $latest_read_lock_region, Email: $latest_read_lock_email. \e[0m" 
                echo -e "\e[1;32mWill release the read lock and backup to $latest_read_lock_directory. \e[0m"
            fi
            jq "del(.\"$backup_path\"[])" /tmp/read_lock > /tmp/read_lock.tmp
            aws s3 cp /tmp/read_lock.tmp ${backup_path%/*}/read_lock
            rm -f /tmp/read_lock.tmp
        fi
        rm -f /tmp/read_lock
    fi

    NumberOfBinaryHasData=$(echo $node_data | jq -r '.data.binaries | length')
    BinaryBlockHeights=""
    for (( index=0 ; index<$((NumberOfBinaryHasData)) ; index++ )) ; do
        BinaryBlockHeights=$BinaryBlockHeights',
        "LOCAL_HEIGHT_'$((index))'": "'$(jq -r '.data.binaries['$((index))'].local_height' <<< $node_data)'",
        "GLOBAL_HEIGHT_'$((index))'": "'$(jq -r '.data.binaries['$((index))'].global_height' <<< $node_data)'"'
    done

    cat <<EOF > /tmp/backup_metadata.json
    {"$PROTOCOL_NAME":{
        "PUBLIC_IP": "$(jq -r '.data.public_ip' <<< $node_data)"$BinaryBlockHeights
    }}
EOF
    backup_process $backup_path
}

function latest_backup_timestamp() {
    local latest_backup_timestamp=0
    local data_1_backup_timestamp=$(aws s3 cp $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-1/backup_metadata.json - | jq -r ".\"$PROTOCOL_NAME\".TIMESTAMP")
    local data_2_backup_timestamp=$(aws s3 cp $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/data-2/backup_metadata.json - | jq -r ".\"$PROTOCOL_NAME\".TIMESTAMP")
    if [[ $data_2_backup_timestamp -lt $data_1_backup_timestamp ]]; then
        latest_backup_timestamp=$data_1_backup_timestamp
    else
        latest_backup_timestamp=$data_2_backup_timestamp
    fi
    echo $latest_backup_timestamp
}

function backup_process() {
    local backup_path=$1
    if [[ "$data_type" != "snapshots" ]]; then
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Killing node... \e[0m"
        systemctl stop protocol-core.service
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Killed node. \e[0m"
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Uploading backup data...\e[0m"
        su ubuntu bash -c "/opt/protocol/protocol_runner $PROTOCOL_NAME backup $backup_path"
        aws s3 rm $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/write_lock --only-show-errors
        systemctl restart protocol-core.service
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Uploaded backup data \e[0m"
    else 
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Uploading backup snapshot ... \e[0m"
        su ubuntu bash -c "/opt/protocol/protocol_runner $PROTOCOL_NAME backup_snapshot $backup_path"
        aws s3 rm $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/$data_type/write_lock --only-show-errors
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Uploaded backup snapshot \e[0m"
    fi
    aws s3 cp $backup_path/backup_metadata.json $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/
}

{
    if [[ $CLOUD_PROVIDER == "oci" ]]; then
        export AWS_CONFIG_FILE=/home/ubuntu/.aws/config
        export AWS_SHARED_CREDENTIALS_FILE=/home/ubuntu/.aws/credentials
        export AWS_PROFILE=oci
    fi
    start_backup
    unset AWS_PROFILE

    if [[ ! -z "$BACKUP_ERROR" ]]; then
        exit 2
    fi
} >> $LOG_PATH 2>&1
