#!/bin/bash
################### SECTION 1: SETUP NEEDED PACKAGES #######################
echo "STEP 1: Install postgresql & java (if needed)"
sudo apt-get install -y postgresql openjdk-7-jre-headless

################### SECTION 2: SETUP EC2 TOOLS #######################
# This section downloads the EC2 tools and sets them up
echo "STEP 2: Downloading AWS CLI Tools"
wget -q -O /tmp/RDSCli.zip http://s3.amazonaws.com/rds-downloads/RDSCli.zip
cd /tmp
sudo unzip -q -o /tmp/RDSCli.zip -d /usr/local/
# Rename the RDS directory to /usr/local/rds
sudo mv /usr/local/RDSCli* /usr/local/rds 

################### SECTION 3: SETUP PATHS #######################
# This section sets parameters such as the your AWS credentials are stored, the Postgres username and password, the name of the primary RDS instance and the name of the secondary instance. 
echo "STEP 3: Setup parameters"
export AWS_CREDENTIAL_FILE=/home/ubuntu/.aws.creds
export AWS_RDS_HOME=/usr/local/rds
export JAVA_HOME=/usr/lib/jvm/default-java

export PGUSER=postgres
export PGPASSWD=postgres
PRIMARY_DB=db1
BACKUP_DB=db2

################### SECTION 4: CREATE TEMPORARY NAMES #######################
#This section creates some random names which we shall use when renaming our backups
echo "STEP 4: Creating temporary files"
TEMP_DB=$(mktemp XXXXXXXX)
SNAPSHOT="a$(mktemp XXXXXXXX)"

################### SECTION 5: Create a snapshot of the primary #######################
#This section creates a snapshot of the primary, giving it a temporary name (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-CreateDBSnapshot.html)
echo "STEP 5: Creating snapshot ${SNAPSHOT} of ${PRIMARY_DB}. Please wait..."

${AWS_RDS_HOME}/bin/rds-create-db-snapshot -i ${PRIMARY_DB} -s ${SNAPSHOT}

#The command line tools don't tell us when the snapshot has been successfully created, so we need to constantly (every 15 seconds) monitor the snapshot until it shows as "available". (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBSnapshots.html)

# Every 30 seconds, check if snapshot complete
count=0
while /bin/true
do
    sleep 30
    eval count=$((count+30))
    echo "... $count seconds gone. Still waiting..."
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-snapshots -i ${PRIMARY_DB} -s ${SNAPSHOT} | grep available)

    [[ ! -z $STATUS ]] && break
done

echo "Snapshot ${SNAPSHOT} done"

################### SECTION 6: Create a new instance based on this snapshot #############
#Now, we create a new db instance using the snapshot we created (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-RestoreDBInstanceFromDBSnapshot.html)

# Now, restore this snapshot to the backup instance
echo "STEP 6: Creating DB ${TEMP_DB} from snapshot ${SNAPSHOT}"
${AWS_RDS_HOME}/bin/rds-restore-db-instance-from-db-snapshot -i ${TEMP_DB} -s ${SNAPSHOT}

# The command line tools don't tell us when the instance has been successfully created, so we need to constantly (every 60 seconds because this takes longer than snapshotting) monitor the instance until it shows as "available". (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBInstances.html)

count=0
# Check every minute for it to be created
while /bin/true
do
    sleep 60
    count=$((count+1))
    echo "... Checking for completion of DB creation... Minutes elapsed=${count}"
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${TEMP_DB} | head -1 | grep "available")
    [[ $STATUS == *available* ]] && break
done    

################### SECTION 7: Rename the backup instance #######################
# Now, we rename the backup instance. Deleting takes long, so we want to rename it first, then delete it. (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-ModifyDBInstance.html)

echo "STEP 7: Renaming the old ${BACKUP_DB} DB to ${BACKUP_DB}-old. Please wait..."
${AWS_RDS_HOME}/bin/rds-modify-db-instance ${BACKUP_DB} -n ${BACKUP_DB}-old --apply-immediately > /dev/null 2>&1

count=0
# Check every minute for it to be created
while /bin/true
do
    sleep 15
    count=$((count+15))
    echo "... Checking for renaming of DB creation... ${count} second elapsed"
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB}-old | grep available)
    [[ $STATUS == *available* ]] && break
done    

################### SECTION 8: Rename the backup instance #######################
# Now, we rename the newly created temporary instance (i.e. the one we created from a snapshot) to be our backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-ModifyDBInstance.html)

sleep 60 # wait a minute
echo "STEP 8: Renaming the snapshot DB ${TEMP_DB} to ${BACKUP_DB}. Please wait..."
${AWS_RDS_HOME}/bin/rds-modify-db-instance ${TEMP_DB} -n ${BACKUP_DB} --apply-immediately > /dev/null 2>&1

count=0
# Check every minute for it to be created
while /bin/true
do
    sleep 15
    count=$((count+15))
    echo "... Checking for renaming of snapshot... ${count} second elapsed"
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB} | grep available)
    [[ $STATUS == *available* ]] && break
done    

################### SECTION 9: Rename the backup instance #######################
# Now, we delete the old backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DeleteDBInstance.html)

echo "STEP 9: Deleting ${BACKUP_DB}-old ..."
${AWS_RDS_HOME}/bin/rds-delete-db-instance --skip-final-snapshot -f ${BACKUP_DB}-old > /dev/null 2>&1

################# SECTION 10: Find out the port the instance is running on #############

################### so our psql tool can connect #############
# Now, we delete the old backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBInstances.html)
echo "STEP 10: Configuring host & port"

# Discover host & port
AWS_RDS_DETAILS=$({AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB} | head -1)
AWS_RDS_HOST=$(echo ${AWS_RDS_DETAILS} | awk '{print $9}')
AWS_RDS_PORT=$(echo ${AWS_RDS_DETAILS} | awk '{print $10}')

################### SECTION 10: Now we reset the user's password #############
# Now, we use postgresql's client tool to reset use passwords
echo "STEP 11: Now resetting user passwords & fixing receipts table"
SQL_FILE=$(mktemp)
for username in `psql -h ${AWS_RDS_HOST} -p ${AWS_RDS_PORT} template1 -tc "SELECT usename FROM pg_catalog.pg_user u WHERE usename <> 'postgres'"`; do
    echo "ALTER USER $username WITH PASSWORD 'thisisourstandardpassword'" >> $SQL_FILE
done

# Reset images

psql -h ${AWS_RDS_HOST} -p ${AWS_RDS_PORT} template1 -f $SQL_FILE

echo "**************** COMPLETED ******************"
