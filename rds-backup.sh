#!/bin/bash
if test "$#" -ne 2; then
    echo "Illegal number of parameters, please pass the names of the instance to backup from, and the one to backup to"
    echo "Example $0 db1 db2"
fi

PRIMARY_DB=$1
BACKUP_DB=$2
SLEEP_TIME=15
################### SECTION 3: SETUP PATHS #######################
# This section sets parameters such as the your AWS credentials are stored, the Postgres username and password, the name of the primary RDS instance and the name of the secondary instance. 
echo "STEP 1 of 11: Setup parameters"
export AWS_CREDENTIAL_FILE=/root/.aws.creds
export AWS_RDS_HOME=/opt/aws/apitools/rds
export JAVA_HOME=/usr/lib/jvm/jre
export AVAIL_ZONE=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
export EC2_REGION="$(echo $AVAIL_ZONE | sed 's/.$//g')"

echo "Availability Zone: $AVAIL_ZONE"
export PGUSER=postgres
export PGPASSWORD=postgres
export STANDARDPASSWORD=thisisourstandardpassword

echo ""
echo "--------------------------------------------------------------"
echo "STEP 2 of 11: Verify that primary instance exists"
OUTFILE=$(mktemp)
${AWS_RDS_HOME}/bin/rds-describe-db-instances ${PRIMARY_DB}> ${OUTFILE}
STATUS=$(head -1 ${OUTFILE} | grep "available")
SECURITY_GROUP=$(grep "VPCSECGROUP" ${OUTFILE} | awk '{print $2}')

if [[ $STATUS != *available* ]]; then
    echo "Sorry. Primary instance ${PRIMARY_DB} does not exist or is not available. Cannot proceed"
    exit 1
fi

echo "... Primary Instance verified"

if [[ $PRIMARY_DB == $BACKUP_DB ]]; then
    echo "Sorry. Primary instance & Backup Instance cannot be the same. Cannot proceed"
    exit 1
fi

################### SECTION 2: SETUP NEEDED PACKAGES #######################
echo ""
echo "--------------------------------------------------------------"
echo "STEP 3 of 11: Install EC2 tools, postgresql & java (if needed)"
PACKLIST=""
if ! test -f /usr/bin/java ; then
    PACKLIST="$PACKLIST java-1.6.0-openjdk"
fi
if ! test -f /usr/bin/psql; then
    PACKLIST="$PACKLIST postgresql"
fi
if ! rpm -q --quiet aws-apitools-rds; then
    PACKLIST="$PACKLIST aws-apitools-rds"
fi

if [[ $PACKLIST != "" ]]; then
    sudo yum install -y $PACKLIST
fi

################### SECTION 4: CREATE TEMPORARY NAMES #######################
#This section creates some random names which we shall use when renaming our backups
echo ""
echo "--------------------------------------------------------------"
echo "STEP 4 of 11: Creating names for temporary db instances"
TEMP_DB=$(mktemp -u db-XXXXXXXX)
SNAPSHOT=$(mktemp -u sn-XXXXXXXX)
TEMP_DB_OLD=$(mktemp -u db-XXXXXXXX)

################### SECTION 5: Create a snapshot of the primary #######################
#This section creates a snapshot of the primary, giving it a temporary name (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-CreateDBSnapshot.html)
echo ""
echo "--------------------------------------------------------------"
echo "STEP 5 of 11: Creating snapshot ${SNAPSHOT} of ${PRIMARY_DB}. Please wait..."

if ! ${AWS_RDS_HOME}/bin/rds-create-db-snapshot -i ${PRIMARY_DB} -s ${SNAPSHOT} | tee ${OUTFILE}; then 
    echo "*********** ERROR: Failed to create snapshot of ${PRIMARY_DB} ********************"
    exit 1
fi  
VPC=$(head -1 ${OUTFILE} | sed 's/.*vpc/vpc/' | awk '{print $1}')


#The command line tools don't tell us when the snapshot has been successfully created, so we need to constantly (every 15 seconds) monitor the snapshot until it shows as "available". (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBSnapshots.html)

# Every 30 seconds, check if snapshot complete
count=0
while /bin/true
do
    sleep ${SLEEP_TIME}
    eval count=$((count+${SLEEP_TIME}))
    echo "... $count seconds gone. Still waiting..."
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-snapshots -i ${PRIMARY_DB} -s ${SNAPSHOT} | grep available)

    [[ ! -z $STATUS ]] && break
done

echo "Snapshot ${SNAPSHOT} done"

################### SECTION 6: Create a new instance based on this snapshot #############
#Now, we create a new db instance using the snapshot we created (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-RestoreDBInstanceFromDBSnapshot.html)

# Now, restore this snapshot to the backup instance
echo ""
echo "--------------------------------------------------------------"
echo "STEP 6 of 11: Creating DB Instance ${TEMP_DB} from snapshot ${SNAPSHOT}"

SEC=$(${AWS_RDS_HOME}/bin/rds-describe-db-subnet-groups | grep $VPC | awk '{print $2}')

if [[ -z ${SEC} ]]; then
    echo "*********** ERROR: Failed to find any subnet groups for ${VPC} ********************"
    exit 1
fi

if ! ${AWS_RDS_HOME}/bin/rds-restore-db-instance-from-db-snapshot -i ${TEMP_DB} -s ${SNAPSHOT} -sn ${SEC}; then
    echo "*********** ERROR: Failed to restore the snapshot ${SNAPSHOT} as a DB Instance ${TEMP_DB} ********************"
    exit 1
fi

# The command line tools don't tell us when the instance has been successfully created, so we need to constantly (every 60 seconds because this takes longer than snapshotting) monitor the instance until it shows as "available". (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBInstances.html)

count=0
# Check every minute for it to be created
while /bin/true
do
    sleep ${SLEEP_TIME}
    count=$((count+${SLEEP_TIME}))
    echo "... Checking for completion of DB creation... ${count} seconds elapsed"
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${TEMP_DB} | head -1 | grep "available")
    [[ $STATUS == *available* ]] && break
done

################### SECTION 7: Rename the backup instance #######################
# Now, we rename the backup instance. Deleting takes long, so we want to rename it first, then delete it. (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-ModifyDBInstance.html)

echo ""
echo "--------------------------------------------------------------"

echo "STEP 7 of 11: Check if backup instance ${BACKUP_DB} exists. If it does, rename it"

STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB} | head -1 | grep "available")

DELETE_OLD=0
if [[ $STATUS == *available* ]]; then
    DELETE_OLD=1
    echo "... ${BACKUP_DB} exists. Renaming to ${TEMP_DB_OLD}. Please wait..."
    if ! ${AWS_RDS_HOME}/bin/rds-modify-db-instance ${BACKUP_DB} -n ${TEMP_DB_OLD} --apply-immediately; then
        echo "*********** ERROR: Failed to rename ${BACKUP_DB}. Cannot proceed ********************"
        exit 1
    fi

    # Wait to be sure it's been renamed, or the next step will fail
    while ${AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB}; do
        echo "... Waiting for it to be renamed"
        sleep 5
    done

    echo "... Finished renaming old backup instance"
fi

################### SECTION 8: Rename the snapshotted instance #######################
# Now, we rename the newly created temporary instance (i.e. the one we created from a snapshot) to be our backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-ModifyDBInstance.html)

echo ""
echo "--------------------------------------------------------------"
echo "STEP 8 of 11: Renaming the snapshot DB ${TEMP_DB} to ${BACKUP_DB}. Please wait..."
if ! ${AWS_RDS_HOME}/bin/rds-modify-db-instance ${TEMP_DB} -sg ${SECURITY_GROUP} -n ${BACKUP_DB} --apply-immediately; then
    echo "*********** ERROR: Failed to rename instance ${TEMP_DB} to ${BACKUP_DB}. Cannot proceed ********************"
    exit 1
fi

sleep ${SLEEP_TIME}
count=0
# Wait for it to be renamed & made available
while /bin/true
do
    sleep ${SLEEP_TIME}
    count=$((count+${SLEEP_TIME}))
    echo "... Checking for renaming of snapshot... ${count} seconds elapsed"
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB} | grep available)
    [[ $STATUS == *available* ]] && break
done    

################# SECTION 9: Find out the port the instance is running on #############

################### so our psql tool can connect #############
# Now, we delete the old backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBInstances.html)
echo ""
echo "--------------------------------------------------------------"
echo "STEP 9 of 11: Configuring host & port"

# Discover host & port
AWS_RDS_DETAILS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB} | head -1)
AWS_RDS_HOST=$(echo ${AWS_RDS_DETAILS} | awk '{print $9}')
AWS_RDS_PORT=$(echo ${AWS_RDS_DETAILS} | awk '{print $10}')

################### SECTION 10: Now we reset the user's password #############
# Now, we use postgresql's client tool to reset use passwords
echo ""
echo "--------------------------------------------------------------"
echo "STEP 10 of 11: Now resetting user passwords & fixing receipts table"

# First make sure instance is reachable. Sometimes this takes some time
while /bin/true
do
    [[ host ${AWS_RDS_HOST} ]] && break
done

SQL_FILE=$(mktemp)
for username in `psql -h ${AWS_RDS_HOST} -p ${AWS_RDS_PORT} template1 -tc "SELECT usename FROM pg_catalog.pg_user u WHERE usename NOT IN ('rdsadmin', 'rdsrepladmin');"`; do
    echo "ALTER USER $username WITH PASSWORD '"${STANDARDPASSWORD}"';" >> $SQL_FILE
done

psql -h ${AWS_RDS_HOST} -p ${AWS_RDS_PORT} template1 -f $SQL_FILE
rm $SQL_FILE

echo "Resetting images for receipts table"
# Reset images

psql -h ${AWS_RDS_HOST} -p ${AWS_RDS_PORT} dama86dd4g3vj6 -c "UPDATE receipts set S3_path_to_image = 'test'";

################### SECTION 11: Rename the backup instance #######################
# Now, we delete the old backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DeleteDBInstance.html)

echo ""
echo "--------------------------------------------------------------"
echo "STEP 11 of 11: Deleting old snapshots and instances"

[[ $DELETE_OLD -eq 1 ]] && ${AWS_RDS_HOME}/bin/rds-delete-db-instance ${TEMP_DB_OLD} --skip-final-snapshot -f && echo "... Deleted ${TEMP_DB_OLD}"

echo "STEP 11a: Deleting snapshot ${SNAPSHOT}"
if ${AWS_RDS_HOME}/bin/rds-delete-db-snapshot ${SNAPSHOT} -f; then
    echo "Snapshot deleted"
else
    echo "Failed to delete snapshot ${SNAPSHOT}. Please delete manually."
fi


echo "**************** COMPLETED ******************"