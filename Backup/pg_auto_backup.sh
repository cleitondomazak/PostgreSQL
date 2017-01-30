#!/bin/bash

# Username to access the PostgreSQL server e.g. dbuser
USERNAME=postgres

# Host name (or IP address) of PostgreSQL server e.g localhost
DBHOST=localhost

#Backup type (plain or custom)
BACKUPTYPE="custom"

#Specify the compression level to use. Default is 5
COMPRESIONLEVEL=5

# List of DBNAMES for Daily/Weekly Backup e.g. "DB1 DB2 DB3"
DBNAMES="all"

# Backup directory location e.g /backups
BACKUPDIR="/storage/backups"

#Send to Amazon S3
SEND_TO_S3="yes"
BUCKETNAME="s3://your-s3-bucket/"

# Email Address to send mail to? (user@domain.com)
MAILADDR="dba@domain.com"

#Zabbix integration
ZABBIXSENDER="yes"

# List of DBBNAMES for Monthly Backups.
MDBNAMES="template1 $DBNAMES"

# List of DBNAMES to EXLUCDE if DBNAMES are set to all (must be in " quotes)
DBEXCLUDE=""

# Include CREATE DATABASE in backup?
CREATE_DATABASE=yes

# Which day do you want weekly backups? (1 to 7 where 1 is Monday)
DOWEEKLY=6

# Choose Compression type. (gzip or bzip2)
COMP=bzip2

# Command to run before backups (uncomment to use)
#PREBACKUP="/etc/pgsql-backup-pre"

# Command run after backups (uncomment to use)
#POSTBACKUP="bash /home/backups/scripts/ftp_pgsql"

PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/postgres/bin:/usr/local/pgsql/bin
DATE=`date +%Y-%m-%d`				# Datestamp e.g 2002-09-21
DOW=`date +%A`					# Day of the week e.g. Monday
DNOW=`date +%u`					# Day number of the week 1 to 7 where 1 represents Monday
DOM=`date +%d`					# Date of the Month e.g. 27
M=`date +%B`					# Month e.g January
W=`date +%V`					# Week Number e.g 37
LOGFILE=$BACKUPDIR/$DBHOST-`date +%d%m%y%H%M%S`.log	# Logfile Name
OPT=""						# --port for example

# Create required directories
if [ ! -e "$BACKUPDIR" ]		# Check Backup Directory exists.
	then
	mkdir -p "$BACKUPDIR"
fi

if [ ! -e "$BACKUPDIR/daily" ]		# Check Daily Directory exists.
	then
	mkdir -p "$BACKUPDIR/daily"
fi

if [ ! -e "$BACKUPDIR/weekly" ]		# Check Weekly Directory exists.
	then
	mkdir -p "$BACKUPDIR/weekly"
fi

if [ ! -e "$BACKUPDIR/monthly" ]	# Check Monthly Directory exists.
	then
	mkdir -p "$BACKUPDIR/monthly"
fi


# IO redirection for logging.
eval rm -f *.log
touch $LOGFILE
exec 6>&1           # Link file descriptor #6 with stdout.
                    # Saves stdout.
exec > $LOGFILE     # stdout replaced with file $LOGFILE.

#Set option for create database command on backup file
  if [ $CREATE_DATABASE == 'yes' ]
  then
    CREATEDB=' --create'
  fi

# Functions
check(){
 "$@"
 status=$?
 if [ $status -ne 0 ]; then
	touch	$BACKUPDIR/error
	if [ $ZABBIXSENDER == 'yes' ]; then
		zabbix_sender -c /etc/zabbix/zabbix_agentd.conf -k backup_failed[$DB] -o 1
	fi
	return 2
 fi
}

# Database dump function
	HOST="-h $DBHOST"
	if [ $BACKUPTYPE = 'plain' ]
  then
    BACKUPEXT='sql'
    dbdump="pg_dump $HOST $OPT $CREATEDB"
  else
    BACKUPEXT='dump'
    dbdump="pg_dump $HOST $OPT -Fc -Z $COMPRESIONLEVEL"
  fi

# Compression function
SUFFIX=""
compression () {
if [ "$COMP" = "gzip" ]; then
	gzip -f "$1"
	echo
	echo Backup Information for "$1"
	gzip -l "$1.gz"
	SUFFIX=".gz"
elif [ "$COMP" = "bzip2" ]; then
	echo Compression information for "$1.bz2"
	bzip2 -f -v $1 2>&1
	SUFFIX=".bz2"
else
	echo "No compression option set, check advanced settings"
fi
return 0
}

# Run command before we begin
if [ "$PREBACKUP" ]
	then
	echo ======================================================================
	echo "Prebackup command output."
	echo
	eval $PREBACKUP
	echo
	echo ======================================================================
	echo
fi

# If backing up all DBs on the server
if [ "$DBNAMES" = "all" ]; then
	DBNAMES="`check psql -U $USERNAME $HOST $OPT -l -A -F: | sed -ne "/:/ { /Name:Owner/d; /template0/d; s/:.*$//; p }"`"

	# If DBs are excluded
	for exclude in $DBEXCLUDE
	do
		DBNAMES=`echo $DBNAMES | sed "s/\b$exclude\b//g"`
	done
    MDBNAMES=$DBNAMES
fi

echo ======================================================================
echo Backup of Database Server - $DBHOST
echo ======================================================================

# Start Backup
echo Backup Start Time `date`
echo ======================================================================
	# Prepare $DB for using
	for DB in $MDBNAMES
	do
		DB="`echo $DB | sed 's/%/ /g'`"

	# Create Separate directory for each DB
	if [ ! -e "$BACKUPDIR/daily/$DB" ]		# Check Daily DB Directory exists.
		then
		mkdir -p "$BACKUPDIR/daily/$DB"
	fi
	if [ ! -e "$BACKUPDIR/weekly/$DB" ]		# Check Weekly DB Directory exists.
		then
		mkdir -p "$BACKUPDIR/weekly/$DB"
	fi
	if [ ! -e "$BACKUPDIR/monthly/$DB" ]		# Check Weekly DB Directory exists.
		then
		mkdir -p "$BACKUPDIR/monthly/$DB"
	fi

	#monthly backup

	if [ $DOM = "01" ]; then
		echo Monthly Backup of $DB...
			check $dbdump -f "$BACKUPDIR/monthly/$DB/${DB}_$DATE.$M.$DB.$BACKUPEXT" -U $USERNAME "$DB"
    	compression "$BACKUPDIR/monthly/$DB/${DB}_$DATE.$M.$DB.$BACKUPEXT"
    echo ----------------------------------------------------------------------

	#weekly backup
	elif [ $DNOW = $DOWEEKLY ]; then
		echo Weekly Backup of Database \( $DB \)
		echo Rotating 5 weeks Backups...
			if [ "$W" -le 05 ];then
				REMW=`expr 48 + $W`
			elif [ "$W" -lt 15 ];then
				REMW=0`expr $W - 5`
			else
				REMW=`expr $W - 5`
			fi
		eval rm -fv "$BACKUPDIR/weekly/$DB/week.$REMW.*"
		echo
			check $dbdump -f "$BACKUPDIR/weekly/$DB/${DB}_week.$W.$DATE.$BACKUPEXT" -U $USERNAME "$DB"
			compression "$BACKUPDIR/weekly/$DB/${DB}_week.$W.$DATE.$BACKUPEXT"
    echo ----------------------------------------------------------------------

	# Daily Backup
	else
		echo Daily Backup of Database \( $DB \)
		echo Rotating last weeks Backup...
		eval rm -fv "$BACKUPDIR/daily/$DB/*.$DOW.$BACKUPEXT.*"
		echo
			check $dbdump -f "$BACKUPDIR/daily/$DB/${DB}_$DATE.$DOW.$BACKUPEXT" -U $USERNAME "$DB"
			compression "$BACKUPDIR/daily/$DB/${DB}_$DATE.$DOW.$BACKUPEXT"
  fi
	done
echo Backup End `date`
echo =====================================================================

echo Total disk space used for backup storage..
echo Size - Location
echo `du -hs "$BACKUPDIR"`

#Send to S3
if [ "$SEND_TO_S3" = "yes" ]
  then
  check aws s3 sync $BACKUPDIR $BUCKETNAME
else
  echo "Backup saved on $BACKUPDIR"
fi

# Run command when we're done
if [ "$POSTBACKUP" ]
	then
	echo ======================================================================
	echo "Postbackup command output."
	echo
	eval $POSTBACKUP
	echo
	echo ======================================================================
fi

#Clean up IO redirection
exec 1>&6 6>&-      # Restore stdout and close file descriptor #6.

if [ -f "$BACKUPDIR/error" ]
then
	{
		echo To: $MAILADDR
		echo From: $MAILADDR
		echo Subject: ERROR on PostgreSQL Backup for $DBHOST - $DATE
		cat $BACKUPDIR/errorlog.txt
} | /usr/sbin/ssmtp $MAILADDR
else
	{
    echo To: $MAILADDR
    echo From: $MAILADDR
    echo Subject: SUCCESS on PostgreSQL Backup Log for $DBHOST - $DATE
    cat $LOGFILE
} | /usr/sbin/ssmtp $MAILADDR
fi

# Clean up Logfile
eval rm -f "$BACKUPDIR/error"
eval rm -f "$ERRORLOG"
eval rm -f "$LOGFILE"
exit 0
