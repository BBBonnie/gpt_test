#!/bin/bash
#
#  script for common helpers that snapshot block data.
#
set -e
source /home/ubuntu/.infd/.env

LOG_PATH=/home/ubuntu/logs/syslog/snapshot.out
INFD_API="http://127.0.0.1:12345"
S3PATH_PROTOCOL="s3://infstones-protocol"
snapshot_regions=()
function usage() {
    echo "
Usage: Snapshot data
    $(basename $0) data [Options]
[Options]:
    -h | --help         # Help document.
    "
    exit 1
}

{
    while [[ $# -gt 0 ]]; do
        case $1 in
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

    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) [Begin]: Snapshotting data... \e[0m"

} >> $LOG_PATH 2>&1

function start_snapshot() {
    local node_data=$(curl -s $INFD_API/data)
    local node_status=$(jq -r '.data.node_status' <<< $node_data)
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Check snapshot_lock_info... \e[0m"
    local snapshot_lock=$(aws s3 ls $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/snapshot_lock)
    local current_time=$(date "+%s")
    if [[ -n $snapshot_lock ]]; then
      #have snapshot_lock
        local snapshot_lock_info=$(aws s3 cp $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/snapshot_lock -)
        local snapshot_lock_info_node_id=$(echo $snapshot_lock_info | jq -r '.NODE_ID')
        local snapshot_lock_info_snapshot_name=$(echo $snapshot_lock_info | jq -r '.SNAPSHOT_NAME')
        local snapshot_lock_info_email=$(echo $snapshot_lock_info | jq -r '.EMAIL')
        local snapshot_lock_info_public_ip=$(echo $snapshot_lock_info | jq -r '.PUBLIC_IP')
        local snapshot_lock_info_timestamp=$(date "+%s" -d $snapshot_lock_info_time)
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Found a snapshot_lock... \e[0m"
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The snapshot from node $snapshot_lock_info_node_id to $snapshot_lock_info_snapshot_name is currently in progress. \e[0m"
        echo -e "\e[1;32mNode $snapshot_lock_info_node_id has the Public_IP: $snapshot_lock_info_public_ip, Deploy_Env: $snapshot_lock_info_deploy_env, Cloud_Provider: $snapshot_lock_info_cloud_provider, Region: $snapshot_lock_info_region, Email: $snapshot_lock_info_email. \nExited\e[0m"
        BACKUP_ERROR=1
        return
    fi
    #No lock,continue to snapshot
    get_snapshot_regions
    if [[ $CLOUD_PROVIDER == "aws" ]]; then
      region=$(ec2metadata --availability-zone | sed 's/\(.*\)[a-z]/\1/')
      accounts=$(curl --location --request GET 'https://proxy.'$DOMAIN_NAME'/protocolmanager/aws/accounts' --header 'Authorization: Bearer '$JWT_TOKEN''|jq -r .'data')
      DEV_ACCOUNT=$(echo $accounts|jq -r '.dev')
      STAGE_ACCOUNT=$(echo $accounts|jq -r '.stage')
      PROD_INTERNAL_ACCOUNT=$(echo $accounts|jq -r '.["prod-internal"]')
      PROD_CLOUD_ACCOUNT=$(echo $accounts|jq -r '.["prod-cloud"]')
      if [[ -z $DEV_ACCOUNT || -z $STAGE_ACCOUNT || -z $PROD_INTERNAL_ACCOUNT || -z $PROD_CLOUD_ACCOUNT ]]; then
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) AWS account is null... \e[0m"
        BACKUP_ERROR=1
        return
      fi
      latest_current_region_snapshots=$(aws ec2 describe-snapshots --region $region --filter Name=tag:Name,Values="*snapshot-$PROTOCOL_NAME*" Name=status,Values=completed --query "sort_by(Snapshots, &StartTime)")
      latest_current_available_snapshot_total_num=$(echo $latest_current_region_snapshots|jq length)
      if [[ $latest_current_available_snapshot_total_num == 0 ]]; then
        #first time
        current_region_snapshot_serial_num=0
      else
        latest_current_region_snapshot_name=$(echo $latest_current_region_snapshots | jq -r '.[-1].Tags[0].Value')
        current_region_snapshot_serial_num=$(echo $latest_current_region_snapshot_name | cut -d "-" -f5)
       fi
    fi
    if [[ $CLOUD_PROVIDER == "oci" ]]; then
      region=$(curl -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ 2>/dev/null | jq '.regionInfo.regionIdentifier' | cut -d'"' -f 2)
      read instance_id compartment_id availability_domain < <(echo $(curl -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ 2>/dev/null | jq -r '.id, .compartmentId, .availabilityDomain' | cut -d'"' -f 2))
      latest_current_region_snapshots=$(sudo oci bv backup list --region $region --lifecycle-state "AVAILABLE" --query "data [?contains(\"display-name\",'snapshot-$PROTOCOL_NAME')]" --sort-by TIMECREATED --auth instance_principal --compartment-id $compartment_id)
      latest_current_available_snapshot_total_num=$(echo $latest_current_region_snapshots|jq length)
      if [[ $latest_current_available_snapshot_total_num == 0 || -z "$latest_current_available_snapshot_total_num" ]]; then
        #first time
         current_region_snapshot_serial_num=0
      else
        latest_current_region_snapshot_name=$(echo $latest_current_region_snapshots |jq -r '.[0]."display-name"')
        current_region_snapshot_serial_num=$(echo $latest_current_region_snapshot_name | cut -d "-" -f5)
      fi
    fi
    process_snapshot $current_region_snapshot_serial_num
}

function process_snapshot() {
    local snapshot_lock=$(cat <<-END
    {"NODE_ID": "$NODE_ID",
     "SNAPSHOT_NAME": "$SNAPSHOT_NAME",
     "CLOUD_PROVIDER": "$CLOUD_PROVIDER",
     "DEPLOY_ENV": "$DEPLOY_ENV",
     "PUBLIC_IP": "$(curl -s $INFD_API/data | jq -r '.data.public_ip')",
     "EMAIL": "$EMAIL",
     "REGION": "$REGION"}
END
)
    jq -r '.' <<< $snapshot_lock > /tmp/snapshot_lock
    aws s3 mv /tmp/snapshot_lock $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/

    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Killing node... \e[0m"
    systemctl stop protocol-core.service
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Killed node. \e[0m"
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Creating snapshot... \e[0m"
    data_size=$(du -sb /data | cut -f 1)
    sleep 10
    new_data_size=$(du -sb /data | cut -f 1)
    while [[ $data_size -ne $new_data_size ]]; do
      echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) data_size is $data_size \e[0m"
      echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) new_data_size is $new_data_size \e[0m"
      data_size=new_data_size
      sleep 10
      new_data_size=$(du -sb /data | cut -f 1)
    done
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) data_size is $data_size \e[0m"
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) new_data_size is $new_data_size \e[0m"
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Snapshotting... \e[0m"
    if [[ $CLOUD_PROVIDER == "aws" ]]; then
    create_aws_snapshot $1
    fi
    if [[ $CLOUD_PROVIDER == "oci" ]]; then
    create_oci_snapshot $1
    fi
    aws s3 rm $S3PATH_PROTOCOL/$PROTOCOL_NAME/data/snapshot_lock --only-show-errors
    echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Create snapshot successfully.\e[0m"
    systemctl restart protocol-core.service
}

function create_aws_snapshot() {
        snapshot_name="$DEPLOY_ENV-$USAGE-snapshot-$PROTOCOL_NAME-$(($1+1))"
        region=$(ec2metadata --availability-zone | sed 's/\(.*\)[a-z]/\1/')
        instance_id=$(ec2metadata --instance-id)
        volume_info=$(aws ec2 describe-volumes --region $region --filters "Name=attachment.instance-id,Values=$instance_id" "Name=attachment.device,Values=/dev/sdm")
        volume_id=$(echo $volume_info | jq -r '.Volumes[0].VolumeId')
        if [[ -z $volume_id || $volume_id == null ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The volume_id is null, the snapshot process will exit.\e[0m"
          return
        fi
        current_region_snapshot_id=$(aws ec2 create-snapshot --volume-id $volume_id --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$snapshot_name}]"  --description $snapshot_name  --region $region| jq -r .SnapshotId)
        current_region_snapshot_status=$(aws ec2 describe-snapshots --region $region --snapshot-ids $current_region_snapshot_id | jq -r .Snapshots[0].State)
        while [[ $current_region_snapshot_status == "pending" ]]; do
           sleep 10
           current_region_snapshot_status=$(aws ec2 describe-snapshots --region $region --snapshot-ids $current_region_snapshot_id | jq -r .Snapshots[0].State)
        done
        if [[ $current_region_snapshot_status == "completed" ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) $snapshot_name is available.\e[0m"
        else
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) current_region_snapshot_status is $current_region_snapshot_status \e[0m"
          BACKUP_ERROR=1
          return
        fi
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Coping snapshot... \e[0m"
        for snapshot_region in ${snapshot_regions[@]}
        do {
          if [[ $snapshot_region != $region ]]; then
            copy_aws_snapshot_to_other_region $snapshot_region
          fi
        } &
        done
        wait
        if [[ $DEPLOY_ENV == "dev" ]]; then
        aws ec2 modify-snapshot-attribute --snapshot-id $current_region_snapshot_id  --region $region --attribute createVolumePermission --operation-type add --user-ids $STAGE_ACCOUNT $PROD_INTERNAL_ACCOUNT $PROD_CLOUD_ACCOUNT
        fi
        if [[ $DEPLOY_ENV == "stage" ]]; then
        aws ec2 modify-snapshot-attribute --snapshot-id $current_region_snapshot_id  --region $region --attribute createVolumePermission --operation-type add --user-ids $DEV_ACCOUNT $PROD_INTERNAL_ACCOUNT $PROD_CLOUD_ACCOUNT
        fi
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Share region $region snapshot finished.\e[0m"
        if [[ ! -z "$BACKUP_ERROR" ]]; then
          exit 2
        fi
        #delete old snapshot
        sleep 10
        for snapshot_region in ${snapshot_regions[@]}
        do
        available_snapshot_total_num=$(aws ec2 describe-snapshots --region $snapshot_region --filter Name=tag:Name,Values="*snapshot-$PROTOCOL_NAME*" Name=status,Values=completed --query 'length(Snapshots)')
        if [[ $available_snapshot_total_num -gt 2 ]]; then
          old_available_snapshot_id=$(aws ec2 describe-snapshots --region $snapshot_region --filter Name=tag:Name,Values="*snapshot-$PROTOCOL_NAME*" Name=status,Values=completed --query "sort_by(Snapshots, &StartTime)[-3]" |jq -r '.SnapshotId')
          aws ec2 delete-snapshot --snapshot-id $old_available_snapshot_id --region $snapshot_region
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Delete snapshot finished in $snapshot_region.\e[0m"
        else
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) No snapshot need to delete in $snapshot_region.\e[0m"
        fi
        done
} >> $LOG_PATH 2>&1

function copy_aws_snapshot_to_other_region() {
        per_region_copied_snapshot_id=$(aws ec2 copy-snapshot --region $1 --source-region $region --source-snapshot-id $current_region_snapshot_id --description $snapshot_name |jq -r .SnapshotId)
        per_region_copied_snapshot_status=$(aws ec2 describe-snapshots --region $1 --snapshot-ids $per_region_copied_snapshot_id | jq -r .Snapshots[0].State)
        while [[ $per_region_copied_snapshot_status == "pending" ]]; do
           sleep 10
           per_region_copied_snapshot_status=$(aws ec2 describe-snapshots --region $1 --snapshot-ids $per_region_copied_snapshot_id | jq -r .Snapshots[0].State)
        done
        if [[ $per_region_copied_snapshot_status == "completed" ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Region $1 snapshot is available.\e[0m"
        else
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Region $1 snapshot status is $per_region_copied_snapshot_status \e[0m"
          BACKUP_ERROR=1
          return
        fi
        aws ec2 create-tags --resources $per_region_copied_snapshot_id --region $1 --tags Key=Name,Value=$snapshot_name
        if [[ $DEPLOY_ENV == "dev" ]]; then
        aws ec2 modify-snapshot-attribute --snapshot-id $per_region_copied_snapshot_id  --region $1 --attribute createVolumePermission --operation-type add --user-ids $STAGE_ACCOUNT $PROD_INTERNAL_ACCOUNT $PROD_CLOUD_ACCOUNT
        fi
        if [[ $DEPLOY_ENV == "stage" ]]; then
        aws ec2 modify-snapshot-attribute --snapshot-id $per_region_copied_snapshot_id  --region $1 --attribute createVolumePermission --operation-type add --user-ids $DEV_ACCOUNT $PROD_INTERNAL_ACCOUNT $PROD_CLOUD_ACCOUNT
        fi
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Share region $1 snapshot finished.\e[0m"
}

function create_oci_snapshot() {
        snapshot_name="$DEPLOY_ENV-$USAGE-snapshot-$PROTOCOL_NAME-$(($1+1))"
        volume_id=$(sudo oci compute volume-attachment list --availability-domain $availability_domain --compartment-id $compartment_id --instance-id $instance_id --auth instance_principal | jq '.data[] ."volume-id"' | cut -d'"' -f 2)
        if [[ -z $volume_id || $volume_id == null ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) The volume_id is null, the snapshot process will exit.\e[0m"
          return
        fi
        current_region_snapshot_id=$(sudo oci bv backup create --volume-id $volume_id --display-name $snapshot_name --auth instance_principal | jq -r '.data.id')
        current_region_snapshot_status=$(sudo oci bv backup get --volume-backup-id $current_region_snapshot_id --auth instance_principal | jq -r '.data."lifecycle-state"')
        while [[ $current_region_snapshot_status == "CREATING" || $current_region_snapshot_status == "REQUEST_RECEIVED" ]]; do
           sleep 10
           current_region_snapshot_status=$(sudo oci bv backup get --volume-backup-id $current_region_snapshot_id --auth instance_principal | jq -r '.data."lifecycle-state"')
        done
        if [[ $current_region_snapshot_status == "AVAILABLE" ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) $snapshot_name is available.\e[0m"
        else
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) current_region_snapshot_status is $current_region_snapshot_status \e[0m"
          BACKUP_ERROR=1
          return
        fi
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Coping snapshot... \e[0m"
        #copy snapshot to other regions
        for snapshot_region in ${snapshot_regions[@]}
        do {
          if [[ $snapshot_region != $region ]]; then
            copy_oci_snapshot_to_other_region $snapshot_region
          fi
        } &
        done
        wait
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Copy region $region snapshot finished.\e[0m"
        #delete old snapshot
        sleep 10
        for snapshot_region in ${snapshot_regions[@]}
        do
        available_snapshot_total_num=$(sudo oci bv backup list --lifecycle-state "AVAILABLE"  --sort-by TIMECREATED --query "length(data [?contains(\"display-name\",'snapshot-$PROTOCOL_NAME')])" --auth instance_principal --compartment-id $compartment_id  --region $snapshot_region)
        if [[ $available_snapshot_total_num -gt 2 ]]; then
          old_available_snapshot_id=$(sudo oci bv backup list --lifecycle-state "AVAILABLE"  --sort-by TIMECREATED --query "data [?contains(\"display-name\",'snapshot-$PROTOCOL_NAME')]" --auth instance_principal --compartment-id $compartment_id  --region $snapshot_region | jq -r '.[2].id')
          sudo oci bv backup delete --force --region $snapshot_region --auth instance_principal --volume-backup-id $old_available_snapshot_id
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Delete snapshot finished in $snapshot_region.\e[0m"
        else
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) No snapshot need to delete in $snapshot_region.\e[0m"
        fi
        done

} >> $LOG_PATH 2>&1

function copy_oci_snapshot_to_other_region() {
        per_region_copied_snapshot_id=$(sudo oci bv backup copy --destination-region $1 --volume-backup-id $current_region_snapshot_id --auth instance_principal | jq -r .data.id)
        per_region_copied_snapshot_status=$(sudo oci bv backup get --region $1 --volume-backup-id $per_region_copied_snapshot_id --auth instance_principal | jq -r '.data."lifecycle-state"')
        while [[ $per_region_copied_snapshot_status == "CREATING" || $per_region_copied_snapshot_status == "REQUEST_RECEIVED" ]]; do
           sleep 10
           per_region_copied_snapshot_status=$(sudo oci bv backup get --volume-backup-id $per_region_copied_snapshot_id --region $1 --auth instance_principal | jq -r '.data."lifecycle-state"')
        done
        if [[ $per_region_copied_snapshot_status == "AVAILABLE" ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Region $1 snapshot is available.\e[0m"
        else
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) Region $1 snapshot status is $per_region_copied_snapshot_status \e[0m"
          BACKUP_ERROR=1
          return
        fi
}

function get_snapshot_regions() {
        source /home/ubuntu/.infd/.env
        response_data=$(curl --location --request GET 'https://proxy.'$DOMAIN_NAME'/protocolmanager/snapshot_regions?cloud_provider='$CLOUD_PROVIDER --header 'Authorization: Bearer '$JWT_TOKEN''|jq -r .'data')
        if [[ $CLOUD_PROVIDER == "aws" ]]; then
        region=$(ec2metadata --availability-zone | sed 's/\(.*\)[a-z]/\1/')
        fi
        if [[ $CLOUD_PROVIDER == "oci" ]]; then
        region=$(curl -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ 2>/dev/null | jq '.regionInfo.regionIdentifier' | cut -d'"' -f 2)
        fi
        #response data is null
        if [[ $response_data == null ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) snapshot_regions is null.\e[0m"
          snapshot_regions[0]=$region
          return
        fi
        snapshot_regions=($(echo $response_data| jq -r '.[]'))
        #response data is []
        if [[ -z $snapshot_regions ]]; then
          echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) snapshot_regions length is 0.\e[0m"
          snapshot_regions[0]=$region
        fi
        echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) List all regions.\e[0m"
        for snapshot_region in ${snapshot_regions[@]}
        do {
           echo -e "\e[1;32m$(date +%Y-%m-%d_%H:%M:%S) $snapshot_region.\e[0m"
        }
        done
}

{
    if [[ $CLOUD_PROVIDER == "oci" ]]; then
      export AWS_CONFIG_FILE=/home/ubuntu/.aws/config
      export AWS_SHARED_CREDENTIALS_FILE=/home/ubuntu/.aws/credentials
      export AWS_PROFILE=oci
    fi
    start_snapshot
    unset AWS_PROFILE
    if [[ ! -z "$BACKUP_ERROR" ]]; then
        exit 2
    fi
} >> $LOG_PATH 2>&1
