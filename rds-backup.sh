#!/bin/sh
################### SECTION 1: SETUP NEEDED PACKAGES #######################
sudo yum install postgresql

################### SECTION 2: SETUP EC2 TOOLS #######################
# This section downloads the EC2 tools and sets them up
wget -P /tmp http://s3.amazonaws.com/rds-downloads/RDSCli.zip
cd /tmp
sudo unzip /tmp/RDSCli.zip -d /usr/local/
# Rename the RDS directory to /usr/local/rds
sudo mv /usr/local/RDSCli* /usr/local/rds 

################### SECTION 3: SETUP PATHS #######################
# This section sets parameters such as the your AWS credentials are stored, the Postgres username and password, the name of the primary RDS instance and the name of the secondary instance. 
export AWS_ACCESS_KEY=your-aws-access-key-id
export AWS_SECRET_KEY=your-aws-secret-key
export AWS_RDS_HOME=/usr/local/rds

export PGUSER=postgres
export PGPASSWD=postgres
PRIMARY_DB=primary_database_instance
BACKUP_DB=backup_database_instance

################### SECTION 4: CREATE TEMPORARY NAMES #######################
#This section creates some random names which we shall use when renaming our backups
TEMP_DB=$(mktemp XXXXXXXX)
SNAPSHOT=$(mktemp XXXXXXXX)

################### SECTION 5: Create a snapshot of the primary #######################
#This section creates a snapshot of the primary, giving it a temporary name (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-CreateDBSnapshot.html)
echo "Creating snapshot ${TEMP_DB} of ${PRIMARY_DB}"

${AWS_RDS_HOME}/bin/rds-create-db-snapshot -i ${PRIMARY_DB} -s ${SNAPSHOT}

#The command line tools don't tell us when the snapshot has been successfully created, so we need to constantly (every 15 seconds) monitor the snapshot until it shows as "available". (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBSnapshots.html)

# Every 15 seconds, check if snapshot complete
while /bin/true
do
    sleep 15
    if ${AWS_RDS_HOME}/bin/rds-describe-db-snapshots -i ${PRIMARY_DB} -s ${SNAPSHOT} | grep available; then 

    if [ "x$STATUS" -eq "xavailable" ]; then
        break
    fi
done


################### SECTION 6: Create a new instance based on this snapshot #############
#Now, we create a new db instance using the snapshot we created (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-RestoreDBInstanceFromDBSnapshot.html)

# Now, restore this snapshot to the backup instance
echo "Creating DB ${TEMP_DB} from snapshot ${SNAPSHOT}"
${AWS_RDS_HOME}/bin/rds-restore-db-instance-from-db-snapshot -i ${TEMP_DB} -s ${SNAPSHOT}

# The command line tools don't tell us when the instance has been successfully created, so we need to constantly (every 60 seconds because this takes longer than snapshotting) monitor the instance until it shows as "available". (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBInstances.html)

count=0
# Check every minute for it to be created
while /bin/true
do
    sleep 60
    count=$((count+1))
    echo "Checking for completion of DB creation... Minutes elapsed=${count}"
    STATUS=$(${AWS_RDS_HOME}/bin/rds-describe-db-instances ${TEMP_DB} | head -1 | awk '{print $7}')
    if [ "$STATUS" -eq "available" ]; then
        break
    fi
done    

################### SECTION 7: Rename the backup instance #######################
# Now, we rename the backup instance. Deleting takes long, so we want to rename it first, then delete it. (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-ModifyDBInstance.html)

echo "Renaming the old ${BACKUP_DB} DB to ${BACKUP_DB}-old"
${AWS_RDS_HOME}/bin/rds-modify-db-instance ${BACKUP_DB} -n ${BACKUP_DB}-old --apply-immediately

################### SECTION 8: Rename the backup instance #######################
# Now, we rename the newly created temporary instance (i.e. the one we created from a snapshot) to be our backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-ModifyDBInstance.html)

sleep 60 # wait a minute
echo "Renaming the snapshot DB ${TEMP_DB} to ${BACKUP_DB}"
${AWS_RDS_HOME}/bin/rds-modify-db-instance ${TEMP_DB} -n ${BACKUP_DB} --apply-immediately

################### SECTION 9: Rename the backup instance #######################
# Now, we delete the old backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DeleteDBInstance.html)

sleep 60 # wait a minute
echo "Deleting ${BACKUP_DB}.old"
${AWS_RDS_HOME}/bin/rds-delete-db-instance ${BACKUP_DB}-old

################# SECTION 10: Find out the port the instance is running on #############

################### so our psql tool can connect #############
# Now, we delete the old backup instance (http://docs.aws.amazon.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-DescribeDBInstances.html)

# Discover host & port
AWS_RDS_DETAILS=$({AWS_RDS_HOME}/bin/rds-describe-db-instances ${BACKUP_DB} | head -1)
AWS_RDS_HOST=$(echo ${AWS_RDS_DETAILS} | awk '{print $9}')
AWS_RDS_PORT=$(echo ${AWS_RDS_DETAILS} | awk '{print $10}')

################### SECTION 10: Now we reset the user's password #############
# Now, we use postgresql's client tool to reset use passwords
echo "Now resetting user passwords & fixing receipts table"
SQL_FILE=$(mktemp)
for username in `psql -h ${AWS_RDS_HOST} -p ${AWS_RDS_PORT} template1 -tc "SELECT usename FROM pg_catalog.pg_user u WHERE usename <> 'postgres'"`; do
    echo "ALTER USER $username WITH PASSWORD 'thisisourstandardpassword'" >> $SQL_FILE
done

# Reset images

psql -h ${AWS_RDS_HOST} -p ${AWS_RDS_PORT} template1 -f $SQL_FILE

echo "COMPLETED"
