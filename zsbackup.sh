#!/bin/bash
########################################################################
# Name          : zsbackup.sh
# Version       : 1.0
# Date          : 2016-12-08
# Author        : Matteo Temporini
# Compatibility : Ubuntu 16.04 LTS, Zimbra 8.7.x
# Purpose       : Backup individual mailbox accounts.
# Exit Codes    : (if multiple errors, value is the addition of codes)
#   0 = success
#   1 = failure

# Email notification options
EMAILFROM="admin@domain.ltd"
EMAILTO="admin2@domain.ltd"

# Email account NOT to backup
EXCEPTIONS="spam.t1ml2qhoo@domain.com;ham.w5adcmdphn@domain.com;virus-quarantine.lzab8c2m_@domain.com"

# Paths and file defs, probably nothing for you to change
TEMPDIR="/backup"
LOGFILE="${TEMPDIR}/zm-user-backup.log"
SOURCEDIR="/opt/zimbra"
TARGETDIR="${TEMPDIR}/zmusers"
ARCHIVEFILE="`date +%Y-%m-%d_%H-%M`_zmusers.tar"
MAILFILE="${TEMPDIR}/zm-user-backup-mail.$$"
MAILLOG="${TEMPDIR}/zm-user-backup-mail-log.$$"
FTPLOG="${TEMPDIR}/zm-user-backup-ftp-log.$$"

# Remote NFS mount
REMOTESITE="/mnt/zmbackup"
REMOTETESTFILE="${REMOTESITE}/online.txt"

# Remote FTPS server
FTP="yes"                               # To FTP or not to FTP, if no, copy to NFS will be performed
FTPSERVER="backupserver.domain.ltd"           # FTP server to copy backup to
FTPUSER="USERNAME"                     # FTP account username
FTPPASS="PASSWORD"                     # FTP account password
FTPDIR="/mybackupdir"                 # Directory on FTP server to place backup into

# Nothing to change here, move along
HOSTNAME=$(hostname -f)
SCRIPTNAME=${0}
RETURNVALUE=0
UCOUNT=0
ERRORFLAG=0

#######################################
##            FUNCTIONS              ##
#######################################

function f_sendmail()
{
  # Purpose: Send email message.
  # Parameter #1 = Subject
  # Parameter #2 = Body
  echo "From: ${EMAILFROM}" > ${MAILFILE}
  echo "To: ${EMAILTO}" >> ${MAILFILE}
  echo "Subject: ${1}" >> ${MAILFILE}
  echo "" >> ${MAILFILE}
  echo ${2} >> ${MAILFILE}
  echo "" >> ${MAILFILE}
  cat ${MAILLOG} >> ${MAILFILE}
  echo "" >> ${MAILFILE}
  cat ${FTPLOG} >> ${MAILFILE}
  echo "" >> ${MAILFILE}
  echo "Server: ${HOSTNAME}, Program: ${SCRIPTNAME}" >> ${MAILFILE}
  ${SOURCEDIR}/common/sbin/sendmail -t < ${MAILFILE}
}

function f_cleanup()
{
  rm ${MAILFILE}
  rm ${MAILLOG}
  rm ${FTPLOG}
  # Remove backup's older then 5 days
  find ${TEMPDIR}/*.tar -mtime +5 -exec rm {} \;
}

function f_log()
{
  # Handles logging of messages
  # Parameter #1 = Log Message
  STAMP=`date '+%Y-%m-%d %H:%M:%S'`
  echo "${STAMP} ${1}"
  echo "${STAMP} ${1}" >> ${LOGFILE}
  echo "${STAMP} ${1}" >> ${MAILLOG}
}


#######################################
##           MAIN PROGRAM            ##
#######################################

echo "---------------------------------------------------" >> ${LOGFILE}
f_log "- zm user backup started."
if [ -d "${TARGETDIR}" ]; then
  # Purge existing archives.
  rm ${TARGETDIR}/*.tgz 1>/dev/null 2>&1
else
  # Make the folder if it does not exist.
  mkdir -p ${TARGETDIR} 1>/dev/null 2>&1
fi
f_log "-- Getting list of user accounts"
for ACCT in `su - zimbra -c "zmprov -l gaa"`
do
  # Check to see if current account should be skipped.
  if echo "${EXCEPTIONS}" | grep -q ${ACCT}
  then
    # Exception found, skip this account.
    echo "" > /dev/null
  else
    # Backup user account.
    UCOUNT=$((UCOUNT+1))
    f_log "--- Backing up user ${ACCT}"
    ${SOURCEDIR}/bin/zmmailbox -z -m ${ACCT} getRestURL "//?fmt=tgz" > ${TARGETDIR}/${ACCT}.tgz
    RETURNVALUE=$?
    if [ ! ${RETURNVALUE} -eq 0 ]; then
      # Something went wrong.
      f_log "---- Error on ${ACCT}, exit code ${RETURNVALUE}"
      ERRORFLAG=$((ERRORFLAG+1))
    fi
  fi
done
f_log "-- ${UCOUNT} accounts processed."

# Comment out the below line if you do not want to receive statistic emails.
#f_sendmail "Zimbra User Mailbox Backup" "${UCOUNT} accounts backed up."

f_log "--- Setting file permissions on ${TARGETDIR}/*.tgz"
chmod 0600 ${TARGETDIR}/*.tgz
f_log "--- Creating a single archive ${TEMPDIR}/${ARCHIVEFILE}"
tar -cf ${TEMPDIR}/${ARCHIVEFILE} ${TARGETDIR} 1>/dev/null 2>&1
RETURNVALUE=$?
if [ ! "${RETURNVALUE}" -eq "0" ]; then
  # Something went wrong.
  f_log "--- Error creating ${TEMPDIR}/${ARCHIVEFILE}, Return Value: ${RETURNVALUE}"
  ERRORFLAG=$((ERRORFLAG+1))
fi

if [ "$FTP" = "yes" ]
then
        # Do FTPS copy to FTP site
        f_log "-- Starting FTPS copy to ${FTPSERVER}"
        #lftp -u ${FTPUSER},${FTPPASS} -e "set ftp:ssl-force true,ftp:ssl-protect-data true,net:max-retries 5; cd ${FTPDIR}; put ${TEMPDIR}/${ARCHIVEFILE}; exit" ${FTPSERVER}
        lftp -u ${FTPUSER},${FTPPASS} -e "set net:max-retries 5; cd ${FTPDIR}; put ${TEMPDIR}/${ARCHIVEFILE}; exit" ${FTPSERVER}
        RETURNVALUE=$?
        if [ "${RETURNVALUE}" == "0" ]
        then
                f_log "--- FTPS upload completed successfully"
        else
                f_log "--- FTPS upload FAILED, exit code ${RETURNVALUE}"
                ERRORFLAG=$((ERRORFLAG+1))
        fi
else
        # Do copy to remote file store

        if [ -f ${TEMPDIR}/${ARCHIVEFILE} ]; then
          # Copy archive to remote site.
          if [ -f ${REMOTETESTFILE} ]; then
            # Remote site is online / available.
            cp ${TEMPDIR}/${ARCHIVEFILE} ${REMOTESITE}/${ARCHIVEFILE} 1>/dev/null 2>&1
          else
            # Remote site is offline / unavailable.
            f_log "--- Error: Remote site is unavailable: ${REMOTESITE}"
            ERRORFLAG=$((ERRORFLAG+1))
          fi
        fi

        if [ -f ${REMOTESITE}/${ARCHIVEFILE} ]; then
          # Remote copy worked.  Remove local archive.
          rm ${TEMPDIR}/${ARCHIVEFILE}

          # Uncomment the following 2 lines if you do not wish to have a local copy of individual mailboxes.
          #rm ${TARGETDIR}/*.tgz
          #rmdir ${TARGETDIR}
        else
          # Remote copy failed.
          f_log "--- Error creating ${TEMPDIR}/${ARCHIVEFILE}, Return Value: ${RETURNVALUE}"
          ERRORFLAG=$((ERRORFLAG+1))
        fi
fi

f_log "- zm user backup complete. exit code: ${ERRORFLAG}"

if [ "${ERRORFLAG}" -ne "0" ]; then
  f_sendmail "Zimbra Mailbox Backup Error - ${HOSTNAME}" "${ERRORFLAG} errors detected in ${HOSTNAME} ${SCRIPTNAME}"<${MAILLOG}
else
  f_sendmail "Zimbra User Mailbox Backup - ${HOSTNAME}" "${UCOUNT} accounts backed up."<${MAILLOG}
fi

# Perform cleanup routine.
f_cleanup
# Exit with the combined return code value.
exit ${ERRORFLAG}
