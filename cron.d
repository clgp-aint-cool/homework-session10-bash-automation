# Health check every minute 
* * * * * root /home/lab05/homework-session10-bash-automation/health-check.sh >> /var/log/lab05-cron/health-check.log 2>&1

# Backup daily at 20:00
0 20 * * * root /home/lab05/homework-session10-bash-automation/backup.sh >> /var/log/lab05-cron/backup.log 2>&1
